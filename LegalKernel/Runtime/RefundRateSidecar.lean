-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Runtime.RefundRateSidecar — GP.9.1 refund-rate persistence.

The `claimBudgetRefund` admission gate pins a refund's
`weiPerBudgetUnit` field to a TRUSTED per-resource exchange rate
(`RuntimeState.refundRate`), supplied by the operator via the
`--wei-per-budget-unit-eth` / `--wei-per-budget-unit-bold` CLI flags.
Unlike the budget config (GP.6.2) and the gas-pool genesis (GP.7.4),
the rate is NOT part of the committed state — the kernel refund step
uses the action's *logged* `weiPerBudgetUnit`, so replay / fault-proof
remain deterministic regardless of the runtime rate.

But the rate DOES decide *which* `claimBudgetRefund` actions are
admissible: a logged refund admitted by the producer under rate `R`
(which pins its `weiPerBudgetUnit = R`) is REJECTED by a replayer
running under a different rate `R' ≠ R` (the rate pin fails), so the
replay diverges silently.  To turn that into a CLEAR, actionable error
— exactly as `BudgetSidecar` does for the budget config — the runtime
persists the rate in a sidecar next to the log and cross-checks it on
every log-touching command (incl. the fault-proof oracle's
`replay-up-to` / `export-cell-proofs`, so the off-chain observer can
never recompute a state commit under the wrong rate).

Design (mirrors `BudgetSidecar`):

  * **Sidecar path**: `<logPath>.refundratecfg`.
  * **Format** (one line, ASCII): `knomosis-refund-rate/v1 <ethRate>
    <boldRate>` — the ETH-leg (resource 0) and BOLD-leg (resource 1)
    `weiPerBudgetUnit` rates.
  * **Check** (`checkConsistent`): if the sidecar exists, the current
    rate MUST decode-equal it, else a precise error names the expected
    flags.  Absent sidecar ⇒ no constraint.
  * **Write** (`writeSidecarIfAbsent`): the writer (`process`) records
    the rate after a successful bootstrap, but ONLY for a non-default
    (refunds-enabled) rate — a refunds-disabled (`0 0`) deployment
    creates no sidecar, preserving the pre-GP.9.1 on-disk footprint
    byte-for-byte.

The pure `encode` / `decode` round-trip + `isDefault` predicate are
unit-tested; the IO orchestration is exercised by the
`runtime-refund-rate-sidecar` suite.
-/

import LegalKernel.Authority.Nonce

namespace LegalKernel.Runtime.RefundRateSidecar

open LegalKernel

/-- The persisted refund-rate configuration: the per-resource
    `weiPerBudgetUnit` rates the admission gate pins each refund to.
    Two legs are supported on the CLI (matching the GP.5.1 / GP.5.4
    deposit-side rates): ETH (resource 0) and BOLD (resource 1).

    **Deployment-calibration warning (cross-resource value consistency).**
    A claimant's action budget is a SINGLE scalar
    (`EpochBudgetState.currentBudget`), but the refund payout is
    per-resource (`budgetUnits × refundRate gasResource`).  A claimant
    therefore retires their one shared budget at whichever blessed
    resource has the highest rate.  The gate prevents a double refund
    (the single budget is consumed once) and inflation (the rate is
    pinned, not user-chosen), but it does NOT police cross-resource
    consistency: set the per-resource rates so that
    `rate_eth : rate_bold` reflects the resources' actual relative value
    (e.g. the same USD-per-budget-unit on both legs, as the GP.6.5
    calibration corpus does), or a claimant will always pick the
    richest leg. -/
structure RefundRateConfig where
  /-- ETH-leg (resource 0) `weiPerBudgetUnit` rate (`0` = refunds
      disabled at ETH). -/
  ethRate : Nat
  /-- BOLD-leg (resource 1) `weiPerBudgetUnit` rate (`0` = refunds
      disabled at BOLD). -/
  boldRate : Nat
  deriving DecidableEq, Repr

namespace RefundRateConfig

/-- The `ResourceId → Nat` refund-rate function a config denotes.  ETH
    (resource 0) and BOLD (resource 1) get their configured rates;
    every other resource has refunds disabled (rate `0`), so a refund
    at an off-leg resource fails the gate's rate pin. -/
def toRefundRate (c : RefundRateConfig) : ResourceId → Nat :=
  fun r => if r = 0 then c.ethRate else if r = 1 then c.boldRate else 0

/-- Build a config from the two CLI flag values. -/
def ofFlags (ethRate boldRate : Nat) : RefundRateConfig :=
  { ethRate := ethRate, boldRate := boldRate }

/-- The refunds-disabled config (both rates `0`).  The default for every
    log-touching subcommand: refunds are off unless an operator wires a
    rate, and no sidecar is written. -/
def disabled : RefundRateConfig := { ethRate := 0, boldRate := 0 }

/-- `true` iff this is the refunds-disabled default (nothing to
    protect: a default deployment writes no sidecar). -/
def isDefault (c : RefundRateConfig) : Bool :=
  c.ethRate == 0 && c.boldRate == 0

end RefundRateConfig

/-- The magic prefix identifying a v1 refund-rate sidecar line. -/
def magic : String := "knomosis-refund-rate/v1"

/-- The sidecar file path for a given log path: `<logPath>.refundratecfg`. -/
def sidecarPath (logPath : System.FilePath) : System.FilePath :=
  System.FilePath.mk (logPath.toString ++ ".refundratecfg")

/-- Encode a config to its canonical one-line sidecar form
    (newline-terminated). -/
def encode (c : RefundRateConfig) : String :=
  s!"{magic} {c.ethRate} {c.boldRate}\n"

/-- Decode a sidecar line back to a `RefundRateConfig`.  Returns `none`
    on a missing / wrong magic prefix, the wrong field count, or any
    non-`Nat` field.  Tolerant of trailing whitespace / a trailing
    newline / CRLF. -/
def decode (s : String) : Option RefundRateConfig :=
  let cleaned := (s.replace "\n" " ").replace "\r" " "
  let toks := cleaned.splitOn " " |>.filter (· ≠ "")
  match toks with
  | [m, ethStr, boldStr] =>
    if m ≠ magic then none
    else match ethStr.toNat?, boldStr.toNat? with
      | some eth, some bold => some { ethRate := eth, boldRate := bold }
      | _, _ => none
  | _ => none

-- NOTE: the `decode (encode c) = some c` round-trip holds for every
-- `RefundRateConfig`, but a closed-form Lean proof would have to reason
-- about decimal `Nat` rendering + `String.splitOn`, which is
-- disproportionately painful.  Per the project's value-level test
-- convention it is pinned by the `runtime-refund-rate-sidecar` suite
-- across a range of configs instead.

/-- A human-readable rendering of a config's defining CLI flags, for
    error messages. -/
def describeFlags (c : RefundRateConfig) : String :=
  s!"--wei-per-budget-unit-eth {c.ethRate} --wei-per-budget-unit-bold {c.boldRate}"

/-- IO: cross-check the current rate against any existing sidecar.

    * Sidecar absent → `.ok ()` (no constraint; the writer creates it
      later).
    * Sidecar present + decodes + equals `current` → `.ok ()`.
    * Sidecar present + decodes + differs → `.error` naming the
      expected flags (the operator most likely forgot or changed a
      rate flag on restart — a refund-containing log replays correctly
      only under the producing rate).
    * Sidecar present + undecodable → `.error` (corrupt sidecar). -/
def checkConsistent (logPath : System.FilePath) (current : RefundRateConfig) :
    IO (Except String Unit) := do
  let path := sidecarPath logPath
  if ← path.pathExists then
    let contents ← IO.FS.readFile path
    match decode contents with
    | none =>
      pure (.error
        s!"refund-rate sidecar {path} is corrupt or unrecognised; \
           expected `{magic} <ethRate> <boldRate>`")
    | some persisted =>
      if persisted = current then
        pure (.ok ())
      else
        pure (.error
          s!"refund-rate mismatch: this log was created with \
             `{describeFlags persisted}`, but the current invocation uses \
             `{describeFlags current}`.  Re-run with the original refund-rate \
             flags (the rate determines which `claimBudgetRefund` actions are \
             admissible; replaying a refund-containing log under a different \
             rate rejects those actions and diverges).")
  else
    pure (.ok ())

/-- IO: LOAD the persisted refund-rate config from the sidecar.  Unlike
    `checkConsistent` (which compares a CLI-supplied config against disk),
    this RECONSTRUCTS the config from disk — for the auditor path
    (`knomosis-replay`), which has no refund-rate flags and must re-derive
    the rate the producer used so an admitted `claimBudgetRefund` replays
    deterministically.  Returns `ok none` when no sidecar exists (refunds
    were disabled — the default), `ok (some cfg)` when it decodes, and
    `error` when the sidecar is present but corrupt (the auditor must fail
    loudly, never silently audit under the wrong rate). -/
def load (logPath : System.FilePath) :
    IO (Except String (Option RefundRateConfig)) := do
  let path := sidecarPath logPath
  if ← path.pathExists then
    let contents ← IO.FS.readFile path
    match decode contents with
    | none =>
      pure (.error
        s!"refund-rate sidecar {path} is corrupt or unrecognised; \
           expected `{magic} <ethRate> <boldRate>`")
    | some cfg => pure (.ok (some cfg))
  else
    pure (.ok none)

/-- IO: write the sidecar iff it does NOT already exist AND the rate is
    non-default (refunds enabled).  Called by the writer (`process`)
    after a successful bootstrap, so a refunds-disabled deployment never
    creates a sidecar (preserving the pre-GP.9.1 on-disk footprint). -/
def writeSidecarIfAbsent (logPath : System.FilePath) (current : RefundRateConfig) :
    IO Unit := do
  if current.isDefault then
    pure ()
  else
    let path := sidecarPath logPath
    unless ← path.pathExists do
      IO.FS.writeFile path (encode current)

end LegalKernel.Runtime.RefundRateSidecar

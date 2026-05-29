/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Runtime.BudgetSidecar — GP.6.2 budget-config persistence.

The per-actor budget gate's configuration (`BudgetPolicy` +
epoch-advancement length) participates in every log entry's
post-state hash.  An operator who restarts `knomosis process` /
`replay` with a DIFFERENT budget config than the one a log was
created under therefore hits an opaque `postStateHash` mismatch deep
in replay.  To turn that into a CLEAR, actionable error, the runtime
persists the budget config in a sidecar file next to the log and
cross-checks it on every log-touching command.

Design:

  * **Sidecar path**: `<logPath>.budgetcfg`.
  * **Format** (one line, ASCII): `knomosis-budget/v1 <ft> <ac> <ce>
    <epochLength>` where the four fields are the bounded policy's
    `freeTier` / `actionCost` / `currentEpoch` and the epoch length.
  * **Check** (`checkConsistent`): if the sidecar exists, the current
    config MUST decode-equal it, else a precise error names the
    expected flags.  Absent sidecar ⇒ no constraint.
  * **Write** (`writeSidecarIfAbsent`): the writer (`process`) records
    the config after a successful bootstrap, but ONLY for a
    non-default config — a default (`bounded 0 1 0`, no advancement)
    deployment creates no sidecar, preserving the pre-GP.6.2 on-disk
    footprint byte-for-byte.

The pure `encode` / `decode` round-trip + `isDefault` predicate are
unit-tested; the IO orchestration is exercised by the
`integration-budget-sidecar` suite.
-/

import LegalKernel.Authority.Nonce

namespace LegalKernel.Runtime.BudgetSidecar

open LegalKernel.Authority

/-- The persisted budget configuration: the bounded policy fields plus
    the epoch-advancement length. -/
structure BudgetConfig where
  /-- Per-epoch free-tier floor. -/
  freeTier : Nat
  /-- Per-action budget cost (≥ 1 by the smart constructor). -/
  actionCost : Nat
  /-- Base epoch index. -/
  currentEpoch : Nat
  /-- Admitted log entries per budget epoch (`0` = no advancement). -/
  epochLength : Nat
  deriving DecidableEq, Repr

/-- Build a `BudgetConfig` from a `BudgetPolicy` + epoch length. -/
def ofPolicy (policy : BudgetPolicy) (epochLength : Nat) : BudgetConfig :=
  match policy with
  | .bounded ft ac ce => { freeTier := ft, actionCost := ac, currentEpoch := ce, epochLength }

/-- The `BudgetPolicy` a config denotes (via the clamping smart
    constructor, so a decoded `actionCost = 0` is normalised to 1 —
    though the encoder never emits that). -/
def toPolicy (c : BudgetConfig) : BudgetPolicy :=
  BudgetPolicy.mkBounded c.freeTier c.actionCost c.currentEpoch

/-- The magic prefix identifying a v1 budget-config sidecar line. -/
def magic : String := "knomosis-budget/v1"

/-- `true` iff this is the genesis-default config (nothing to protect:
    a default deployment writes no sidecar). -/
def isDefault (c : BudgetConfig) : Bool :=
  c.freeTier == 0 && c.actionCost == 1 && c.currentEpoch == 0 && c.epochLength == 0

/-- The sidecar file path for a given log path: `<logPath>.budgetcfg`. -/
def sidecarPath (logPath : System.FilePath) : System.FilePath :=
  System.FilePath.mk (logPath.toString ++ ".budgetcfg")

/-- Encode a config to its canonical one-line sidecar form
    (newline-terminated). -/
def encode (c : BudgetConfig) : String :=
  s!"{magic} {c.freeTier} {c.actionCost} {c.currentEpoch} {c.epochLength}\n"

/-- Decode a sidecar line back to a `BudgetConfig`.  Returns `none`
    on a missing / wrong magic prefix, the wrong field count, or any
    non-`Nat` field.  Tolerant of trailing whitespace / a trailing
    newline. -/
def decode (s : String) : Option BudgetConfig :=
  -- Normalise line endings to spaces, then split + drop empties so a
  -- trailing newline / CRLF / repeated spaces don't corrupt the last
  -- token.
  let cleaned := (s.replace "\n" " ").replace "\r" " "
  let toks := cleaned.splitOn " " |>.filter (· ≠ "")
  match toks with
  | [m, ftStr, acStr, ceStr, elStr] =>
    if m ≠ magic then none
    else match ftStr.toNat?, acStr.toNat?, ceStr.toNat?, elStr.toNat? with
      | some ft, some ac, some ce, some el =>
        some { freeTier := ft, actionCost := ac, currentEpoch := ce, epochLength := el }
      | _, _, _, _ => none
  | _ => none

-- NOTE: the `decode (encode c) = some c` round-trip holds for every
-- `BudgetConfig`, but a closed-form Lean proof would have to reason
-- about decimal `Nat` rendering + `String.splitOn`, which is
-- disproportionately painful.  Per the project's value-level test
-- convention it is pinned by the `integration-budget-sidecar` suite
-- (`budgetSidecarRoundTrip`) across a range of configs instead.

/-- A human-readable rendering of a config's defining CLI flags, for
    error messages. -/
def describeFlags (c : BudgetConfig) : String :=
  s!"--budget-policy bounded --free-tier {c.freeTier} --action-cost {c.actionCost} " ++
  s!"--current-epoch {c.currentEpoch} --epoch-length {c.epochLength}"

/-- IO: cross-check the current config against any existing sidecar.

    * Sidecar absent → `.ok ()` (no constraint; the writer creates it
      later).
    * Sidecar present + decodes + equals `current` → `.ok ()`.
    * Sidecar present + decodes + differs → `.error` naming the
      expected flags (the operator most likely forgot or changed a
      budget flag on restart).
    * Sidecar present + undecodable → `.error` (corrupt sidecar). -/
def checkConsistent (logPath : System.FilePath) (current : BudgetConfig) :
    IO (Except String Unit) := do
  let path := sidecarPath logPath
  if ← path.pathExists then
    let contents ← IO.FS.readFile path
    match decode contents with
    | none =>
      pure (.error
        s!"budget-config sidecar {path} is corrupt or unrecognised; \
           expected `{magic} <freeTier> <actionCost> <currentEpoch> <epochLength>`")
    | some persisted =>
      if persisted = current then
        pure (.ok ())
      else
        pure (.error
          s!"budget-config mismatch: this log was created with \
             `{describeFlags persisted}`, but the current invocation uses \
             `{describeFlags current}`.  Re-run with the original budget \
             flags (the budget config participates in the log's post-state \
             hashes and cannot change for an existing log).")
  else
    pure (.ok ())

/-- IO: write the sidecar iff it does NOT already exist AND the config
    is non-default.  Called by the writer (`process`) after a
    successful bootstrap, so a default-config deployment never creates
    a sidecar (preserving the pre-GP.6.2 on-disk footprint). -/
def writeSidecarIfAbsent (logPath : System.FilePath) (current : BudgetConfig) :
    IO Unit := do
  if isDefault current then
    pure ()
  else
    let path := sidecarPath logPath
    unless ← path.pathExists do
      IO.FS.writeFile path (encode current)

end LegalKernel.Runtime.BudgetSidecar

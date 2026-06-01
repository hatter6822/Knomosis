-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.GasPoolSidecar — Workstream GP.7.4 gas-pool-config
persistence (the GP.6.2 `BudgetSidecar` pattern, for the gas-pool
genesis wiring).

A GP-enabled deployment declares `gasPoolPolicy mEth mBold` for
`gasPoolActor` in its genesis `localPolicies` (the state half of the
GP.7.4 wiring).  Because `localPolicies` is part of the encoded
`ExtendedState`, it participates in every log entry's post-state hash.
An operator who restarts `knomosis process` / `replay` with a DIFFERENT
gas-pool config — or with the gas pool disabled — than the one a log was
created under therefore hits an opaque `postStateHash` mismatch deep in
replay.  To turn that into a CLEAR, actionable error, the runtime
persists the gas-pool config in a sidecar next to the log and
cross-checks it on every log-touching command.

This mirrors `LegalKernel.Runtime.BudgetSidecar` exactly, with the
opt-out (`none` — the gas pool disabled) playing the role the
genesis-default budget config plays there: a deployment with the gas
pool DISABLED writes no sidecar, preserving the pre-GP.7.4 on-disk
footprint byte-for-byte.

Design:

  * **Sidecar path**: `<logPath>.gaspoolcfg`.
  * **Format** (one line, ASCII): `knomosis-gaspool/v1 <ethCap> <boldCap>`.
  * **Check** (`checkConsistent`): if the sidecar exists, the current
    config MUST decode-equal it (and the gas pool MUST be enabled),
    else a precise error names the expected flags.  Absent sidecar ⇒
    no constraint (a from-genesis run will create it; a mismatch on an
    EXISTING non-gas-pool log is still caught loudly by replay's
    post-state-hash check, exactly as for the budget sidecar).
  * **Write** (`writeSidecarIfAbsent`): the writer (`process`) records
    the config after a successful bootstrap, but ONLY when the gas pool
    is enabled (`some cfg`).

The pure `encode` / `decode` round-trip is unit-tested; the IO
orchestration is exercised by the `runtime-gas-pool-sidecar` suite.
-/

import LegalKernel.Bridge.GasPoolPolicy

namespace LegalKernel.Runtime.GasPoolSidecar

open LegalKernel.Bridge (GasPoolConfig)

/-- The magic prefix identifying a v1 gas-pool-config sidecar line. -/
def magic : String := "knomosis-gaspool/v1"

/-- The sidecar file path for a given log path: `<logPath>.gaspoolcfg`. -/
def sidecarPath (logPath : System.FilePath) : System.FilePath :=
  System.FilePath.mk (logPath.toString ++ ".gaspoolcfg")

/-- Encode a config to its canonical one-line sidecar form
    (newline-terminated). -/
def encode (c : GasPoolConfig) : String :=
  s!"{magic} {c.maxDrainPerActionEth} {c.maxDrainPerActionBold}\n"

/-- Decode a sidecar line back to a `GasPoolConfig`.  Returns `none`
    on a missing / wrong magic prefix, the wrong field count, or any
    non-`Nat` field.  Tolerant of trailing whitespace / a trailing
    newline / CRLF. -/
def decode (s : String) : Option GasPoolConfig :=
  let cleaned := (s.replace "\n" " ").replace "\r" " "
  let toks := cleaned.splitOn " " |>.filter (· ≠ "")
  match toks with
  | [m, ethStr, boldStr] =>
    if m ≠ magic then none
    else match ethStr.toNat?, boldStr.toNat? with
      | some eth, some bold =>
        some { maxDrainPerActionEth := eth, maxDrainPerActionBold := bold }
      | _, _ => none
  | _ => none

-- NOTE: the `decode (encode c) = some c` round-trip holds for every
-- `GasPoolConfig`, but (as for `BudgetSidecar`) a closed-form Lean proof
-- would reason about decimal `Nat` rendering + `String.splitOn`, so it
-- is pinned by the `runtime-gas-pool-sidecar` suite value-level instead.

/-- A human-readable rendering of a config's defining CLI flags, for
    error messages. -/
def describeFlags (c : GasPoolConfig) : String :=
  s!"--gas-pool-eth-cap {c.maxDrainPerActionEth} --gas-pool-bold-cap {c.maxDrainPerActionBold}"

/-- IO: cross-check the current gas-pool config against any existing
    sidecar.

    * Sidecar absent → `.ok ()` (no constraint; a from-genesis writer
      creates it later).
    * Sidecar present + decodes + `current = some` equal to it → `.ok ()`.
    * Sidecar present + `current = none` (gas pool disabled this run) →
      `.error` (the log was created WITH the gas pool).
    * Sidecar present + decodes + differs → `.error` naming the expected
      flags.
    * Sidecar present + undecodable → `.error` (corrupt sidecar). -/
def checkConsistent (logPath : System.FilePath) (current : Option GasPoolConfig) :
    IO (Except String Unit) := do
  let path := sidecarPath logPath
  if ← path.pathExists then
    let contents ← IO.FS.readFile path
    match decode contents with
    | none =>
      pure (.error
        s!"gas-pool-config sidecar {path} is corrupt or unrecognised; \
           expected `{magic} <ethCap> <boldCap>`")
    | some persisted =>
      match current with
      | none =>
        pure (.error
          s!"gas-pool-config mismatch: this log was created with \
             `{describeFlags persisted}`, but the current invocation does NOT \
             enable the gas pool.  Re-run with the original gas-pool flags (the \
             gas-pool genesis policy participates in the log's post-state hashes \
             and cannot change for an existing log).")
      | some cur =>
        if persisted = cur then
          pure (.ok ())
        else
          pure (.error
            s!"gas-pool-config mismatch: this log was created with \
               `{describeFlags persisted}`, but the current invocation uses \
               `{describeFlags cur}`.  Re-run with the original gas-pool flags.")
  else
    pure (.ok ())

/-- IO: write the sidecar iff it does NOT already exist AND the gas pool
    is enabled (`current = some cfg`).  Called by the writer (`process`)
    after a successful bootstrap, so a gas-pool-disabled deployment never
    creates a sidecar (preserving the pre-GP.7.4 on-disk footprint). -/
def writeSidecarIfAbsent (logPath : System.FilePath) (current : Option GasPoolConfig) :
    IO Unit := do
  match current with
  | none => pure ()
  | some cfg =>
    let path := sidecarPath logPath
    unless ← path.pathExists do
      IO.FS.writeFile path (encode cfg)

end LegalKernel.Runtime.GasPoolSidecar

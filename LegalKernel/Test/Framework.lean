/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Framework — micro test harness.

A deliberately tiny test runner: each test is an `IO Unit` that
throws (via `IO.userError`) on failure.  The umbrella runner
catches errors per test, prints a one-line PASS/FAIL banner, and
returns a non-zero exit code if any test failed.

We do not depend on a third-party test framework (no LSpec, no
Plausible) because Phase 0's core acceptance gate is "no external
deps beyond Lean core".  Phase 1+ may layer property-based testing
on top of this scaffold.

This module also exposes `LegalKernel.Test.emptyState`, the canonical
"no balances anywhere" state.  Test modules build their fixtures on
top of it so that fresh-state construction lives in exactly one place.
-/

import LegalKernel.Kernel

namespace LegalKernel.Test

/-- The empty deployment state: no resource has any actor balance.
    Every `getBalance _ _` query against `emptyState` returns `0`. -/
def emptyState : LegalKernel.State := { balances := ∅ }

/-- A single named test.  `body` is `IO Unit` so it can call any
    of the `assert*` helpers below; the runner catches `IO.userError`
    and turns it into a `fail`. -/
structure TestCase where
  /-- Human-readable test name printed alongside the PASS / FAIL banner. -/
  name : String
  /-- The test body.  Throw `IO.userError msg` (typically via `assert`
      or `assertEq`) to signal failure. -/
  body : IO Unit

/-- Result of running a single test. -/
inductive Outcome
  /-- The test ran to completion without throwing. -/
  | pass
  /-- The test threw `IO.userError msg`. -/
  | fail (msg : String)

/-- Run one test, reporting PASS/FAIL to stdout. -/
def runOne (t : TestCase) : IO Outcome := do
  try
    t.body
    IO.println s!"  PASS  {t.name}"
    pure .pass
  catch e =>
    let msg := e.toString
    IO.println s!"  FAIL  {t.name}"
    IO.println s!"        {msg}"
    pure (.fail msg)

/-- Run every test in `ts`, printing a summary banner.  Returns the
    number of failures (0 when every test passed). -/
def runAll (suite : String) (ts : List TestCase) : IO Nat := do
  IO.println s!"== {suite} =="
  let mut failures := 0
  for t in ts do
    match (← runOne t) with
    | .pass     => pure ()
    | .fail _   => failures := failures + 1
  if failures = 0 then
    IO.println s!"-- {suite}: {ts.length} passed"
  else
    IO.println s!"-- {suite}: {failures}/{ts.length} FAILED"
  pure failures

/-- Throw `IO.userError msg` if `cond` is false; otherwise no-op. -/
def assert (cond : Bool) (msg : String) : IO Unit :=
  if cond then pure () else throw (IO.userError msg)

/-- Throw `IO.userError` if `actual ≠ expected`.  `expected` and
    `actual` must be `BEq`-comparable and `Repr`-printable; the
    optional `where_` string is folded into the failure message to
    distinguish multiple assertions in the same test body. -/
def assertEq {α : Type _} [BEq α] [Repr α]
    (expected actual : α) (where_ : String := "") : IO Unit :=
  if expected == actual then
    pure ()
  else
    let prefixStr := if where_.isEmpty then "assertEq" else s!"assertEq ({where_})"
    throw <| IO.userError s!"{prefixStr}: expected {repr expected}, got {repr actual}"

end LegalKernel.Test

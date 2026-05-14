/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.Injectivity — Workstream EI scaffolding
(`docs/planning/encoder_injectivity_plan.md` §4.0 EI.0.c).

This module is the home for every Workstream-EI test case.  It is
seeded with four shared-fixture smoke checks at the EI.0.c
landing: no per-theorem coverage has shipped yet because the
per-theorem proofs (EI.1 onwards) have not landed.  Each
subsequent EI sub-sub-unit adds its own `TestCase` values (term-
level API-stability checks plus value-level fixture-pair
assertions) and appends them to `tests` here.

The module also houses *shared fixtures* used by EI.1 – EI.7's
per-sub-state test bundles.  Hoisting these helpers up here keeps
each EI sub-unit's PR scoped to a single new theorem plus a small
`TestCase` block, with no duplicated fixture machinery.

Wiring:
  * Imported by `Tests.lean` so the umbrella driver picks the
    suite up.
  * Registered in the umbrella `main` under the
    `"encoding-injectivity"` suite name.
  * `lake test` runs the suite alongside every other test
    module.

Per CLAUDE.md "Background-agent file-change protection" §, this
file is owned by Workstream EI and should not be edited by any
non-EI workstream.

Reference: §3 of the encoder-injectivity plan (dependency DAG)
and Appendix A (theorem-to-test cross-reference matrix).
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.State

namespace LegalKernel.Test.Encoding
namespace InjectivityTests

open Std
open LegalKernel
open LegalKernel.Encoding

/-! ## Shared fixtures

A `genTreeMap` helper that produces representative
`Std.TreeMap ActorId Amount compare` fixtures in three sizes
(empty, singleton, three-element).  Hoisted here so that EI.2 –
EI.7's per-sub-state tests share a single source of test maps,
keeping the fixture surface easy to extend (the `BalanceMap`
abbrev is `TreeMap ActorId Amount compare`, which is the most
common shape used by EI's per-sub-state proofs). -/

/-- Fixture size knob — the three canonical shapes used by EI
    per-sub-state tests.  Adding a new size variant (e.g. a
    sixteen-element stress case) only needs an `EI.size` extension
    here, not a per-test rewrite. -/
inductive FixtureSize
  /-- The empty map.  Exercises the "0-pair" branch of every
      sub-state's encoder. -/
  | empty
  /-- A singleton map (one `(key, value)` pair).  Exercises the
      head-only branch. -/
  | singleton
  /-- A three-element map.  Exercises the inductive case at the
      smallest non-trivial size.  Test bodies that need a larger
      fixture should grow the inductive `FixtureSize` rather than
      bypass it ad hoc. -/
  | three
deriving DecidableEq, Repr

/-- Shared `BalanceMap` fixture generator.  Produces empty / one /
    three-pair maps using deterministic keys and values so the
    encoded bytes are reproducible across runs.

    The chosen `(key, value)` pairs avoid clashing with any
    invariant the inner balance map enforces (no zero amounts:
    every `Amount` is positive, exercising the "kept after
    `setBalance`" path).  Sub-states that key on `ActorId =
    UInt64` (the dominant case) use this fixture verbatim; sub-
    states keyed on other types (`ResourceId`, `WithdrawalId`,
    `DepositId`) ship a thin per-type adaptor in the same shape
    (added when the per-sub-state test bundle lands). -/
def genTreeMap : FixtureSize → BalanceMap
  | .empty     => (∅ : BalanceMap)
  | .singleton => (∅ : BalanceMap).insert (5 : ActorId) (100 : Amount)
  | .three     =>
      (((∅ : BalanceMap).insert (3 : ActorId) (10   : Amount)
                         ).insert (5 : ActorId) (100  : Amount)
                          ).insert (7 : ActorId) (1000 : Amount)

/-! ## Smoke checks for the shared fixtures

Four minimal sanity tests that exercise the `genTreeMap` shared
fixture before any EI.1+ tests use it.  These keep the suite
from being literally empty — `lake test` running zero cases
under this suite name would be a silent regression if a future
edit accidentally cleared `tests`.

Each is **fixture-only** (no per-theorem coverage); they verify
that the helper produces the documented shape and that
deterministic encoding holds on the chosen fixtures (a property
already shipped by `state_encode_deterministic`, but re-asserted
here on the EI fixtures to detect drift in the generator). -/

/-- `genTreeMap .empty` is the canonical empty map: no key is
    present.  Catches a future regression where someone "fills in"
    the empty case with a default-key trick. -/
def fixtureEmptyShape : TestCase := {
  name := "genTreeMap .empty is the empty map"
  body := do
    let bm := genTreeMap .empty
    -- The empty map has no entries; `[k]?` returns `none` for any k.
    assertEq (none : Option Amount) bm[(5 : ActorId)]? "lookup in empty"
    assertEq (none : Option Amount) bm[(0 : ActorId)]? "lookup at 0 in empty"
}

/-- `genTreeMap .singleton` has exactly the documented one pair.
    Catches a regression where the singleton shape grows extra
    entries. -/
def fixtureSingletonShape : TestCase := {
  name := "genTreeMap .singleton has exactly (5, 100)"
  body := do
    let bm := genTreeMap .singleton
    assertEq (some (100 : Amount)) bm[(5 : ActorId)]? "lookup at 5"
    assertEq (none : Option Amount) bm[(3 : ActorId)]? "lookup at 3"
    assertEq (none : Option Amount) bm[(7 : ActorId)]? "lookup at 7"
}

/-- `genTreeMap .three` has exactly three pairs at keys 3, 5, 7. -/
def fixtureThreeShape : TestCase := {
  name := "genTreeMap .three has (3,10), (5,100), (7,1000)"
  body := do
    let bm := genTreeMap .three
    assertEq (some (10   : Amount)) bm[(3 : ActorId)]? "lookup at 3"
    assertEq (some (100  : Amount)) bm[(5 : ActorId)]? "lookup at 5"
    assertEq (some (1000 : Amount)) bm[(7 : ActorId)]? "lookup at 7"
    assertEq (none : Option Amount) bm[(1 : ActorId)]? "lookup at 1"
}

/-- Encoding the shared `BalanceMap` fixtures is deterministic
    (`BalanceMap.encode` is referentially transparent).  Sanity
    check on the fixture; the per-sub-state injectivity proofs that
    EI.1 – EI.7 ship use `BalanceMap.encode` directly on these
    same fixtures. -/
def fixtureEncodeDeterministic : TestCase := {
  name := "genTreeMap fixtures encode deterministically"
  body := do
    for sz in [FixtureSize.empty, .singleton, .three] do
      let bm := genTreeMap sz
      let b1 := BalanceMap.encode bm
      let b2 := BalanceMap.encode bm
      assert (b1 == b2) s!"BalanceMap.encode non-deterministic at size {repr sz}"
}

/-! ## Suite registration

`tests` is intentionally minimal at EI.0.c.  EI.1 onwards each
append their per-theorem `TestCase` values here.  The four fixture
checks above stay (they're shared-machinery regressions, not
per-theorem coverage). -/

/-- Workstream EI's test cases.  Seeded with the four shared-
    fixture smoke checks.  Per the plan §4.0.c, value-level
    per-theorem coverage and term-level API-stability checks land
    with each subsequent EI sub-sub-unit (EI.1 onwards). -/
def tests : List TestCase :=
  [ fixtureEmptyShape
  , fixtureSingletonShape
  , fixtureThreeShape
  , fixtureEncodeDeterministic ]

end InjectivityTests
end LegalKernel.Test.Encoding

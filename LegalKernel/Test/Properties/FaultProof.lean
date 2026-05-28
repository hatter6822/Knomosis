/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Properties.FaultProof — property-based tests
for the fault-proof workstream (Workstream H §15 / WUs H.11.1 –
H.11.3).

Three properties × default 100 samples each:
  * `bisectionAgreeNarrowsProperty` — every legal `respondAgree`
    transition strictly narrows the dispute range.
  * `bisectionDisagreeNarrowsProperty` — same for `respondDisagree`.
  * `gameDeterminismProperty` — `applyTransition` is deterministic
    across replays.

Reproducibility: `KNOMOSIS_PROPERTY_SEED` env var pins the test
seed for failure investigation.
-/

import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.Game
import LegalKernel.Test.Framework
import LegalKernel.Test.Property

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test
open LegalKernel.Test.Property

namespace LegalKernel.Test.Properties.FaultProof

/-! ## Test fixtures: a property check yields a Bool. -/

/-- A property-check input: a generated game state and a generated
    midpoint claim that is strictly inside the game's range.  The
    test bodies check the bisection invariants on this input. -/
structure PropInput where
  /-- The generated initial game state. -/
  gs : LegalKernel.FaultProof.GameState
  /-- A midpoint claim strictly inside `gs.range`. -/
  mp : Claim
  deriving Repr

/-! ## Generators

Use `Gen` from `LegalKernel.Test.Property`. -/

/-- Generate a `PropInput` with a small range (low.idx < high.idx)
    and a midpoint strictly inside.  We pick `low.idx ∈ [0,
    1000)`, `gap ∈ [2, 1000)`, then offset `∈ [1, gap-1]`. -/
def genPropInput : Gen PropInput := fun st =>
  -- Generate low
  let (lo, st₁) := genNat 1000 st
  -- Generate gap (≥ 2)
  let (gapMinus2, st₂) := genNat 998 st₁
  let gap := gapMinus2 + 2
  -- Generate offset within (0, gap) exclusive both ends
  let (offsetMinus1, st₃) := genNat (gap - 1) st₂
  let offset := offsetMinus1 + 1
  let range : DisputedRange :=
    { low  := { idx := lo,        commit := ByteArray.empty },
      high := { idx := lo + gap,  commit := ByteArray.empty } }
  let mp : Claim :=
    { idx := lo + offset, commit := ByteArray.empty }
  let gs : LegalKernel.FaultProof.GameState :=
    { sequencer       := 1,
      challenger      := 2,
      range           := range,
      pendingMidpoint := none,
      depth           := 0,
      turn            := .sequencer,
      sequencerBond   := 1_000,
      challengerBond  := 50,
      status          := .inProgress,
      deploymentId    := ByteArray.empty }
  ({ gs := gs, mp := mp }, st₃)

/-! ## Properties

Each property returns a Bool: `true` for pass, `false` for fail.
The `forAll` driver throws on the first counter-example. -/

/-- Property: respondAgree on a well-formed midpoint strictly
    narrows the range.  Tests the
    `range_narrows_on_response_agree` theorem at the value
    level. -/
def bisectionAgreeNarrowsProp (input : PropInput) : Bool :=
  let gameWithPending : LegalKernel.FaultProof.GameState :=
    { input.gs with
        pendingMidpoint := some input.mp,
        turn := .challenger }
  match applyTransition gameWithPending .respondAgree with
  | .ok gs' =>
    let oldWidth := input.gs.range.high.idx - input.gs.range.low.idx
    let newWidth := gs'.range.high.idx - gs'.range.low.idx
    decide (newWidth < oldWidth)
  | .error _ => false

/-- Property: respondDisagree narrows the range to the first half. -/
def bisectionDisagreeNarrowsProp (input : PropInput) : Bool :=
  let gameWithPending : LegalKernel.FaultProof.GameState :=
    { input.gs with
        pendingMidpoint := some input.mp,
        turn := .challenger }
  match applyTransition gameWithPending .respondDisagree with
  | .ok gs' =>
    let oldWidth := input.gs.range.high.idx - input.gs.range.low.idx
    let newWidth := gs'.range.high.idx - gs'.range.low.idx
    decide (newWidth < oldWidth)
  | .error _ => false

/-- Property: `submitMidpoint` is deterministic across two fresh
    runs on the same input. -/
def gameDeterminismProp (input : PropInput) : Bool :=
  let r1 := applyTransition input.gs (.submitMidpoint input.mp)
  let r2 := applyTransition input.gs (.submitMidpoint input.mp)
  match r1, r2 with
  | .ok g1, .ok g2 =>
    decide (g1.depth = g2.depth ∧
             g1.range.low.idx = g2.range.low.idx ∧
             g1.range.high.idx = g2.range.high.idx)
  | .error e1, .error e2 => decide (e1 = e2)
  | _, _ => false

/-! ## Test driver entry points -/

/-- Run `bisectionAgreeNarrowsProp` on the configured number of
    samples.  Reads `KNOMOSIS_PROPERTY_SEED` and
    `KNOMOSIS_PROPERTY_ITERATIONS` from the environment. -/
def runBisectionAgreeNarrows : IO Unit := do
  let seed ← readSeed
  let iters ← readIterations
  forAll iters seed genPropInput bisectionAgreeNarrowsProp

/-- Run `bisectionDisagreeNarrowsProp` on the configured number of samples. -/
def runBisectionDisagreeNarrows : IO Unit := do
  let seed ← readSeed
  let iters ← readIterations
  forAll iters seed genPropInput bisectionDisagreeNarrowsProp

/-- Run `gameDeterminismProp` on the configured number of samples. -/
def runGameDeterminism : IO Unit := do
  let seed ← readSeed
  let iters ← readIterations
  forAll iters seed genPropInput gameDeterminismProp

/-- The full property-test suite.  Each property runs
    `defaultIterations` (= 100) samples by default. -/
def tests : List TestCase :=
  [ { name := "bisection-agree-narrows (×100)"
    , body := runBisectionAgreeNarrows
    }
  , { name := "bisection-disagree-narrows (×100)"
    , body := runBisectionDisagreeNarrows
    }
  , { name := "game-determinism (×100)"
    , body := runGameDeterminism
    }
  ]

end LegalKernel.Test.Properties.FaultProof

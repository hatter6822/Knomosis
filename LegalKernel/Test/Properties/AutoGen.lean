/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Properties.AutoGen — Workstream-LX (M3) auto-
generated property-test suite.

LX.38 of `docs/lex_implementation_plan.md`.

This file contains property-test harness invocations
auto-generated from the codegen-input JSON sidecars'
`satisfies` claims.  Each `(law, property)` pair gets one
property test that samples random states and verifies the
property holds.

Currently auto-generated for the four kernel-built-in laws with
the corresponding `satisfies` claims:

  * `conservative` ⇒ random-state property: applying the law
    leaves `TotalSupply` at the law's resource unchanged.
  * `monotonic` ⇒ `TotalSupply` is non-decreasing.
  * `local [r]` ⇒ resources outside `[r]` are pointwise-
    unchanged.
  * `freeze_preserving [r]` ⇒ resources in `[r]` are
    pointwise-unchanged.

# Skip envelope (LX.38)

Each generated test is wrapped in
`if env CANON_AUTOGEN_SKIP = "1" then return ()` so CI can opt
out of the auto-generated tests for fast cycles.

# Generation method

In M3 v1, this file is *hand-written* (mirroring the four
properties listed above) — the auto-generation logic in
`Tools/LexCodegen.lean`'s `--gen-property-tests` flag emits a
file with this same shape from the JSON sidecars.  The
hand-written version doubles as the regression-coverage
fixture.  M4 may replace this with a fully-machine-generated
version produced at build time.
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Freeze

namespace LegalKernel.Test.Properties.AutoGen

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test
open LegalKernel.Test.Property

/-! ## Helpers: random state generation -/

/-- Generate a small `State` with a few balance entries.  V1
    samples bounded balances on resource 0 to keep the property
    space tractable.  `nActors` controls the breadth (default 4). -/
def genTestState (nActors : Nat := 4) (balanceMax : Nat := 100) :
    Gen State := fun st =>
  let rec loop (n : Nat) (s : State) (gs : GenState) : State × GenState :=
    if n = 0 then (s, gs)
    else
      let (bal, gs1) := genNat balanceMax gs
      let actorId : ActorId := UInt64.ofNat (n - 1)
      let s' := setBalance s 0 actorId bal
      loop (n - 1) s' gs1
  loop nActors emptyState st

/-! ## `conservative` property — `TotalSupply` is preserved -/

/-- Auto-generated: `transfer` (Lex re-expression
    `legalkernel.transfer`) satisfies `conservative` ⇒ a random
    state on which the precondition holds is mapped by `transfer`
    to a state with the same `TotalSupply` at the transferred
    resource.

    Property body: `TotalSupply (transfer.apply_impl s) r =
    TotalSupply s r` whenever `transfer.pre s` holds. -/
def transferConservativeProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.transfer.conservative property holds (100 samples)"
  body := do
    -- LX.38 skip envelope: `CANON_AUTOGEN_SKIP=1` skips this test.
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    -- Sample random states; for each, pick a transfer with
    -- amount ∈ [1, balance].  The conservative property holds
    -- whenever the precondition holds.
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let sender : ActorId := 0
      let receiver : ActorId := 1
      let bal := getBalance s r sender
      let amount := if bal > 0 then 1 else 0
      let t := Laws.transfer r sender receiver amount
      -- If the pre fails, the property is vacuously true.
      if _ : t.pre s then
        let s' := step_impl s t
        decide (TotalSupply s r = TotalSupply s' r)
      else
        true)
}

/-- `freezeResource` is `conservative`. -/
def freezeConservativeProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.freezeResource.conservative property holds (100 samples)"
  body := do
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let t := Laws.freezeResource r
      let s' := step_impl s t
      decide (TotalSupply s r = TotalSupply s' r))
}

/-! ## `monotonic` property — `TotalSupply` is non-decreasing -/

/-- `mint` is `monotonic`: applying mint at a resource never
    decreases `TotalSupply` at that resource. -/
def mintMonotonicProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.mint.monotonic property holds (100 samples)"
  body := do
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let recipient : ActorId := 0
      let amount : Amount := 5
      let t := Laws.mint r recipient amount
      if _ : t.pre s then
        let s' := step_impl s t
        decide (TotalSupply s r ≤ TotalSupply s' r)
      else
        true)
}

/-- `transfer` is `monotonic` (vacuously since it's also
    conservative; included for completeness of the property
    coverage matrix). -/
def transferMonotonicProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.transfer.monotonic property holds (100 samples)"
  body := do
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let sender : ActorId := 0
      let receiver : ActorId := 1
      let bal := getBalance s r sender
      let amount := if bal > 0 then 1 else 0
      let t := Laws.transfer r sender receiver amount
      if _ : t.pre s then
        let s' := step_impl s t
        decide (TotalSupply s r ≤ TotalSupply s' r)
      else
        true)
}

/-! ## `local [r]` property — other resources are unchanged -/

/-- `transfer` is `local [r]`: applying transfer at resource `r`
    does not touch balance at any other resource (1 in this
    fixture). -/
def transferLocalProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.transfer.local property holds (100 samples)"
  body := do
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let r' : ResourceId := 1
      let sender : ActorId := 0
      let receiver : ActorId := 1
      let bal := getBalance s r sender
      let amount := if bal > 0 then 1 else 0
      let t := Laws.transfer r sender receiver amount
      if _ : t.pre s then
        let s' := step_impl s t
        -- Property: every actor's balance at r' is unchanged.
        decide (getBalance s r' 0 = getBalance s' r' 0 ∧
                getBalance s r' 1 = getBalance s' r' 1 ∧
                getBalance s r' 2 = getBalance s' r' 2 ∧
                getBalance s r' 3 = getBalance s' r' 3)
      else
        true)
}

/-- `mint` is `local [r]`. -/
def mintLocalProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.mint.local property holds (100 samples)"
  body := do
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let r' : ResourceId := 1
      let recipient : ActorId := 0
      let amount : Amount := 5
      let t := Laws.mint r recipient amount
      if _ : t.pre s then
        let s' := step_impl s t
        decide (getBalance s r' 0 = getBalance s' r' 0 ∧
                getBalance s r' 1 = getBalance s' r' 1 ∧
                getBalance s r' 2 = getBalance s' r' 2)
      else
        true)
}

/-! ## `freeze_preserving [r]` property — frozen resource is unchanged -/

/-- `freezeResource r` is `freeze_preserving [r]`: applying
    `freezeResource` does not touch the balance map for the
    frozen resource. -/
def freezePreservingProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.freezeResource.freeze_preserving holds (100 samples)"
  body := do
    match (← IO.getEnv "CANON_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via CANON_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let t := Laws.freezeResource r
      let s' := step_impl s t
      -- Every actor's balance at r is unchanged.
      decide (getBalance s r 0 = getBalance s' r 0 ∧
              getBalance s r 1 = getBalance s' r 1 ∧
              getBalance s r 2 = getBalance s' r 2 ∧
              getBalance s r 3 = getBalance s' r 3))
}

/-! ## Combined test suite -/

/-- The complete LX.38 auto-generated test suite. -/
def tests : List TestCase :=
  [ transferConservativeProperty,
    freezeConservativeProperty,
    mintMonotonicProperty,
    transferMonotonicProperty,
    transferLocalProperty,
    mintLocalProperty,
    freezePreservingProperty ]

end LegalKernel.Test.Properties.AutoGen

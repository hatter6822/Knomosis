-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Test.AutoGenProperties — Workstream-LX (M3) auto-
generated property-test suite.

LX.38 of `docs/planning/lex_implementation_plan.md`.

**THIS FILE IS AUTO-GENERATED.**  Do not edit by hand.
Re-generate by running:

  lake exe lex_codegen --gen-property-tests

The generator reads `Lex/Inputs/*.json` and
emits one property-test harness invocation per supported
`(law, property)` pair declared in each law's `satisfies`
claims list.

Skip envelope: each test wraps in `KNOMOSIS_AUTOGEN_SKIP=1`
(per §LX.38) so CI can opt out for fast cycles.
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Burn
import LegalKernel.Laws.Reward
import LegalKernel.Laws.Freeze

namespace Lex.Test.AutoGenProperties

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test
open LegalKernel.Test.Property

/-! ## Helpers: random state generation -/

/-- Generate a small `State` with sampled balances across
    multiple resources.  `nActors` controls the breadth
    (default 4); `nResources` is the number of distinct
    resource-id slots populated (default 3 — covers indices
    0, 1, 2).

    Audit-5 fix: pre-fix the generator only populated
    resource 0, which made `local`-property tests trivial
    (e.g. `transferLocalProperty` checks `getBalance s r' a =
    getBalance s' r' a` for `r' = 1`; with all r'=1 balances
    being 0, the test reduced to `0 = 0` — a tautology that
    would silently pass even if `transfer` corrupted other-
    resource state).  Now populates resources 0..nResources-1
    with independently-sampled balances. -/
def genTestState (nActors : Nat := 4) (balanceMax : Nat := 100)
    (nResources : Nat := 3) :
    Gen State := fun st =>
  let rec actorsLoop (r : Nat) (n : Nat) (s : State) (gs : GenState) :
      State × GenState :=
    if n = 0 then (s, gs)
    else
      let (bal, gs1) := genNat balanceMax gs
      let actorId : ActorId := UInt64.ofNat (n - 1)
      let resourceId : ResourceId := UInt64.ofNat r
      let s' := setBalance s resourceId actorId bal
      actorsLoop r (n - 1) s' gs1
  let rec resourcesLoop (r : Nat) (s : State) (gs : GenState) :
      State × GenState :=
    if r = 0 then (s, gs)
    else
      let (s', gs') := actorsLoop (r - 1) nActors s gs
      resourcesLoop (r - 1) s' gs'
  resourcesLoop nResources emptyState st

/-! ## Coverage notes (for pairs not auto-tested) -/

-- legalkernel.transfer.freeze_preserving: out-of-scope for v1 auto-generator
-- legalkernel.transfer.nonce_advances: out-of-scope for v1 auto-generator
-- legalkernel.transfer.registry_preserving: out-of-scope for v1 auto-generator
-- legalkernel.mint.freeze_preserving: out-of-scope for v1 auto-generator
-- legalkernel.mint.nonce_advances: out-of-scope for v1 auto-generator
-- legalkernel.mint.registry_preserving: out-of-scope for v1 auto-generator
-- legalkernel.burn.local: out-of-scope for v1 auto-generator
-- legalkernel.burn.freeze_preserving: out-of-scope for v1 auto-generator
-- legalkernel.burn.nonce_advances: out-of-scope for v1 auto-generator
-- legalkernel.burn.registry_preserving: out-of-scope for v1 auto-generator
-- legalkernel.freezeResource.local: out-of-scope for v1 auto-generator
-- legalkernel.freezeResource.nonce_advances: out-of-scope for v1 auto-generator
-- legalkernel.freezeResource.registry_preserving: out-of-scope for v1 auto-generator
-- legalkernel.replaceKey: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.reward.monotonic: out-of-scope for v1 auto-generator
-- legalkernel.reward.local: out-of-scope for v1 auto-generator
-- legalkernel.reward.freeze_preserving: out-of-scope for v1 auto-generator
-- legalkernel.reward.nonce_advances: out-of-scope for v1 auto-generator
-- legalkernel.reward.registry_preserving: out-of-scope for v1 auto-generator
-- legalkernel.distributeOthers: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.proportionalDilute: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.dispute: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.disputeWithdraw: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.verdict: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.rollback: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.registerIdentity: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.deposit: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.withdraw: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.declareLocalPolicy: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- legalkernel.revokeLocalPolicy: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- reserved.gp.ammSwap: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only
-- reserved.gp.reclaimAmmReserves: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only

/-- Auto-gen LX.38: legalkernel.transfer.conservative property holds (100 samples). -/
def legalkernel_transferConservativeProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.transfer.conservative property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
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
        decide (TotalSupply s r = TotalSupply s' r)
      else true)
}

/-- Auto-gen LX.38: legalkernel.transfer.monotonic property holds (100 samples). -/
def legalkernel_transferMonotonicProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.transfer.monotonic property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
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
      else true)
}

/-- Auto-gen LX.38: legalkernel.transfer.local property holds (100 samples). -/
def legalkernel_transferLocalProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.transfer.local property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
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
        decide (getBalance s r' 0 = getBalance s' r' 0 ∧
                getBalance s r' 1 = getBalance s' r' 1)
      else true)
}

/-- Auto-gen LX.38: legalkernel.mint.monotonic property holds (100 samples). -/
def legalkernel_mintMonotonicProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.mint.monotonic property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
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
      else true)
}

/-- Auto-gen LX.38: legalkernel.mint.local property holds (100 samples). -/
def legalkernel_mintLocalProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.mint.local property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
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
        decide (getBalance s r' 0 = getBalance s' r' 0)
      else true)
}

/-- Auto-gen LX.38: legalkernel.freezeResource.conservative property holds (100 samples). -/
def legalkernel_freezeResourceConservativeProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.freezeResource.conservative property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
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

/-- Auto-gen LX.38: legalkernel.freezeResource.monotonic property holds (100 samples). -/
def legalkernel_freezeResourceMonotonicProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.freezeResource.monotonic property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let t := Laws.freezeResource r
      let s' := step_impl s t
      decide (TotalSupply s r ≤ TotalSupply s' r))
}

/-- Auto-gen LX.38: legalkernel.freezeResource.freeze_preserving property holds (100 samples). -/
def legalkernel_freezeResourceFreezePreservingProperty : TestCase := {
  name := "auto-gen LX.38: legalkernel.freezeResource.freeze_preserving property holds (100 samples)"
  body := do
    match (← IO.getEnv "KNOMOSIS_AUTOGEN_SKIP") with
    | some "1" =>
      IO.println "  (skipped via KNOMOSIS_AUTOGEN_SKIP=1)"
      return ()
    | _ => pure ()
    let seed ← readSeed
    let n ← readIterations
    forAll (T := State) n seed (genTestState 4 50) (fun s =>
      let r : ResourceId := 0
      let t := Laws.freezeResource r
      let s' := step_impl s t
      decide (getBalance s r 0 = getBalance s' r 0 ∧
              getBalance s r 1 = getBalance s' r 1))
}

/-! ## Combined test suite -/

/-- The complete LX.38 auto-generated test suite. -/
def tests : List TestCase :=
  [ legalkernel_transferConservativeProperty,
    legalkernel_transferMonotonicProperty,
    legalkernel_transferLocalProperty,
    legalkernel_mintMonotonicProperty,
    legalkernel_mintLocalProperty,
    legalkernel_freezeResourceConservativeProperty,
    legalkernel_freezeResourceMonotonicProperty,
    legalkernel_freezeResourceFreezePreservingProperty ]

end Lex.Test.AutoGenProperties

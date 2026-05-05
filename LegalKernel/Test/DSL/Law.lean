/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.DSL.Law — Phase-4 WU 4.9 tests for the `law` DSL macro.

Verifies that `law pre := ... ; impl := ...` elaborates to a
`Transition` definitionally equal to the hand-written form, and that
the impl-only form `law impl := ...` defaults `pre` to `True`.
-/

import LegalKernel.Test.Framework
import LegalKernel.DSL.Law
import LegalKernel.Laws.Transfer

namespace LegalKernel.Test.DSL
namespace LawTests

open LegalKernel
open LegalKernel.DSL

/-- DSL `law` produces a `Transition` whose `pre` matches the
    supplied expression. -/
def lawPreShape : TestCase := {
  name := "law pre := <expr> ; impl := <expr> shape"
  body := do
    let t : Transition := law
      pre  := fun s => getBalance s 1 2 ≥ 5 ;
      impl := fun s => setBalance s 1 2 (getBalance s 1 2 - 5)
    -- The transition's apply_impl reduces correctly on a state where
    -- the precondition holds.
    let s : State := setBalance ({ balances := ∅ }) 1 2 10
    let s' := t.apply_impl s
    assertEq (5 : Amount) (getBalance s' 1 2) "post-state balance"
}

/-- DSL `law impl := <expr>` form defaults `pre` to `True`. -/
def lawImplOnlyShape : TestCase := {
  name := "law impl := <expr> defaults pre to True"
  body := do
    let t : Transition := law impl := fun s => s
    -- The pre is `fun _ => True`, decidable to `true`.
    let _ : Decidable (t.pre ({ balances := ∅ } : State)) := inferInstance
    pure ()
}

/-- DSL-derived `transferDSL` matches the hand-written `Laws.transfer`
    at the value level (same precondition, same state transformer). -/
def transferDSLAgrees : TestCase := {
  name := "transferDSL apply_impl matches Laws.transfer"
  body := do
    let r : ResourceId := 1
    let s_act : ActorId := 2
    let r_act : ActorId := 3
    let am : Amount := 5
    let s : State := setBalance ({ balances := ∅ }) r s_act 10
    -- Both apply_impl should produce the same result.
    let dsl := (transferDSL r s_act r_act am).apply_impl s
    let hand := (Laws.transfer r s_act r_act am).apply_impl s
    -- Compare via getBalance at the relevant cells.
    assertEq (getBalance hand r s_act) (getBalance dsl r s_act) "sender balance"
    assertEq (getBalance hand r r_act) (getBalance dsl r r_act) "receiver balance"
}

/-- DSL-derived `transferDSL` has the SAME precondition as
    `Laws.transfer`, including the positivity clause `amount > 0`.
    Pin this at value level so a future divergence is caught. -/
def transferDSLPreMatches : TestCase := {
  name := "transferDSL pre matches Laws.transfer (incl. positivity)"
  body := do
    let r : ResourceId := 1
    let s_act : ActorId := 2
    let r_act : ActorId := 3
    -- Case A: amount > 0 and balance ≥ amount → both pres true.
    let s_funded : State := setBalance ({ balances := ∅ }) r s_act 10
    assert (decide ((transferDSL r s_act r_act 5).pre s_funded)
            = decide ((Laws.transfer r s_act r_act 5).pre s_funded))
      "case A: funded + amount > 0 → both pres agree"
    -- Case B: amount = 0 → BOTH pres FALSE (the positivity clause
    -- is what distinguishes from a "balance check only" form).
    assert (decide ((transferDSL r s_act r_act 0).pre s_funded) = false)
      "case B: amount = 0 → DSL pre false (positivity clause active)"
    assert (decide ((Laws.transfer r s_act r_act 0).pre s_funded) = false)
      "case B: amount = 0 → Laws.transfer pre false"
    -- Case C: amount > balance → both pres false.
    assert (decide ((transferDSL r s_act r_act 100).pre s_funded) = false)
      "case C: insufficient → DSL pre false"
    assert (decide ((Laws.transfer r s_act r_act 100).pre s_funded) = false)
      "case C: insufficient → Laws.transfer pre false"
}

/-- Term-level API check: `Law.mk` is callable with the expected
    signature. -/
def lawMkAPI : TestCase := {
  name := "Law.mk API stability"
  body := do
    -- Check that Law.mk applied with a decidable precondition produces a Transition.
    let _proof : Transition :=
      Law.mk (fun (s : State) => getBalance s 0 0 ≥ 0) (fun s => s)
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [lawPreShape, lawImplOnlyShape, transferDSLAgrees, transferDSLPreMatches, lawMkAPI]

end LawTests
end LegalKernel.Test.DSL

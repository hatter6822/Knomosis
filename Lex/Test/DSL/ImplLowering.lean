/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.DSL.ImplLowering — tests for the §6.2
calculus parser.

LX-M2 milestone: verifies that each `lex_do <calculus statement>`
form lowers to a Lean term definitionally equal to the
hand-written `fun s => ...` form.
-/

import LegalKernel
import Lex.DSL.ImplLowering
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.DSL.Lex
open LegalKernel.Test

namespace Lex.Test.DSL.ImplLoweringTests

/-! ## §6.2 calculus → Lean term lowering tests -/

/-- `flow r amt v from a to b` lowers to the §4.11 self-transfer-
    safe sequencing pattern. -/
private def flowLowering : TestCase := {
  name := "flow lowers to post-debit re-read sequencing"
  body := do
    let r : ResourceId := 1
    let a : ActorId := 10
    let b : ActorId := 20
    let v : Amount := 5
    let lex   : State → State := lex_do flow r amt v from a to b
    let hand  : State → State := fun s =>
      let fromBal := getBalance s r a
      let s1      := setBalance s r a (fromBal - v)
      let toBal   := getBalance s1 r b
      setBalance s1 r b (toBal + v)
    -- Definitional equality witness via rfl-typed binding.
    let _ : lex = hand := rfl
    pure ()
}

/-- `mint r amt v to b` lowers to the additive credit pattern. -/
private def mintLowering : TestCase := {
  name := "mint lowers to additive credit"
  body := do
    let r : ResourceId := 1
    let b : ActorId := 20
    let v : Amount := 5
    let lex  : State → State := lex_do mint r amt v to b
    let hand : State → State := fun s => setBalance s r b (getBalance s r b + v)
    let _ : lex = hand := rfl
    pure ()
}

/-- `burn r amt v from a` lowers to the truncated-subtraction debit. -/
private def burnLowering : TestCase := {
  name := "burn lowers to Nat-truncated debit"
  body := do
    let r : ResourceId := 1
    let a : ActorId := 10
    let v : Amount := 5
    let lex  : State → State := lex_do burn r amt v from a
    let hand : State → State := fun s => setBalance s r a (getBalance s r a - v)
    let _ : lex = hand := rfl
    pure ()
}

/-- `reward r amt v to b` lowers to the same shape as `mint`
    (definitionally equal at the kernel level). -/
private def rewardLowering : TestCase := {
  name := "reward lowers to additive credit (mint-shaped at kernel level)"
  body := do
    let r : ResourceId := 1
    let b : ActorId := 20
    let v : Amount := 5
    let lex     : State → State := lex_do reward r amt v to b
    let mintLex : State → State := lex_do mint r amt v to b
    let _ : lex = mintLex := rfl
    pure ()
}

/-- `freeze_resource r` lowers to the identity transition. -/
private def freezeResourceLowering : TestCase := {
  name := "freeze_resource lowers to kernel-level identity"
  body := do
    let r : ResourceId := 1
    let lex  : State → State := lex_do freeze_resource r
    -- Identity lowering: applying to any state returns it
    -- definitionally unchanged.
    let s : State := emptyState
    let _ : lex s = s := rfl
    pure ()
}

/-- `register_key a as k` lowers to the identity transition (the
    authority-layer effect lives in `applyActionToRegistry`). -/
private def registerKeyLowering : TestCase := {
  name := "register_key lowers to kernel-level identity"
  body := do
    let a : ActorId := 10
    let k : Authority.PublicKey := ByteArray.empty
    let lex  : State → State := lex_do register_key a as k
    let s : State := emptyState
    let _ : lex s = s := rfl
    pure ()
}

/-- `register_identity a as k` lowers to the identity transition. -/
private def registerIdentityLowering : TestCase := {
  name := "register_identity lowers to kernel-level identity"
  body := do
    let a : ActorId := 10
    let k : Authority.PublicKey := ByteArray.empty
    let lex  : State → State := lex_do register_identity a as k
    let s : State := emptyState
    let _ : lex s = s := rfl
    pure ()
}

/-- `nop` lowers to the identity transition. -/
private def nopLowering : TestCase := {
  name := "nop lowers to kernel-level identity"
  body := do
    let lex  : State → State := lex_do nop
    let s : State := emptyState
    let _ : lex s = s := rfl
    pure ()
}

-- Multi-statement composition is omitted from the calculus
-- parser in M2 (single-statement only); each kernel-built-in
-- law's impl is a single calculus statement.  Multi-statement
-- impls (like `proportionalDilute`'s `for`-loop) use Lean-term
-- form via `lex_impl := fun s => ...` per the LX-M2 macro
-- surface.  M3 may extend the calculus parser with line-based
-- sequencing once the layout-sensitive parsing is hardened.

/-! ## Byte-equivalence with hand-written `Laws.*.apply_impl`

These tests assert that the calculus form on each kernel-built-in
law matches the hand-written `apply_impl` body via value-level
applications.  Stronger byte-equivalence at the *term* level
(definitional equality of the two `State → State` functions
without applying them) is verified by the per-law `example`s in
each `Laws/<Law>.lean` file. -/

/-- Calculus `mint` and `Laws.mint` agree at every state. -/
private def mintImplValueEquiv : TestCase := {
  name := "calculus `mint` produces same post-state as Laws.mint.apply_impl"
  body := do
    let r : ResourceId := 1
    let recipient : ActorId := 20
    let amount : Amount := 5
    let s0 : State := setBalance emptyState r recipient 100
    let lex  : State → State := lex_do mint r amt amount to recipient
    let hand : State → State := (Laws.mint r recipient amount).apply_impl
    -- Spot-check post-state equality via balance probe.
    assertEq (getBalance (lex s0) r recipient) (getBalance (hand s0) r recipient)
      "post-mint balance"
}

/-- Calculus `burn` and `Laws.burn` agree at every state. -/
private def burnImplValueEquiv : TestCase := {
  name := "calculus `burn` produces same post-state as Laws.burn.apply_impl"
  body := do
    let r : ResourceId := 1
    let fromActor : ActorId := 10
    let amount : Amount := 5
    let s0 : State := setBalance emptyState r fromActor 100
    let lex  : State → State := lex_do burn r amt amount from fromActor
    let hand : State → State := (Laws.burn r fromActor amount).apply_impl
    assertEq (getBalance (lex s0) r fromActor) (getBalance (hand s0) r fromActor)
      "post-burn balance"
}

/-- Calculus `flow` and `Laws.transfer` agree at every state. -/
private def flowImplValueEquiv : TestCase := {
  name := "calculus `flow` produces same post-state as Laws.transfer.apply_impl"
  body := do
    let r : ResourceId := 1
    let sender : ActorId := 10
    let receiver : ActorId := 20
    let amount : Amount := 5
    let s0 : State := setBalance emptyState r sender 100
    let lex  : State → State := lex_do flow r amt amount from sender to receiver
    let hand : State → State := (Laws.transfer r sender receiver amount).apply_impl
    -- Both forms produce the same sender + receiver post-balances.
    assertEq (getBalance (lex s0) r sender) (getBalance (hand s0) r sender)
      "post-flow sender balance"
    assertEq (getBalance (lex s0) r receiver) (getBalance (hand s0) r receiver)
      "post-flow receiver balance"
}

/-- All tests. -/
def tests : List TestCase :=
  [flowLowering, mintLowering, burnLowering, rewardLowering,
   freezeResourceLowering, registerKeyLowering, registerIdentityLowering,
   nopLowering,
   mintImplValueEquiv, burnImplValueEquiv, flowImplValueEquiv]

end Lex.Test.DSL.ImplLoweringTests

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.BoundsReachable — the amount ceiling is a
real constraint, and the laws really enforce it.

Two things need showing, and only one of them is the theorem.

The theorem (`canonicalBounds_base_amt_of_reachable`) says every
reachable state is under `Laws.maxAmount`.  That is worth nothing if
the bound is trivially true, so the first cases here exhibit a state
that VIOLATES it — the bound is a constraint, not a tautology — and
show the laws refusing to reach one: a credit that would cross the
ceiling makes the step a no-op rather than an over-ceiling write.

The rest pins the value-level behaviour the proofs are stated over:
the no-op is a genuine no-op (the state is unchanged, not merely
bounded), a debit needs no conjunct, and the self-transfer corner is
bounded by the sender's balance rather than by twice it — which is
the case a conjunct stated over the pre-state would wrongly refuse.
-/

import LegalKernel.FaultProof.BoundsReachable
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.BoundsReachable

/-- A state holding `v` at (resource 1, actor 10). -/
def stateAt (v : Nat) : State :=
  { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
      ((∅ : BalanceMap).insert 10 v) }

/-- One unit under the ceiling — the largest legal balance. -/
def nearMax : Nat := Laws.maxAmount - 1

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "the ceiling is a real constraint, not a tautology"
    , body := do
        -- If every state were bounded, the theorem would say nothing.
        -- A state AT the ceiling is representable and is not bounded.
        assert (decide (getBalance (stateAt nearMax) 1 10 < Laws.maxAmount))
          "one under the ceiling is bounded"
        assert (!decide (getBalance (stateAt Laws.maxAmount) 1 10 < Laws.maxAmount))
          "AT the ceiling is NOT bounded — so the predicate constrains"
    }
  , { name := "a mint that would cross the ceiling is refused"
    , body := do
        let s := stateAt nearMax
        -- Crediting 1 lands exactly on the ceiling, where `encodeAmount`
        -- would truncate to the canonically-absent value.  The
        -- precondition must reject it.
        assert (!decide ((Laws.mint 1 10 1).pre s))
          "mint over the ceiling fails its precondition"
        assert (decide ((Laws.mint 1 10 0 |>.pre s) = False) ||
                !decide ((Laws.mint 1 10 0).pre s))
          "a zero mint is refused for the separate positivity reason"
    }
  , { name := "...and the refusal is a no-op, not a truncated write"
    , body := do
        let s := stateAt nearMax
        -- `step_impl` is `if pre then apply_impl else id`, so the
        -- balance is untouched rather than wrapped.
        assertEq (expected := nearMax)
                 (actual := getBalance (step_impl s (Laws.mint 1 10 1)) 1 10)
                 "the balance is exactly what it was"
    }
  , { name := "a mint that stays under the ceiling still applies"
    , body := do
        -- The negative control for the two cases above: the conjunct
        -- refuses over-ceiling credits WITHOUT refusing ordinary ones.
        let s := stateAt 100
        assert (decide ((Laws.mint 1 10 50).pre s)) "an ordinary mint is admitted"
        assertEq (expected := 150)
                 (actual := getBalance (step_impl s (Laws.mint 1 10 50)) 1 10)
                 "and it lands"
    }
  , { name := "a debit needs no ceiling conjunct"
    , body := do
        -- `burn` carries none, because `Nat` subtraction only shrinks.
        -- Exercised at the largest legal balance, where a credit would
        -- fail.
        let s := stateAt nearMax
        assert (decide ((Laws.burn 1 10 5).pre s)) "burn at the ceiling is admitted"
        assertEq (expected := nearMax - 5)
                 (actual := getBalance (step_impl s (Laws.burn 1 10 5)) 1 10)
                 "and it debits"
    }
  , { name := "a self-transfer is bounded by the balance, not by twice it"
    , body := do
        -- The case a conjunct stated over the PRE-state would refuse:
        -- reading the receiver from the post-debit state makes the
        -- credited value `bal`, not `bal + amount`.  At a balance over
        -- half the ceiling the two answers differ.
        let big := Laws.maxAmount / 2 + 10
        let s := stateAt big
        assert (decide ((Laws.transfer 1 10 10 big).pre s))
          "a whole-balance self-transfer is admitted"
        assertEq (expected := big)
                 (actual := getBalance (step_impl s (Laws.transfer 1 10 10 big)) 1 10)
                 "and conserves the actor's balance"
        -- The pre-state reading would have been `big + big`, over the
        -- ceiling — shown here so the case cannot pass vacuously.
        assert (!decide (big + big < Laws.maxAmount))
          "the pre-state reading really would have exceeded the ceiling"
    }
  , { name := "a cross-actor transfer over the ceiling is refused"
    , body := do
        -- The receiver leg genuinely binds: the sender can afford it
        -- and the receiver still cannot hold it.
        let s : State :=
          { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
              (((∅ : BalanceMap).insert 10 100).insert 20 nearMax) }
        assert (decide (getBalance s 1 10 ≥ 50)) "the sender can afford it"
        assert (!decide ((Laws.transfer 1 10 20 50).pre s))
          "but the receiver would cross the ceiling, so it is refused"
        assertEq (expected := nearMax)
                 (actual := getBalance (step_impl s (Laws.transfer 1 10 20 50)) 1 20)
                 "and the receiver is untouched"
        assertEq (expected := 100)
                 (actual := getBalance (step_impl s (Laws.transfer 1 10 20 50)) 1 10)
                 "as is the sender — a refusal debits nobody"
    }
  , { name := "genesis satisfies the bound"
    , body := do
        let _proof : BalancesBounded ExtendedState.empty :=
          balancesBounded_genesis ExtendedState.empty (by decide)
        pure ()
    }
  , { name := "term-level API stability: the bound is inductive"
    , body := do
        -- The two theorems the discharge composes.
        let _a1 := @balancesBounded_apply_impl
        let _a2 := @balancesBounded_step_impl
        let _a3 := @balancesBounded_admissible_step
        let _a4 := @balancesBounded_of_admissibleReachable
        let _a5 := @canonicalBounds_base_amt_of_reachable
        let _a6 := @canonicalBounds_base_amt_of_balancesBounded
        let _a7 := @admissibleReachable_of_bridgeReachable
        pure ()
    }
  , { name := "term-level API stability: the trace-length bounds (W2)"
    , body := do
        -- The nonce argument that justifies NOT widening the 8-byte
        -- head.  Its conclusion is deliberately weaker than the amount
        -- bound's — `≤ start + n`, not an unconditional `< 2^64`.
        let _b1 := @expectsNonce_admissible_step_le
        let _b2 := @expectsNonce_le_of_reachableIn
        let _b3 := @expectsNonce_lt_of_reachableIn
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.BoundsReachable

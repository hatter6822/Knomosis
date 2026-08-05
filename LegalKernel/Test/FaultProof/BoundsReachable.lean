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
        -- The theorems the discharge composes.  Ascribed, not merely
        -- named: a bare `let _ := @thm` pins only that the NAME still
        -- exists, and what this suite has to catch is the bound itself
        -- weakening — `< maxAmount` drifting, or a hypothesis being
        -- added to the induction.
        let _a1 : ∀ (a : Action) (signer : ActorId) (s : State),
            (∀ (r : ResourceId) (a' : ActorId), getBalance s r a' < Laws.maxAmount) →
            (a.toTransition signer).pre s →
            ∀ (r : ResourceId) (a' : ActorId),
              getBalance ((a.toTransition signer).apply_impl s) r a' < Laws.maxAmount :=
          balancesBounded_apply_impl
        let _a2 : ∀ (a : Action) (signer : ActorId) (s : State),
            (∀ (r : ResourceId) (a' : ActorId), getBalance s r a' < Laws.maxAmount) →
            ∀ (r : ResourceId) (a' : ActorId),
              getBalance (step_impl s (a.toTransition signer)) r a' < Laws.maxAmount :=
          balancesBounded_step_impl
        let _a3 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
            (st : SignedAction) (idx : Nat)
            (h : Bridge.BridgeAdmissibleWith verify P d es st),
            BalancesBounded es →
            BalancesBounded
              (Bridge.apply_bridge_admissible_with verify P d es st idx h) :=
          fun _ _ _ _ _ _ h hb => balancesBounded_admissible_step h hb
        let _a4 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (es es' : ExtendedState),
            BalancesBounded es →
            AdmissibleReachable verify P d es es' →
            BalancesBounded es' :=
          fun _ _ _ _ _ hb hr => balancesBounded_of_admissibleReachable hb hr
        let _a5 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (es es' : ExtendedState),
            BalancesBounded es →
            AdmissibleReachable verify P d es es' →
            ∀ (p : ResourceId × BalanceMap), p ∈ es'.base.balances.toList →
            ∀ (q : ActorId × Amount), q ∈ Std.TreeMap.toList p.snd →
              q.snd < 256 ^ 32 :=
          fun _ _ _ _ _ hb hr => canonicalBounds_base_amt_of_reachable hb hr
        let _a6 : ∀ (es : ExtendedState),
            BalancesBounded es →
            ∀ (p : ResourceId × BalanceMap), p ∈ es.base.balances.toList →
            ∀ (q : ActorId × Amount), q ∈ Std.TreeMap.toList p.snd →
              q.snd < 256 ^ 32 :=
          canonicalBounds_base_amt_of_balancesBounded
        let _a7 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (es es' : ExtendedState),
            Bridge.BridgeReachable verify P d es es' →
            AdmissibleReachable verify P d es es' :=
          fun _ _ _ _ _ hr => admissibleReachable_of_bridgeReachable hr
        pure ()
    }
  , { name := "term-level API stability: the trace-length bounds (W2)"
    , body := do
        -- The nonce argument that justifies NOT widening the 8-byte
        -- head.  Its conclusion is deliberately weaker than the amount
        -- bound's — `≤ start + n`, not an unconditional `< 2^64`.
        let _b1 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
            (st : SignedAction) (idx : Nat)
            (h : Bridge.BridgeAdmissibleWith verify P d es st) (a : ActorId),
            expectsNonce
                (Bridge.apply_bridge_admissible_with verify P d es st idx h) a
              ≤ expectsNonce es a + 1 :=
          fun _ _ _ _ _ _ h a => expectsNonce_admissible_step_le h a
        -- The `+ n` in the conclusion is the point of the ascription:
        -- an unascribed pin would survive this weakening to `+ 2 * n`.
        let _b2 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (n : Nat)
            (es es' : ExtendedState),
            AdmissibleReachableIn verify P d n es es' →
            ∀ (a : ActorId), expectsNonce es' a ≤ expectsNonce es a + n :=
          fun _ _ _ _ _ _ hr => expectsNonce_le_of_reachableIn hr
        let _b3 : ∀ (verify : PublicKey → ByteArray → Signature → Bool)
            (P : AuthorityPolicy) (d : ByteArray) (n : Nat)
            (es es' : ExtendedState),
            AdmissibleReachableIn verify P d n es es' →
            ∀ (a : ActorId), expectsNonce es a = 0 → n < 256 ^ 8 →
              expectsNonce es' a < 256 ^ 8 :=
          fun _ _ _ _ _ _ hr => expectsNonce_lt_of_reachableIn hr
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.BoundsReachable

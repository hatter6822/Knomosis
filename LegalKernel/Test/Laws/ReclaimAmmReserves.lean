-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.ReclaimAmmReserves — Workstream GP.11.10
acceptance tests for the post-disable AMM reserve reclamation.

Exercises the `Laws.reclaimAmmReserves` exact-sweep law (precondition
semantics, the drain-to-zero / pool-credit shape, conservation at
every resource, locality, freeze preservation), the GP.11.10
admission gate (`BridgeAdmissibleWith` conjunct 9: the sweep is
inadmissible while the L2 `ammDisabled` mirror is unset, and the
threaded actors are pinned to the canonical reserved slots), the
mirror step-invariance theorems, the action/event frozen-index wiring
(CBE round-trips for Action 24 and Event 22), and term-level API
stability for every headline theorem.
-/

import LegalKernel.Laws.ReclaimAmmReserves
import LegalKernel.Bridge.Admissible
import LegalKernel.Bridge.AmmReservePolicy
import LegalKernel.Events.Extract
import LegalKernel.Encoding.Event
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Events
open LegalKernel.Test

namespace LegalKernel.Test.Laws.ReclaimAmmReservesTests

/-- Tests for the `reclaimAmmReserves` law and its GP.11.10 wiring. -/
def tests : List TestCase :=
  [ -- ## Precondition semantics (the exact-sweep discipline)
    { name := "precondition: holds at the exact sweep (balance = amount)"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 5000 3 1
        assert (decide (t.pre s)) "pre holds when amount equals the entire balance"
    }
  , { name := "precondition: fails on a partial sweep (amount < balance)"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 4999 3 1
        assert (¬ decide (t.pre s)) "pre fails: partial drains are impossible by construction"
    }
  , { name := "precondition: fails on an over-sweep (amount > balance)"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 5001 3 1
        assert (¬ decide (t.pre s)) "pre fails: cannot sweep more than the balance"
    }
  , { name := "precondition: fails when reserveActor = poolActor"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 5000 3 3
        assert (¬ decide (t.pre s)) "pre fails: self-sweep rejected"
    }
  , { name := "precondition: fails on a zero-amount sweep"
    , body := do
        let t := reclaimAmmReserves 0 0 3 1
        assert (¬ decide (t.pre emptyState)) "pre fails: amount must be positive"
    }
  , { name := "precondition: a second sweep of a drained reserve fails"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 5000 3 1
        let s' := step_impl s t
        -- The reserve now reads 0, so no positive `amount` satisfies
        -- the exact-sweep precondition: replays are self-defeating.
        assert (¬ decide ((reclaimAmmReserves 0 5000 3 1).pre s'))
          "drained reserve rejects the same sweep"
        assert (¬ decide ((reclaimAmmReserves 0 1 3 1).pre s'))
          "drained reserve rejects any positive sweep"
    }
    -- ## The sweep shape (drain-to-zero + pool credit)
  , { name := "sweep: reserve drains to exactly 0"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 5000 3 1
        assertEq (expected := 0) (actual := getBalance (step_impl s t) 0 3)
          "reserve balance is zero after the sweep"
    }
  , { name := "sweep: pool is credited exactly the swept amount"
    , body := do
        let s0 := setBalance emptyState 0 3 5000
        let s := setBalance s0 0 1 700
        let t := reclaimAmmReserves 0 5000 3 1
        assertEq (expected := 5700) (actual := getBalance (step_impl s t) 0 1)
          "pool balance is old + amount"
    }
  , { name := "sweep: other actors untouched at the swept resource"
    , body := do
        let s0 := setBalance emptyState 0 3 5000
        let s := setBalance s0 0 9 123
        let t := reclaimAmmReserves 0 5000 3 1
        assertEq (expected := 123) (actual := getBalance (step_impl s t) 0 9)
          "bystander balance unchanged"
    }
  , { name := "sweep: other resources untouched"
    , body := do
        let s0 := setBalance emptyState 0 3 5000
        let s := setBalance s0 1 3 888
        let t := reclaimAmmReserves 0 5000 3 1
        assertEq (expected := 888) (actual := getBalance (step_impl s t) 1 3)
          "the reserve's OTHER-resource balance unchanged"
    }
  , { name := "sweep: no-op when the precondition fails"
    , body := do
        let s := setBalance emptyState 0 3 5000
        let t := reclaimAmmReserves 0 4999 3 1 -- partial: pre fails
        assertEq (expected := 5000) (actual := getBalance (step_impl s t) 0 3)
          "no silent partial application"
    }
    -- ## Conservation (the headline classification: unlike ammSwap,
    -- the sweep IS conservative)
  , { name := "conservation: TotalSupply unchanged at the swept resource"
    , body := do
        let s0 := setBalance emptyState 0 3 5000
        let s := setBalance s0 0 1 700
        let t := reclaimAmmReserves 0 5000 3 1
        assertEq (expected := TotalSupply s 0)
          (actual := TotalSupply (step_impl s t) 0)
          "the debit and the credit cancel exactly"
    }
  , { name := "conservation: TotalSupply unchanged at other resources"
    , body := do
        let s0 := setBalance emptyState 0 3 5000
        let s := setBalance s0 1 7 999
        let t := reclaimAmmReserves 0 5000 3 1
        assertEq (expected := TotalSupply s 1)
          (actual := TotalSupply (step_impl s t) 1)
          "cross-resource independence"
    }
  , { name := "IsConservative instance exists (term-level)"
    , body := do
        let _inst : IsConservative (reclaimAmmReserves 0 5000 3 1) := inferInstance
        pure ()
    }
  , { name := "IsMonotonic follows via monotonic_of_conservative (term-level)"
    , body := do
        let _inst : IsMonotonic (reclaimAmmReserves 0 5000 3 1) := inferInstance
        pure ()
    }
  , { name := "LocalTo [r] instance exists (term-level)"
    , body := do
        let _inst : LocalTo [0] (reclaimAmmReserves 0 5000 3 1) := inferInstance
        pure ()
    }
    -- ## Headline theorem API pins
  , { name := "reclaimAmmReserves_zeroes_reserve API stable"
    , body := do
        let _ := @reclaimAmmReserves_zeroes_reserve
        assert true "API exists"
    }
  , { name := "reclaimAmmReserves_credits_pool API stable"
    , body := do
        let _ := @reclaimAmmReserves_credits_pool
        assert true "API exists"
    }
  , { name := "reclaimAmmReserves_conserves_at API stable"
    , body := do
        let _ := @reclaimAmmReserves_conserves_at
        assert true "API exists"
    }
  , { name := "reclaimAmmReserves_other_actor_untouched API stable"
    , body := do
        let _ := @reclaimAmmReserves_other_actor_untouched
        assert true "API exists"
    }
    -- ## Action wiring (frozen index 24)
  , { name := "Action.compileTransition maps reclaimAmmReserves to the law"
    , body := do
        let _proof :
            Action.compileTransition (.reclaimAmmReserves 0 5000 3 1) =
            reclaimAmmReserves 0 5000 3 1 := rfl
        pure ()
    }
  , { name := "Action 24 CBE round-trips"
    , body := do
        let a : Action := .reclaimAmmReserves 0 5000 3 1
        match Encoding.Encodable.decode (T := Action)
                (Encoding.Encodable.encode (T := Action) a) with
        | .ok (a', rest) =>
            assert (rest == []) "no trailing bytes"
            assert (a' == a) "reclaimAmmReserves round-trips"
        | .error e => throw <| IO.userError s!"decode failed: {repr e}"
    }
  , { name := "Action.isBridgeOnly classifies reclaimAmmReserves bridge-only"
    , body := do
        assertEq (expected := true)
          (actual := Action.isBridgeOnly (.reclaimAmmReserves 0 5000 3 1))
          "the sweep is a bridge attestation"
    }
  , { name := "bridgeAuthorizedAction authorises reclaimAmmReserves"
    , body := do
        assertEq (expected := true)
          (actual := bridgeAuthorizedAction (.reclaimAmmReserves 0 5000 3 1))
          "isBridgeOnly ⊆ bridgeAuthorizedAction holds for the sweep"
    }
  , { name := "gasPoolPolicy + ammReservePolicy both deny signing tag 24"
    , body := do
        -- Neither reserved actor may SIGN the sweep (it is
        -- bridge-signed): tag 24 is in both deny-lists.
        assert ((24 : Nat) ∈ gasPoolDeniedTags) "pool actor denied tag 24"
        assert ((24 : Nat) ∈ ammReserveDeniedTags) "reserve actor denied tag 24"
    }
    -- ## Event wiring (frozen index 22)
  , { name := "extractEvents emits ammReservesReclaimed (tag 22)"
    , body := do
        let es := { ExtendedState.empty with
          base := setBalance ExtendedState.empty.base 0 3 5000 }
        let st : SignedAction :=
          { action := .reclaimAmmReserves 0 5000 3 1,
            signer := bridgeActor, nonce := 0, sig := ByteArray.empty }
        let post := { es with
          base := step_impl es.base (reclaimAmmReserves 0 5000 3 1) }
        let evs := Events.extractEvents es post st
        assert (evs.any (fun e => Event.tag e == 22))
          "the semantic ammReservesReclaimed event is emitted"
        assert (evs.any (fun e =>
          e == Event.ammReservesReclaimed 0 5000 3 1))
          "the event carries the full sweep payload"
    }
  , { name := "Event 22 CBE round-trips"
    , body := do
        let e : Event := .ammReservesReclaimed 0 123456 3 1
        match Encoding.Encodable.decode (T := Event)
                (Encoding.Encodable.encode (T := Event) e) with
        | .ok (e', rest) =>
            assert (rest == []) "no trailing bytes"
            assert (e' == e) "ammReservesReclaimed round-trips"
        | .error e => throw <| IO.userError s!"decode failed: {repr e}"
    }
    -- ## GP.11.10 admission gate (BridgeAdmissibleWith conjunct 9)
  , { name := "admission: sweep inadmissible while ammDisabled mirror is unset"
    , body := do
        -- `reclaim_inadmissible_while_amm_enabled` at the value level:
        -- a genesis state (ammDisabled = false) decides the bridge
        -- admissibility of ANY reclaim signed action to false, because
        -- conjunct 9's `ammDisabled = true` leg cannot hold.
        let _proof :
            ∀ {verify : PublicKey → ByteArray → Signature → Bool}
              {P : AuthorityPolicy} {d : ByteArray}
              {es : ExtendedState} {st : SignedAction},
            es.bridge.ammDisabled = false →
            ∀ (r : ResourceId) (amount : Amount) (ra pa : ActorId),
            st.action = .reclaimAmmReserves r amount ra pa →
            ¬ BridgeAdmissibleWith verify P d es st :=
          fun h r amount ra pa heq =>
            reclaim_inadmissible_while_amm_enabled h r amount ra pa heq
        pure ()
    }
  , { name := "admission: conjunct 9 pins the canonical reserved actors"
    , body := do
        let _proof := @BridgeAdmissibleWith.reclaimGate
        assert true "reclaimGate projection exists"
    }
    -- ## Mirror step-invariance (the GP.11.10 transition semantics)
  , { name := "mirror invariance: no action moves any AMM mirror field"
    , body := do
        let _proof := @applyActionToBridgeState_preserves_amm_mirrors
        -- Value-level spot check on the sweep itself: the bridge
        -- LEDGER mirrors are untouched even by the reclaim action
        -- (the sweep moves KERNEL balances, not bridge-ledger fields).
        let bs : BridgeState := { BridgeState.empty with
          ammDisabled := true, ammReserveEth := 42 }
        let bs' := applyActionToBridgeState bs (.reclaimAmmReserves 0 5000 3 1) 0
        assertEq (expected := true) (actual := bs'.ammDisabled) "ammDisabled preserved"
        assertEq (expected := 42) (actual := bs'.ammReserveEth) "ammReserveEth preserved"
    }
  , { name := "amm_mirrors_constant_over_admitted_trace API stable"
    , body := do
        let _proof := @amm_mirrors_constant_over_admitted_trace
        let _proj  := @ammDisabled_constant_over_admitted_trace
        assert true "trace-level mirror constancy theorems exist"
    }
  , { name := "BridgeAdmittedTrace: refl trace preserves mirrors (value-level)"
    , body := do
        let es := ExtendedState.empty
        let h : BridgeAdmittedTrace (fun _ _ _ => true)
                  AuthorityPolicy.unrestricted ByteArray.empty es 0 es :=
          BridgeAdmittedTrace.refl
        let _heq : es.bridge.ammDisabled = es.bridge.ammDisabled :=
          ammDisabled_constant_over_admitted_trace
            (fun _ _ _ => true) AuthorityPolicy.unrestricted ByteArray.empty es 0 es h
        assertEq (expected := false) (actual := es.bridge.ammDisabled)
          "genesis mirror is false and the refl trace preserves it"
    }
    -- ## Lex re-expression
  , { name := "Lex re-expression is definitionally the kernel law"
    , body := do
        let _proof :
            reserved_gp_reclaimAmmReserves_transition 0 5000 3 1 =
            reclaimAmmReserves 0 5000 3 1 := rfl
        pure ()
    }
  ]

end LegalKernel.Test.Laws.ReclaimAmmReservesTests

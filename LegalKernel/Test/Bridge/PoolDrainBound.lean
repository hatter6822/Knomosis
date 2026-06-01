-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.PoolDrainBound — Workstream GP.7.3 (+ GP.7.5) test suite.

Exercises the per-resource inductive pool-drain bound
(`LegalKernel/Bridge/PoolDrainBound.lean`).  Coverage:

  * **Per-step drain (ETH + BOLD legs).**  An admitted `gasPoolActor`-signed
    capped transfer drains the chosen leg by exactly `amount` and leaves the
    other leg untouched (two-leg independence).
  * **Exhaustive external non-interference.**  `pool_nondecreasing_of_does_not_debit`
    on external credit / no-op / other-sender actions; the
    `doesNotDebitPoolAt` decidable predicate.
  * **Trace bound.**  1/2/3-step ETH traces, a BOLD trace, mixed
    pool/external traces — `pool_drain_bounded_by_action_count{,_per_resource,_bold}`,
    the surviving-balance floor, and the zero-cap boundary.
  * **Executable `applyTrace`.**  The `Option`-valued fold computes the
    post-state, `applyTrace_drain_bounded_per_resource` bounds it, and
    `applyTrace_yields_poolBoundedTrace` bridges it to the relation.
  * **The discipline that makes the bound hold.**  Over-cap, victim-sender,
    non-sequencer, off-leg, meta-action, zero-amount pool actions are NOT
    admitted under `intersect (gasPoolAuthorityPolicy …)`.
  * **Term-level API stability** for every headline theorem + constructors.
-/

import LegalKernel
import LegalKernel.Bridge.GasPoolPolicy
import LegalKernel.Bridge.PoolDrainBound
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Bridge
namespace PoolDrainBoundTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Fixtures -/

/-- The ETH-leg per-action cap. -/
def mEth : Amount := 1000

/-- The BOLD-leg per-action cap (distinct from `mEth`). -/
def mBold : Amount := 5000

/-- A regular (non-reserved) user actor. -/
def someUser : ActorId := 5

/-- The deployment id used by the admission fixtures. -/
def testDeploymentId : ByteArray := ByteArray.mk #[0x9A, 0x50]

/-- The genesis-wiring authority policy: the unrestricted base narrowed by
    `gasPoolAuthorityPolicy` (GP.7.2). -/
def pol : AuthorityPolicy :=
  AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy mEth mBold)

/-- A zero-ETH-cap variant of `pol` for the boundary fixtures. -/
def polZeroEth : AuthorityPolicy :=
  AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy 0 mBold)

/-- A policy authorising EXACTLY `gasPoolActor`'s capped sequencer
    transfers and nothing else.  Used for the `applyTrace` bound, where
    the external non-interference hypothesis `hext` is then vacuous (no
    non-pool action is admissible). -/
def polPoolOnly : AuthorityPolicy where
  authorized := fun signer action =>
    signer = gasPoolActor ∧ gasPoolActorAuthorized mEth mBold signer action
  decAuth := fun _ _ => inferInstance

/-- The starting kernel state: `gasPoolActor` holds 5000 ETH (resource 0)
    and 4000 BOLD (resource 1); `someUser` holds 3000 ETH. -/
def baseState : State :=
  setBalance
    (setBalance
      (setBalance genesisState 0 gasPoolActor 5000)
      1 gasPoolActor 4000)
    0 someUser 3000

/-- The starting `ExtendedState`: `baseState` balances, `gasPoolActor` and
    `someUser` registered, empty nonce ledger and local-policy table. -/
def es0 : ExtendedState :=
  { base     := baseState
  , nonces   := NonceState.empty
  , registry := KeyRegistry.empty.register gasPoolActor (mockPubKey gasPoolActor.toNat)
                  |>.register someUser (mockPubKey someUser.toNat) }

/-- A `pol`-admissible `SignedAction` for `action` signed by `signer`,
    at the nonce `es` expects, with a `mockSign` signature. -/
def mkSignedAction (action : Action) (signer : ActorId)
    (es : ExtendedState) : SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  { action := action
  , signer := signer
  , nonce  := nonce
  , sig    := mockSign (mockPubKey signer.toNat) msg }

/-- The pool-control hypothesis under `pol` (discharged by the connector). -/
def poolCtl : ∀ (es : ExtendedState) (st : SignedAction),
    AdmissibleWith mockVerify pol testDeploymentId es st → st.signer = gasPoolActor →
    gasPoolActorAuthorized mEth mBold gasPoolActor st.action :=
  fun es st h hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
    AuthorityPolicy.unrestricted testDeploymentId es st mEth mBold h hs

/-- The pool-control hypothesis under `polPoolOnly` (the `.2` of its
    authorisation conjunct). -/
def poolOnlyHpool : ∀ (es : ExtendedState) (st : SignedAction),
    AdmissibleWith mockVerify polPoolOnly testDeploymentId es st → st.signer = gasPoolActor →
    gasPoolActorAuthorized mEth mBold gasPoolActor st.action :=
  fun _ _ h hs => by obtain ⟨_, hg⟩ := h.1; rw [hs] at hg; exact hg

/-- The external-non-interference hypothesis under `polPoolOnly` is
    VACUOUS: every admitted action is `gasPoolActor`-signed (the `.1` of
    the authorisation conjunct), so the `signer ≠ gasPoolActor` premise is
    unsatisfiable. -/
def poolOnlyHext : ∀ (es : ExtendedState) (st : SignedAction)
    (h : AdmissibleWith mockVerify polPoolOnly testDeploymentId es st),
    st.signer ≠ gasPoolActor →
    getBalance es.base 0 gasPoolActor ≤
      getBalance (apply_admissible_with mockVerify polPoolOnly testDeploymentId es st h).base
        0 gasPoolActor :=
  fun _ _ h hne => by obtain ⟨h11, _⟩ := h.1; exact absurd h11 hne

/-! ## Test cases -/

/-- All GP.7.3 / GP.7.5 test cases. -/
def tests : List TestCase :=
  [ -- ## Per-step ETH-leg drain + single-step trace bound
    { name := "GP.7.3: ETH-leg pool transfer drains exactly `amount`; bound holds"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 800) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          assertEq (expected := (4200 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "post ETH balance"
          let _step : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor + mEth :=
            pool_signed_step_drain_le_eth mockVerify pol testDeploymentId es0 st mEth mBold h
              rfl (poolCtl es0 st h rfl)
          let ht : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 1 post :=
            PoolBoundedTrace.step st PoolBoundedTrace.refl h (poolCtl es0 st h)
              (fun hne => absurd rfl hne)
          let _bound : getBalance post.base 0 gasPoolActor + 1 * mEth ≥
              getBalance es0.base 0 gasPoolActor :=
            pool_drain_bounded_by_action_count mEth mBold mockVerify pol testDeploymentId
              es0 1 post ht
          assert (decide (getBalance post.base 0 gasPoolActor + 1 * mEth ≥
              getBalance es0.base 0 gasPoolActor)) "single-step bound numeric"
        else
          throw <| IO.userError "pol rejected a capped ETH-leg pool transfer"
    }
  , -- ## Per-step BOLD-leg drain (per-resource) + leg independence
    { name := "GP.7.5: BOLD-leg pool transfer drains BOLD, leaves ETH untouched"
    , body := do
        let st := mkSignedAction (.transfer 1 gasPoolActor sequencerActor 3000) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "ETH untouched by BOLD transfer"
          assertEq (expected := (1000 : Amount))
            (actual := getBalance post.base 1 gasPoolActor) "BOLD drained"
          -- BOLD-leg single-step trace + per-resource / BOLD bound.
          let ht : PoolBoundedTrace mEth mBold 1 mockVerify pol testDeploymentId es0 1 post :=
            PoolBoundedTrace.step st PoolBoundedTrace.refl h (poolCtl es0 st h)
              (fun hne => absurd rfl hne)
          let _bound : getBalance post.base 1 gasPoolActor + 1 * mBold ≥
              getBalance es0.base 1 gasPoolActor :=
            pool_drain_bounded_by_action_count_bold mEth mBold mockVerify pol testDeploymentId
              es0 1 post ht
          let _per : getBalance post.base 1 gasPoolActor + 1 * legCap mEth mBold 1 ≥
              getBalance es0.base 1 gasPoolActor :=
            pool_drain_bounded_by_action_count_per_resource mEth mBold 1 mockVerify pol
              testDeploymentId es0 1 post ht
          assert (decide (getBalance post.base 1 gasPoolActor + 1 * mBold ≥
              getBalance es0.base 1 gasPoolActor)) "BOLD bound numeric"
        else
          throw <| IO.userError "pol rejected a capped BOLD-leg pool transfer"
    }
  , -- ## Two-leg independence (raw law level)
    { name := "GP.7.5: per_resource_pool_independence — ETH transfer leaves BOLD"
    , body := do
        -- A pool transfer over resource 0 leaves the pool's resource-1 balance.
        assertEq
          (expected := getBalance baseState 1 gasPoolActor)
          (actual := getBalance ((Laws.transfer 0 gasPoolActor sequencerActor 700).apply_impl
            baseState) 1 gasPoolActor) "ETH transfer leaves BOLD"
        let _pf : getBalance ((Laws.transfer 0 gasPoolActor sequencerActor 700).apply_impl
            baseState) 1 gasPoolActor = getBalance baseState 1 gasPoolActor :=
          per_resource_pool_independence 0 1 baseState 700 (by decide)
        pure ()
    }
  , -- ## Exhaustive external discharge — credit-only action
    { name := "GP.7.3: external user mint does not drain the pool (exhaustive discharge)"
    , body := do
        let st := mkSignedAction (.mint 0 someUser 999) someUser es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "pool unchanged by external mint"
          let _nd : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor :=
            pool_nondecreasing_of_does_not_debit mockVerify pol testDeploymentId es0 st 0 h
              (by decide)
        else
          throw <| IO.userError "pol rejected an external mint"
    }
  , -- ## Exhaustive external discharge — other-sender transfer
    { name := "GP.7.3: external user transfer does not drain the pool"
    , body := do
        let st := mkSignedAction (.transfer 0 someUser sequencerActor 500) someUser es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "pool unchanged by external transfer"
          let _nd : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor :=
            transfer_other_sender_pool_nondecreasing mockVerify pol testDeploymentId es0 st h
              0 someUser sequencerActor 500 rfl (by decide)
        else
          throw <| IO.userError "pol rejected an external self-sender transfer"
    }
  , -- ## doesNotDebitPoolAt is decidable + classifies correctly
    { name := "GP.7.3: doesNotDebitPoolAt classifies credit/no-op/debit actions"
    , body := do
        -- credit-only: True
        assert (decide (Action.doesNotDebitPoolAt 0 someUser (.mint 0 someUser 5)))
          "mint qualifies"
        -- other-sender transfer at the bounded leg: sender ≠ pool ⇒ qualifies
        assert (decide (Action.doesNotDebitPoolAt 0 someUser (.transfer 0 someUser sequencerActor 5)))
          "other-sender transfer qualifies"
        -- pool-source transfer at the bounded leg: does NOT qualify
        assert (decide (¬ Action.doesNotDebitPoolAt 0 someUser (.transfer 0 gasPoolActor sequencerActor 5)))
          "pool-source transfer does not qualify"
        -- pool-source transfer on the OTHER leg: qualifies (off the bounded leg)
        assert (decide (Action.doesNotDebitPoolAt 0 someUser (.transfer 1 gasPoolActor sequencerActor 5)))
          "off-leg pool transfer qualifies"
    }
  , -- ## Two-step pool trace
    { name := "GP.7.3: 2-step pool trace satisfies the n·mEth drain bound + floor"
    , body := do
        let st1 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 800) gasPoolActor es0
        if hb1 : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st1 then
          let h1 := hb1.toAdmissibleWith
          let es1 := apply_admissible_with mockVerify pol testDeploymentId es0 st1 h1
          let st2 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 600) gasPoolActor es1
          if hb2 : BridgeAdmissibleWith mockVerify pol testDeploymentId es1 st2 then
            let h2 := hb2.toAdmissibleWith
            let es2 := apply_admissible_with mockVerify pol testDeploymentId es1 st2 h2
            assertEq (expected := (3600 : Amount))
              (actual := getBalance es2.base 0 gasPoolActor) "2-step final ETH balance"
            let t1 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 1 es1 :=
              PoolBoundedTrace.step st1 PoolBoundedTrace.refl h1 (poolCtl es0 st1 h1)
                (fun hne => absurd rfl hne)
            let t2 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 2 es2 :=
              PoolBoundedTrace.step st2 t1 h2 (poolCtl es1 st2 h2) (fun hne => absurd rfl hne)
            let _bound : getBalance es2.base 0 gasPoolActor + 2 * mEth ≥
                getBalance es0.base 0 gasPoolActor :=
              pool_drain_bounded_by_action_count mEth mBold mockVerify pol testDeploymentId
                es0 2 es2 t2
            let _floor : getBalance es2.base 0 gasPoolActor ≥
                getBalance es0.base 0 gasPoolActor - 2 * mEth :=
              pool_balance_lower_bound_via_trace mEth mBold mockVerify pol testDeploymentId
                es0 2 es2 t2
            assert (decide (getBalance es2.base 0 gasPoolActor ≥
                getBalance es0.base 0 gasPoolActor - 2 * mEth)) "2-step floor numeric"
          else
            throw <| IO.userError "pol rejected the second pool transfer"
        else
          throw <| IO.userError "pol rejected the first pool transfer"
    }
  , -- ## Three-step pool trace (induction depth)
    { name := "GP.7.3: 3-step pool trace satisfies the n·mEth drain bound"
    , body := do
        let st1 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 500) gasPoolActor es0
        if hb1 : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st1 then
          let h1 := hb1.toAdmissibleWith
          let es1 := apply_admissible_with mockVerify pol testDeploymentId es0 st1 h1
          let st2 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 900) gasPoolActor es1
          if hb2 : BridgeAdmissibleWith mockVerify pol testDeploymentId es1 st2 then
            let h2 := hb2.toAdmissibleWith
            let es2 := apply_admissible_with mockVerify pol testDeploymentId es1 st2 h2
            let st3 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 700) gasPoolActor es2
            if hb3 : BridgeAdmissibleWith mockVerify pol testDeploymentId es2 st3 then
              let h3 := hb3.toAdmissibleWith
              let es3 := apply_admissible_with mockVerify pol testDeploymentId es2 st3 h3
              assertEq (expected := (2900 : Amount))
                (actual := getBalance es3.base 0 gasPoolActor) "3-step final ETH balance"
              let t1 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 1 es1 :=
                PoolBoundedTrace.step st1 PoolBoundedTrace.refl h1 (poolCtl es0 st1 h1)
                  (fun hne => absurd rfl hne)
              let t2 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 2 es2 :=
                PoolBoundedTrace.step st2 t1 h2 (poolCtl es1 st2 h2) (fun hne => absurd rfl hne)
              let t3 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 3 es3 :=
                PoolBoundedTrace.step st3 t2 h3 (poolCtl es2 st3 h3) (fun hne => absurd rfl hne)
              let _bound : getBalance es3.base 0 gasPoolActor + 3 * mEth ≥
                  getBalance es0.base 0 gasPoolActor :=
                pool_drain_bounded_by_action_count mEth mBold mockVerify pol testDeploymentId
                  es0 3 es3 t3
              assert (decide (getBalance es3.base 0 gasPoolActor + 3 * mEth ≥
                  getBalance es0.base 0 gasPoolActor)) "3-step bound numeric"
            else
              throw <| IO.userError "pol rejected the third pool transfer"
          else
            throw <| IO.userError "pol rejected the second pool transfer (3-step)"
        else
          throw <| IO.userError "pol rejected the first pool transfer (3-step)"
    }
  , -- ## Mixed external+pool trace
    { name := "GP.7.3: mixed external+pool 2-step trace satisfies the bound"
    , body := do
        let st1 := mkSignedAction (.transfer 0 someUser sequencerActor 500) someUser es0
        if hb1 : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st1 then
          let h1 := hb1.toAdmissibleWith
          let es1 := apply_admissible_with mockVerify pol testDeploymentId es0 st1 h1
          let st2 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 700) gasPoolActor es1
          if hb2 : BridgeAdmissibleWith mockVerify pol testDeploymentId es1 st2 then
            let h2 := hb2.toAdmissibleWith
            let es2 := apply_admissible_with mockVerify pol testDeploymentId es1 st2 h2
            assertEq (expected := (4300 : Amount))
              (actual := getBalance es2.base 0 gasPoolActor) "mixed-trace final pool balance"
            let t1 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 1 es1 :=
              PoolBoundedTrace.step st1 PoolBoundedTrace.refl h1
                (fun hs => absurd hs (by decide))
                (fun _ => transfer_other_sender_pool_nondecreasing mockVerify pol
                  testDeploymentId es0 st1 h1 0 someUser sequencerActor 500 rfl (by decide))
            let t2 : PoolBoundedTrace mEth mBold 0 mockVerify pol testDeploymentId es0 2 es2 :=
              PoolBoundedTrace.step st2 t1 h2 (poolCtl es1 st2 h2) (fun hne => absurd rfl hne)
            let _bound : getBalance es2.base 0 gasPoolActor + 2 * mEth ≥
                getBalance es0.base 0 gasPoolActor :=
              pool_drain_bounded_by_action_count mEth mBold mockVerify pol testDeploymentId
                es0 2 es2 t2
            assert (decide (getBalance es2.base 0 gasPoolActor + 2 * mEth ≥
                getBalance es0.base 0 gasPoolActor)) "mixed-trace bound numeric"
          else
            throw <| IO.userError "pol rejected the pool step of the mixed trace"
        else
          throw <| IO.userError "pol rejected the external step of the mixed trace"
    }
  , -- ## Executable applyTrace fold + its bound (under the pool-only policy)
    { name := "GP.7.3: executable applyTrace computes the fold and satisfies the bound"
    , body := do
        -- Build the trace with correctly-chained nonces, then drive the
        -- executable fold over the SAME actions.  `polPoolOnly` admits only
        -- `gasPoolActor`-signed capped transfers, so `poolOnlyHext` is vacuous.
        let st1 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 800) gasPoolActor es0
        if h1 : AdmissibleWith mockVerify polPoolOnly testDeploymentId es0 st1 then
          let es1 := apply_admissible_with mockVerify polPoolOnly testDeploymentId es0 st1 h1
          let st2 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 600) gasPoolActor es1
          match h_at : applyTrace mockVerify polPoolOnly testDeploymentId es0 [st1, st2] with
          | some es2 =>
              -- The executable fold reproduces the post-state: 5000 − 800 − 600.
              assertEq (expected := (3600 : Amount))
                (actual := getBalance es2.base 0 gasPoolActor) "applyTrace final ETH balance"
              let _bound : getBalance es2.base 0 gasPoolActor +
                  [st1, st2].length * legCap mEth mBold 0 ≥ getBalance es0.base 0 gasPoolActor :=
                applyTrace_drain_bounded_per_resource mockVerify polPoolOnly testDeploymentId
                  mEth mBold 0 poolOnlyHpool poolOnlyHext es0 es2 [st1, st2] h_at
              assert (decide (getBalance es2.base 0 gasPoolActor +
                  [st1, st2].length * legCap mEth mBold 0 ≥ getBalance es0.base 0 gasPoolActor))
                "applyTrace bound numeric"
          | none => throw <| IO.userError "applyTrace unexpectedly returned none"
        else
          throw <| IO.userError "polPoolOnly rejected the first pool transfer"
    }
  , -- ## applyTrace ⇒ PoolBoundedTrace bridge, fed through the headline bound
    { name := "GP.7.3: applyTrace_yields_poolBoundedTrace feeds the headline bound"
    , body := do
        let st1 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 800) gasPoolActor es0
        if h1 : AdmissibleWith mockVerify polPoolOnly testDeploymentId es0 st1 then
          let es1 := apply_admissible_with mockVerify polPoolOnly testDeploymentId es0 st1 h1
          let st2 := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 600) gasPoolActor es1
          match h_at : applyTrace mockVerify polPoolOnly testDeploymentId es0 [st1, st2] with
          | some es2 =>
              -- Recover the inductive trace from the executable fold …
              let ht : PoolBoundedTrace mEth mBold 0 mockVerify polPoolOnly testDeploymentId
                  es0 [st1, st2].length es2 :=
                applyTrace_yields_poolBoundedTrace mockVerify polPoolOnly testDeploymentId
                  mEth mBold 0 poolOnlyHpool poolOnlyHext es0 es2 [st1, st2] h_at
              -- … and feed it through the relation-form headline bound.
              let _bound : getBalance es2.base 0 gasPoolActor +
                  [st1, st2].length * legCap mEth mBold 0 ≥ getBalance es0.base 0 gasPoolActor :=
                pool_drain_bounded_by_action_count_per_resource mEth mBold 0 mockVerify
                  polPoolOnly testDeploymentId es0 [st1, st2].length es2 ht
              assert (decide (getBalance es2.base 0 gasPoolActor +
                  [st1, st2].length * legCap mEth mBold 0 ≥ getBalance es0.base 0 gasPoolActor))
                "bridged bound numeric"
          | none => throw <| IO.userError "applyTrace unexpectedly returned none"
        else
          throw <| IO.userError "polPoolOnly rejected the first pool transfer"
    }
  , -- ## Runtime-entry lift: the bound over the LITERAL budget-gated bridge entry
    { name := "GP.7.3: pool_signed_step_drain_le_budget bounds the production runtime entry"
    , body := do
        -- A permissive budget policy so `gasPoolActor` (not budget-exempt)
        -- clears the gate.  The free tier is granted on epoch advance, so
        -- `currentEpoch = 1 > 0` (a fresh actor's `lastEpoch`) gives it the
        -- `freeTier` balance; the kernel drain is unaffected by the budget gate.
        let esB : ExtendedState := { es0 with budgetPolicy := .bounded 10 1 1 }
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 800) gasPoolActor esB
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId esB st then
          match hsuc : apply_bridge_admissible_with_budget mockVerify pol testDeploymentId esB st 0 hb with
          | some es' =>
              -- The runtime entry produces the SAME kernel drain: 5000 − 800.
              assertEq (expected := (4200 : Amount))
                (actual := getBalance es'.base 0 gasPoolActor) "runtime-entry post ETH balance"
              let hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action :=
                gasPoolActorAuthorized_of_admissible_intersect mockVerify
                  AuthorityPolicy.unrestricted testDeploymentId esB st mEth mBold
                  hb.toAdmissibleWith rfl
              let _bound : getBalance esB.base 0 gasPoolActor ≤
                  getBalance es'.base 0 gasPoolActor + legCap mEth mBold 0 :=
                pool_signed_step_drain_le_budget mockVerify pol testDeploymentId esB st
                  mEth mBold 0 0 hb hsuc rfl hauth
              assert (decide (getBalance esB.base 0 gasPoolActor ≤
                  getBalance es'.base 0 gasPoolActor + legCap mEth mBold 0))
                "runtime-entry drain bound numeric"
          | none => throw <| IO.userError "budget gate rejected a budgeted pool transfer"
        else
          throw <| IO.userError "pol rejected the pool transfer (runtime lift)"
    }
  , -- ## The discipline that makes the bound hold
    { name := "GP.7.3 discipline: over-cap pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 1001) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted an over-cap pool transfer"
        else pure ()
    }
  , { name := "GP.7.3 discipline: victim-sender pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 0 someUser sequencerActor 100) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a victim-sender pool transfer"
        else pure ()
    }
  , { name := "GP.7.3 discipline: off-leg pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 5 gasPoolActor sequencerActor 100) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted an off-leg pool transfer"
        else pure ()
    }
  , { name := "GP.7.3 discipline: pool meta-action (revoke) is NOT admitted"
    , body := do
        let st := mkSignedAction .revokeLocalPolicy gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a pool meta-action"
        else pure ()
    }
  , -- ## Zero-cap boundary
    { name := "GP.7.3 boundary: positive ETH drain is inadmissible at mEth = 0"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 1) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify polZeroEth testDeploymentId es0 st) then
          throw <| IO.userError "zero-cap policy admitted a positive ETH drain"
        else pure ()
    }
  , { name := "GP.7.3 boundary: BOLD claim still works at mEth = 0; ETH non-decreasing"
    , body := do
        let st := mkSignedAction (.transfer 1 gasPoolActor sequencerActor 2000) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify polZeroEth testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify polZeroEth testDeploymentId es0 st h
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "ETH untouched under zero cap"
          let ht : PoolBoundedTrace 0 mBold 0 mockVerify polZeroEth testDeploymentId es0 1 post :=
            PoolBoundedTrace.step st PoolBoundedTrace.refl h
              (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                AuthorityPolicy.unrestricted testDeploymentId es0 st 0 mBold h hs)
              (fun hne => absurd rfl hne)
          let _zero : getBalance post.base 0 gasPoolActor ≥ getBalance es0.base 0 gasPoolActor :=
            pool_cannot_drain_when_cap_zero mBold mockVerify polZeroEth testDeploymentId
              es0 1 post ht
        else
          throw <| IO.userError "zero-cap policy rejected a BOLD claim"
    }
  , { name := "GP.7.3 discipline: non-sequencer pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor someUser 100) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a non-sequencer pool transfer"
        else pure ()
    }
  , { name := "GP.7.3 edge: zero-amount pool transfer is NOT admitted (fails pre)"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 0) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a zero-amount pool transfer"
        else pure ()
    }
  , { name := "GP.7.3: at-cap (amount = mEth) ETH transfer admitted; drains mEth"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 1000) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          assertEq (expected := (4000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "post ETH balance at cap"
        else
          throw <| IO.userError "pol rejected an at-cap pool transfer"
    }
  , { name := "GP.7.3: pool transfer admitted under declared gasPoolPolicy + intersect"
    , body := do
        -- Genesis-wiring fidelity: BOTH the `gasPoolPolicy` LocalPolicy AND
        -- the intersected `gasPoolAuthorityPolicy` are in force.
        let esD : ExtendedState :=
          { es0 with localPolicies :=
              LocalPolicies.empty.declare gasPoolActor (gasPoolPolicy mEth mBold) }
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 900) gasPoolActor esD
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId esD st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId esD st h
          assertEq (expected := (4100 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "post balance (genesis-wiring shape)"
        else
          throw <| IO.userError "genesis-wiring policy rejected a capped pool transfer"
    }
  , -- ## Term-level API stability
    { name := "GP.7.3: term-level API stability (per-resource + applyTrace + corollaries)"
    , body := do
        let _t1 := @pool_signed_step_drain_le
        let _t2 := @pool_signed_step_drain_le_eth
        let _t3 := @pool_signed_step_drain_le_bold
        let _t4 := @transfer_other_sender_pool_nondecreasing
        let _t5 := @pool_nondecreasing_of_does_not_debit
        let _t6 := @pool_step_drain_le
        let _t7 := @pool_drain_bounded_by_action_count_per_resource
        let _t8 := @pool_drain_bounded_by_action_count
        let _t9 := @pool_drain_bounded_by_action_count_bold
        let _t10 := @pool_balance_lower_bound_via_trace_per_resource
        let _t11 := @pool_balance_lower_bound_via_trace
        let _t12 := @pool_cannot_drain_when_cap_zero
        let _t13 := @gasPoolActorAuthorized_of_admissible_intersect
        let _t14 := @per_resource_pool_independence
        let _t15 := @pool_balance_eth_leg_independent_of_bold_actions
        let _t16 := @pool_balance_bold_leg_independent_of_eth_actions
        let _t17 := @applyTrace
        let _t18 := @applyTrace_drain_bounded_per_resource
        let _t19 := @applyTrace_yields_poolBoundedTrace
        let _t20 := @apply_admissible_with_base
        let _t21 := @pool_signed_step_drain_le_budget
        let _t22 := @pool_nondecreasing_of_does_not_debit_budget
        let _t23 := @apply_bridge_admissible_with_budget_base_eq_apply
        let _c1 := @PoolBoundedTrace.refl
        let _c2 := @PoolBoundedTrace.step
        let _c3 := @PoolBoundedTrace.headStep
        pure ()
    }
  ]

end PoolDrainBoundTests
end LegalKernel.Test.Bridge

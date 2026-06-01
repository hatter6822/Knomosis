-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.PoolDrainBound — Workstream GP.7.3 test suite.

Exercises the inductive pool-drain bound
(`LegalKernel/Bridge/PoolDrainBound.lean`).  Coverage:

  * **Per-step drain (ETH leg).**  An admitted `gasPoolActor`-signed
    `transfer` over resource 0 debits exactly `amount`; the post-state
    balance is `pre − amount` and the per-step bound `pre ≤ post + mEth`
    holds at the value level.
  * **Per-leg locality (BOLD leg).**  A `gasPoolActor`-signed transfer
    over resource 1 leaves the resource-0 balance untouched.
  * **External non-interference.**  A transfer signed by another actor
    on its OWN balance does not decrease the pool's balance
    (`transfer_other_sender_pool_nondecreasing`).
  * **Trace bound.**  1-, 2-, and 3-step traces (pure pool + mixed
    pool/external) satisfy `pool_drain_bounded_by_action_count` and the
    `pool_balance_lower_bound_via_trace` floor.
  * **The discipline that makes the bound hold.**  Over-cap,
    non-sequencer, off-leg, victim-sender, and meta-action pool actions
    are NOT admitted under `intersect (gasPoolAuthorityPolicy …)`.
  * **Zero-cap boundary.**  With `mEth = 0` the ETH leg cannot drain
    (`pool_cannot_drain_when_cap_zero`); a positive ETH drain is
    inadmissible while a BOLD-leg claim still works.
  * **Connectors + decomposition + term-level API stability** for every
    headline theorem and the `PoolBoundedTrace` constructors.
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

/-- The ETH-leg per-action cap used by the value-level fixtures. -/
def mEth : Amount := 1000

/-- The BOLD-leg per-action cap (distinct from `mEth`). -/
def mBold : Amount := 5000

/-- A regular (non-reserved) user actor for the external-transfer and
    victim-drain fixtures. -/
def someUser : ActorId := 5

/-- The deployment id used by the admission fixtures. -/
def testDeploymentId : ByteArray := ByteArray.mk #[0x9A, 0x50]

/-- The genesis-wiring authority policy: the unrestricted base policy
    narrowed by `gasPoolAuthorityPolicy` (GP.7.2).  This is the policy
    shape GP.7.4 ratifies at genesis, and the one under which the drain
    bound's `hpool` hypothesis is discharged. -/
def pol : AuthorityPolicy :=
  AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy mEth mBold)

/-- A zero-ETH-cap variant of `pol` for the boundary fixtures. -/
def polZeroEth : AuthorityPolicy :=
  AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy 0 mBold)

/-- The starting kernel state: `gasPoolActor` holds 5000 ETH (resource
    0) and 4000 BOLD (resource 1); `someUser` holds 3000 ETH. -/
def baseState : State :=
  setBalance
    (setBalance
      (setBalance genesisState 0 gasPoolActor 5000)
      1 gasPoolActor 4000)
    0 someUser 3000

/-- The starting `ExtendedState`: `baseState` balances, `gasPoolActor`
    and `someUser` registered with mock keys, empty nonce ledger and
    empty local-policy table. -/
def es0 : ExtendedState :=
  { base     := baseState
  , nonces   := NonceState.empty
  , registry := KeyRegistry.empty.register gasPoolActor (mockPubKey gasPoolActor.toNat)
                  |>.register someUser (mockPubKey someUser.toNat) }

/-- A `pol`-admissible `SignedAction` for `action` signed by `signer`,
    at the nonce `es` expects, with a `mockSign` signature.  Mirrors the
    established fixture builder in the budget / bridge-actor suites. -/
def mkSignedAction (action : Action) (signer : ActorId)
    (es : ExtendedState) : SignedAction :=
  let nonce := expectsNonce es signer
  let msg := signingInput action signer nonce testDeploymentId
  { action := action
  , signer := signer
  , nonce  := nonce
  , sig    := mockSign (mockPubKey signer.toNat) msg }

/-! ## Test cases -/

/-- All GP.7.3 test cases. -/
def tests : List TestCase :=
  [ -- ## Per-step ETH-leg drain + single-step trace bound
    { name := "GP.7.3: ETH-leg pool transfer drains exactly `amount`; bound holds"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 800) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          -- Value-level: 5000 − 800 = 4200.
          assertEq (expected := (4200 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "post ETH balance"
          -- Per-step bound (term-level, exercises the proof on real data).
          let _step : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor + mEth :=
            pool_signed_step_drain_le_eth mockVerify pol testDeploymentId es0 st mEth mBold h
              rfl (gasPoolActorAuthorized_of_admissible_intersect mockVerify
                    AuthorityPolicy.unrestricted testDeploymentId es0 st mEth mBold h rfl)
          -- Single-step trace bound: 4200 + 1·1000 ≥ 5000.
          let ht : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 1 post :=
            PoolBoundedTrace.step st PoolBoundedTrace.refl h
              (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                AuthorityPolicy.unrestricted testDeploymentId es0 st mEth mBold h hs)
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
  , -- At-cap transfer is admitted; over-cap is not.
    { name := "GP.7.3: at-cap (amount = mEth) ETH transfer admitted; drains mEth"
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
  , -- ## Per-leg locality (BOLD leg)
    { name := "GP.7.3: BOLD-leg pool transfer leaves the ETH balance untouched"
    , body := do
        let st := mkSignedAction (.transfer 1 gasPoolActor sequencerActor 3000) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          -- ETH (resource 0) balance unchanged; BOLD (resource 1) drained.
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "ETH untouched by BOLD transfer"
          assertEq (expected := (1000 : Amount))
            (actual := getBalance post.base 1 gasPoolActor) "BOLD drained"
        else
          throw <| IO.userError "pol rejected a capped BOLD-leg pool transfer"
    }
  , -- ## External non-interference
    { name := "GP.7.3: external user transfer does not decrease the pool balance"
    , body := do
        let st := mkSignedAction (.transfer 0 someUser sequencerActor 500) someUser es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          -- Pool's ETH balance unchanged (the debit lands on `someUser`).
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "pool unchanged by external transfer"
          let _nd : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor :=
            transfer_other_sender_pool_nondecreasing mockVerify pol testDeploymentId es0 st h
              0 someUser sequencerActor 500 rfl (by decide)
        else
          throw <| IO.userError "pol rejected an external self-sender transfer"
    }
  , -- ## Two-step pool trace
    { name := "GP.7.3: 2-step pool trace satisfies the n·mEth drain bound"
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
            let t1 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 1 es1 :=
              PoolBoundedTrace.step st1 PoolBoundedTrace.refl h1
                (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                  AuthorityPolicy.unrestricted testDeploymentId es0 st1 mEth mBold h1 hs)
                (fun hne => absurd rfl hne)
            let t2 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 2 es2 :=
              PoolBoundedTrace.step st2 t1 h2
                (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                  AuthorityPolicy.unrestricted testDeploymentId es1 st2 mEth mBold h2 hs)
                (fun hne => absurd rfl hne)
            let _bound : getBalance es2.base 0 gasPoolActor + 2 * mEth ≥
                getBalance es0.base 0 gasPoolActor :=
              pool_drain_bounded_by_action_count mEth mBold mockVerify pol testDeploymentId
                es0 2 es2 t2
            -- 3600 + 2·1000 = 5600 ≥ 5000.
            assert (decide (getBalance es2.base 0 gasPoolActor + 2 * mEth ≥
                getBalance es0.base 0 gasPoolActor)) "2-step bound numeric"
            -- Lower-bound floor: 3600 ≥ 5000 − 2·1000 = 3000.
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
  , -- ## Mixed trace: an external step then a pool step
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
            -- Pool drained only by the pool step: 5000 − 700 = 4300.
            assertEq (expected := (4300 : Amount))
              (actual := getBalance es2.base 0 gasPoolActor) "mixed-trace final pool balance"
            let t1 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 1 es1 :=
              PoolBoundedTrace.step st1 PoolBoundedTrace.refl h1
                (fun hs => absurd hs (by decide))
                (fun _ => transfer_other_sender_pool_nondecreasing mockVerify pol
                  testDeploymentId es0 st1 h1 0 someUser sequencerActor 500 rfl (by decide))
            let t2 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 2 es2 :=
              PoolBoundedTrace.step st2 t1 h2
                (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                  AuthorityPolicy.unrestricted testDeploymentId es1 st2 mEth mBold h2 hs)
                (fun hne => absurd rfl hne)
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
  , -- ## The discipline that makes the bound hold
    { name := "GP.7.3 discipline: over-cap pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 1001) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted an over-cap pool transfer"
        else
          pure ()
    }
  , { name := "GP.7.3 discipline: victim-sender pool transfer is NOT admitted"
    , body := do
        -- `gasPoolActor` signs a transfer whose `sender` is `someUser`
        -- (a victim).  `gasPoolAuthorityPolicy` binds `sender = gasPoolActor`,
        -- so this is rejected — the load-bearing fund-safety guarantee the
        -- drain bound's "external steps don't drain" case relies on.
        let st := mkSignedAction (.transfer 0 someUser sequencerActor 100) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a victim-sender pool transfer"
        else
          pure ()
    }
  , { name := "GP.7.3 discipline: non-sequencer pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor someUser 100) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a non-sequencer pool transfer"
        else
          pure ()
    }
  , { name := "GP.7.3 discipline: off-leg (resource 5) pool transfer is NOT admitted"
    , body := do
        let st := mkSignedAction (.transfer 5 gasPoolActor sequencerActor 100) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted an off-leg pool transfer"
        else
          pure ()
    }
  , { name := "GP.7.3 discipline: pool meta-action (revoke) is NOT admitted"
    , body := do
        let st := mkSignedAction .revokeLocalPolicy gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a pool meta-action"
        else
          pure ()
    }
  , -- ## Zero-cap boundary
    { name := "GP.7.3 boundary: positive ETH drain is inadmissible at mEth = 0"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 1) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify polZeroEth testDeploymentId es0 st) then
          throw <| IO.userError "zero-cap policy admitted a positive ETH drain"
        else
          pure ()
    }
  , { name := "GP.7.3 boundary: BOLD claim still works at mEth = 0; ETH non-decreasing"
    , body := do
        -- A BOLD-leg claim is unaffected by the zero ETH cap; the ETH leg
        -- stays put, witnessed by `pool_cannot_drain_when_cap_zero`.
        let st := mkSignedAction (.transfer 1 gasPoolActor sequencerActor 2000) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify polZeroEth testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify polZeroEth testDeploymentId es0 st h
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "ETH untouched under zero cap"
          let ht : PoolBoundedTrace 0 mBold mockVerify polZeroEth testDeploymentId es0 1 post :=
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
  , -- ## Connector + decomposition
    { name := "GP.7.3: gasPoolActorAuthorized_of_admissible_intersect extracts authority"
    , body := do
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 750) gasPoolActor es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          -- Connector: extract the authority fact from the admission witness.
          let hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action :=
            gasPoolActorAuthorized_of_admissible_intersect mockVerify
              AuthorityPolicy.unrestricted testDeploymentId es0 st mEth mBold h rfl
          -- Decomposition applies: the authority is a capped pool transfer
          -- (term-level — `Exists` cannot be eliminated into `IO`).
          let _dec : ∃ r sender receiver amount,
              st.action = .transfer r sender receiver amount ∧
              ((r = 0 ∧ sender = gasPoolActor ∧ receiver = sequencerActor ∧ amount ≤ mEth) ∨
               (r = 1 ∧ sender = gasPoolActor ∧ receiver = sequencerActor ∧ amount ≤ mBold)) :=
            gasPoolActorAuthorized_gasPool_imp_transfer mEth mBold st.action hauth
          -- Value-level: the pool is authorised for exactly this capped transfer.
          assert (decide (gasPoolActorAuthorized mEth mBold gasPoolActor st.action))
            "gasPoolActor authorised for the capped sequencer transfer"
        else
          throw <| IO.userError "pol rejected the connector fixture"
    }
  , -- ## Genesis-wiring fidelity: BOTH the LocalPolicy and the AuthorityPolicy
    { name := "GP.7.3: pool transfer admitted under declared gasPoolPolicy + intersect"
    , body := do
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
  , -- ## Three-step pool trace (exercises the induction depth)
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
              -- 5000 − 500 − 900 − 700 = 2900.
              assertEq (expected := (2900 : Amount))
                (actual := getBalance es3.base 0 gasPoolActor) "3-step final ETH balance"
              let t1 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 1 es1 :=
                PoolBoundedTrace.step st1 PoolBoundedTrace.refl h1
                  (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                    AuthorityPolicy.unrestricted testDeploymentId es0 st1 mEth mBold h1 hs)
                  (fun hne => absurd rfl hne)
              let t2 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 2 es2 :=
                PoolBoundedTrace.step st2 t1 h2
                  (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                    AuthorityPolicy.unrestricted testDeploymentId es1 st2 mEth mBold h2 hs)
                  (fun hne => absurd rfl hne)
              let t3 : PoolBoundedTrace mEth mBold mockVerify pol testDeploymentId es0 3 es3 :=
                PoolBoundedTrace.step st3 t2 h3
                  (fun hs => gasPoolActorAuthorized_of_admissible_intersect mockVerify
                    AuthorityPolicy.unrestricted testDeploymentId es2 st3 mEth mBold h3 hs)
                  (fun hne => absurd rfl hne)
              let _bound : getBalance es3.base 0 gasPoolActor + 3 * mEth ≥
                  getBalance es0.base 0 gasPoolActor :=
                pool_drain_bounded_by_action_count mEth mBold mockVerify pol testDeploymentId
                  es0 3 es3 t3
              -- 2900 + 3·1000 = 5900 ≥ 5000.
              assert (decide (getBalance es3.base 0 gasPoolActor + 3 * mEth ≥
                  getBalance es0.base 0 gasPoolActor)) "3-step bound numeric"
            else
              throw <| IO.userError "pol rejected the third pool transfer"
          else
            throw <| IO.userError "pol rejected the second pool transfer (3-step)"
        else
          throw <| IO.userError "pol rejected the first pool transfer (3-step)"
    }
  , -- ## External transfer crediting the pool (the `receiver = pool` branch)
    { name := "GP.7.3: external transfer TO the pool increases its balance (non-decreasing)"
    , body := do
        -- `someUser` sends to `gasPoolActor` on the ETH leg: the pool's
        -- balance rises, exercising the credit branch of
        -- `transfer_other_sender_pool_nondecreasing`.
        let st := mkSignedAction (.transfer 0 someUser gasPoolActor 400) someUser es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          -- 5000 + 400 = 5400.
          assertEq (expected := (5400 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "pool credited by external transfer"
          let _nd : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor :=
            transfer_other_sender_pool_nondecreasing mockVerify pol testDeploymentId es0 st h
              0 someUser gasPoolActor 400 rfl (by decide)
        else
          throw <| IO.userError "pol rejected an external transfer to the pool"
    }
  , -- ## Combined per-step lemma on an external step
    { name := "GP.7.3: pool_step_drain_le_eth holds on a non-pool-signed step"
    , body := do
        let st := mkSignedAction (.transfer 0 someUser sequencerActor 200) someUser es0
        if hb : BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st then
          let h := hb.toAdmissibleWith
          let post := apply_admissible_with mockVerify pol testDeploymentId es0 st h
          let _step : getBalance es0.base 0 gasPoolActor ≤
              getBalance post.base 0 gasPoolActor + mEth :=
            pool_step_drain_le_eth mockVerify pol testDeploymentId es0 st mEth mBold h
              (fun hs => absurd hs (by decide))
              (fun _ => transfer_other_sender_pool_nondecreasing mockVerify pol
                testDeploymentId es0 st h 0 someUser sequencerActor 200 rfl (by decide))
          assertEq (expected := (5000 : Amount))
            (actual := getBalance post.base 0 gasPoolActor) "pool unchanged by external step"
        else
          throw <| IO.userError "pol rejected the external step fixture"
    }
  , -- ## Zero-amount edge: authorised but rejected by the transfer precondition
    { name := "GP.7.3 edge: zero-amount pool transfer is NOT admitted (fails pre)"
    , body := do
        -- `transfer 0 gasPoolActor sequencerActor 0` is AUTHORISED (0 ≤ mEth)
        -- but fails the kernel `transfer` precondition (`amount > 0`), so it
        -- is inadmissible — a vacuous drain cannot even be applied.
        let st := mkSignedAction (.transfer 0 gasPoolActor sequencerActor 0) gasPoolActor es0
        if (BridgeAdmissibleWith mockVerify pol testDeploymentId es0 st) then
          throw <| IO.userError "pol admitted a zero-amount pool transfer"
        else
          pure ()
    }
  , -- ## Term-level API stability for every headline theorem + constructors
    { name := "GP.7.3: term-level API stability (per-step + trace + corollaries)"
    , body := do
        let _t1 := @pool_signed_step_drain_le_eth
        let _t2 := @transfer_other_sender_pool_nondecreasing
        let _t3 := @pool_step_drain_le_eth
        let _t4 := @pool_drain_bounded_by_action_count
        let _t5 := @pool_balance_lower_bound_via_trace
        let _t6 := @pool_cannot_drain_when_cap_zero
        let _t7 := @gasPoolActorAuthorized_of_admissible_intersect
        let _t8 := @apply_admissible_with_base
        let _t9 := @gasPoolActorAuthorized_gasPool_imp_transfer
        let _c1 := @PoolBoundedTrace.refl
        let _c2 := @PoolBoundedTrace.step
        pure ()
    }
  ]

end PoolDrainBoundTests
end LegalKernel.Test.Bridge

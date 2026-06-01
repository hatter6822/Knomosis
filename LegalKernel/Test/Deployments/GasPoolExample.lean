-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Deployments.GasPoolExample — Workstream GP.7.4
integration tests for the worked unified-gas-pool deployment.

`docs/planning/unified_gas_pool_plan.md` WU GP.7.4.

End-to-end coverage of `Deployments.Examples.GasPoolExample`:

  * **The worked sequence runs** through the bridge-aware admission
    gate (`runGasPoolExamplePure` returns `.ok`): a bridge ETH
    `depositWithFee`, a bridge BOLD `depositWithFee`, and the two
    capped sequencer claims (ETH + BOLD legs) are all admitted.
  * **Post-state balances** are exactly the expected user / pool /
    sequencer figures on both legs.
  * **The L2 budget grants landed**: the user's `currentBudget` is the
    free tier plus both deposit grants.
  * **Genesis fidelity**: the genesis state declares `gasPoolPolicy`
    for `gasPoolActor` (the state half of the GP.7.4 wiring).
  * **The discipline that makes the bound hold** (negative cases,
    against a well-funded pool so the cap — not the balance — is the
    limiter): over-cap ETH / BOLD claims, a pool meta-action
    (`revokeLocalPolicy`), a victim-sender claim, and a non-sequencer
    recipient are all REJECTED under the genesis policy.
  * **The intersection narrows ONLY the pool**: a regular user's
    transfer is still admitted.
  * **The IO entry runs end-to-end via the `knomosis` binary's path**:
    `runGasPoolExample` (the `gas-pool-demo` subcommand) processes the
    four steps to a persisted log and replays it, returning exit 0.
  * **Term-level API stability** for the GP.7.4 genesis-hook theorems
    and the example's proof-carrying demonstrations.
-/

import LegalKernel.Test.Framework
import LegalKernel.Bridge.GasPoolPolicy
import Deployments.Examples.GasPoolExample

namespace LegalKernel.Test.Deployments
namespace GasPoolExampleTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test
open Deployments.Examples.GasPoolExample

/-! ## Fixtures for the negative (discipline) cases

A genesis state whose pool is funded WELL ABOVE the per-action caps,
so a cap-violating claim is rejected by the cap clause — not merely by
the transfer precondition's balance check.  This isolates the policy's
cap discipline. -/

/-- The genesis state with `gasPoolActor` over-funded (5000 on each of
    the two gas legs, far above `maxDrainPerActionEth = 1000` /
    `maxDrainPerActionBold = 3000`). -/
def fundedState : ExtendedState :=
  { exampleState with
    base := setBalance (setBalance genesisState 0 gasPoolActor 5000) 1 gasPoolActor 5000 }

/-- A genesis state with `userActor` funded, for the "other actor is
    unrestricted" positive case. -/
def userFundedState : ExtendedState :=
  { exampleState with base := setBalance genesisState 0 userActor 1000 }

/-- `true` iff the demo-signed `action` by `signer` is bridge-admissible
    at `es` under the deployment's genesis policy. -/
def admissibleAt (es : ExtendedState) (signer : ActorId) (action : Action) : Bool :=
  let st := mkExampleSignedAction action signer es
  decide (BridgeAdmissibleWith exampleVerify examplePolicy exampleDeploymentId es st)

/-! ## Tests -/

/-- All GP.7.4 integration test cases. -/
def tests : List TestCase :=
  [ -- ## The worked sequence runs end-to-end through the admission gate.
    { name := "GP.7.4: worked ETH+BOLD deposit + dual sequencer claim sequence is admitted"
    , body := do
        match runGasPoolExamplePure with
        | .error e => throw <| IO.userError s!"worked sequence rejected: {e}"
        | .ok _ => pure ()
    }
  , -- ## Post-state balances on both legs.
    { name := "GP.7.4: final balances (user / pool / sequencer, ETH + BOLD legs)"
    , body := do
        match runGasPoolExamplePure with
        | .error e => throw <| IO.userError s!"worked sequence rejected: {e}"
        | .ok fs =>
          assertEq (expected := (9000 : Amount)) (actual := getBalance fs.base 0 userActor)
            "user ETH = userAmount of the ETH deposit"
          assertEq (expected := (27000 : Amount)) (actual := getBalance fs.base 1 userActor)
            "user BOLD = userAmount of the BOLD deposit"
          assertEq (expected := (200 : Amount)) (actual := getBalance fs.base 0 gasPoolActor)
            "pool ETH = fee skim (1000) − ETH claim (800)"
          assertEq (expected := (500 : Amount)) (actual := getBalance fs.base 1 gasPoolActor)
            "pool BOLD = fee skim (3000) − BOLD claim (2500)"
          assertEq (expected := (800 : Amount)) (actual := getBalance fs.base 0 sequencerActor)
            "sequencer ETH = ETH claim amount"
          assertEq (expected := (2500 : Amount)) (actual := getBalance fs.base 1 sequencerActor)
            "sequencer BOLD = BOLD claim amount"
    }
  , -- ## The L2 budget grants landed on the recipient.
    { name := "GP.7.4: deposits granted the user an L2 action budget (free tier + both grants)"
    , body := do
        match runGasPoolExamplePure with
        | .error e => throw <| IO.userError s!"worked sequence rejected: {e}"
        | .ok fs =>
          -- free tier 100 + ETH grant 50 + BOLD grant 150 = 300.
          assertEq (expected := (300 : Nat))
            (actual := EpochBudgetState.currentBudget fs.epochBudgets userActor 1 100)
            "user currentBudget = freeTier + ethGrant + boldGrant"
          -- gasPoolActor signed both claims (action cost 1 each): 100 − 2 = 98.
          assertEq (expected := (98 : Nat))
            (actual := EpochBudgetState.currentBudget fs.epochBudgets gasPoolActor 1 100)
            "gasPoolActor budget debited one unit per claim"
    }
  , -- ## Genesis fidelity (state half of the GP.7.4 wiring).
    { name := "GP.7.4: genesis state declares gasPoolPolicy for gasPoolActor"
    , body := do
        assertEq
          (expected := gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold)
          (actual := exampleState.localPolicies.lookup gasPoolActor)
          "lookup gasPoolActor = gasPoolPolicy mEth mBold"
    }
  , -- ## Discipline: over-cap claims are rejected (cap, not balance).
    { name := "GP.7.4 discipline: over-cap ETH claim rejected (pool over-funded)"
    , body := do
        if admissibleAt fundedState gasPoolActor (.transfer 0 gasPoolActor sequencerActor 1500) then
          throw <| IO.userError "over-cap ETH claim was admitted"
        else pure ()
    }
  , { name := "GP.7.4 discipline: over-cap BOLD claim rejected (pool over-funded)"
    , body := do
        if admissibleAt fundedState gasPoolActor (.transfer 1 gasPoolActor sequencerActor 3500) then
          throw <| IO.userError "over-cap BOLD claim was admitted"
        else pure ()
    }
  , -- ## Discipline: the GP.7.4 headline — pool meta-action rejected.
    { name := "GP.7.4 discipline: pool revokeLocalPolicy rejected (meta-action hole closed)"
    , body := do
        if admissibleAt fundedState gasPoolActor .revokeLocalPolicy then
          throw <| IO.userError "pool meta-action (revoke) was admitted"
        else pure ()
    }
  , -- ## Discipline: fund-safety — victim-sender claim rejected.
    { name := "GP.7.4 discipline: victim-sender pool claim rejected (fund safety)"
    , body := do
        -- gasPoolActor signs a transfer whose SENDER is the user.
        if admissibleAt fundedState gasPoolActor (.transfer 0 userActor sequencerActor 100) then
          throw <| IO.userError "victim-sender pool claim was admitted"
        else pure ()
    }
  , -- ## Discipline: non-sequencer recipient rejected.
    { name := "GP.7.4 discipline: non-sequencer recipient claim rejected"
    , body := do
        if admissibleAt fundedState gasPoolActor (.transfer 0 gasPoolActor userActor 100) then
          throw <| IO.userError "non-sequencer recipient claim was admitted"
        else pure ()
    }
  , -- ## The intersection narrows ONLY gasPoolActor.
    { name := "GP.7.4: a regular user's transfer is still admitted (intersection narrows only the pool)"
    , body := do
        let st := mkExampleSignedAction (.transfer 0 userActor sequencerActor 50) userActor userFundedState
        if h : BridgeAdmissibleWith exampleVerify examplePolicy exampleDeploymentId userFundedState st then
          match apply_bridge_admissible_with_budget exampleVerify examplePolicy exampleDeploymentId
                  userFundedState st 0 h with
          | some es' =>
            assertEq (expected := (950 : Amount)) (actual := getBalance es'.base 0 userActor)
              "user debited 50 (unrestricted off the pool actor)"
            assertEq (expected := (50 : Amount)) (actual := getBalance es'.base 0 sequencerActor)
              "recipient credited 50"
          | none => throw <| IO.userError "user transfer budget-rejected (unexpected)"
        else
          throw <| IO.userError "intersected policy rejected a regular user transfer"
    }
  , -- ## The IO entry runs end-to-end via the knomosis binary's path.
    { name := "GP.7.4: knomosis gas-pool-demo IO entry runs process → log → replay (exit 0)"
    , body := do
        let code ← runGasPoolExample
        unless code = 0 do
          throw <| IO.userError s!"gas-pool-demo IO entry returned non-zero exit code {code}"
    }
  , -- ## Proof-carrying demonstrations (the example's own theorems).
    { name := "GP.7.4: example proof-carrying demonstrations hold"
    , body := do
        -- These are proven theorems in the example module; reference
        -- them so a signature change breaks this test at elaboration.
        let _t1 : exampleState.localPolicies.lookup gasPoolActor =
            gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold :=
          example_declares_gas_pool_policy
        let _t2 : examplePolicy.authorized gasPoolActor ethClaimAction :=
          example_eth_claim_authorized
        let _t3 : examplePolicy.authorized gasPoolActor boldClaimAction :=
          example_bold_claim_authorized
        let _t4 : ¬ examplePolicy.authorized gasPoolActor .revokeLocalPolicy :=
          example_rejects_pool_meta
        pure ()
    }
  , -- ## Term-level API stability for the GP.7.4 genesis-hook surface.
    { name := "GP.7.4: genesis-hook theorem API stability"
    , body := do
        let _h1 := @gasPoolGenesisState
        let _h2 := @gasPoolGenesisPolicy
        let _h3 := @gasPoolGenesis
        let _t1 := @gasPoolGenesisState_declares_policy
        let _t2 := @gasPoolGenesisState_preserves_other_localPolicies
        let _t3 := @gasPoolGenesisState_preserves_kernel_substates
        let _t4 := @gasPoolGenesisPolicy_rejects_meta
        let _t5 := @gasPoolGenesisPolicy_other_actors_unrestricted
        let _t6 := @gasPoolGenesisPolicy_rejects_non_pool_sender
        let _t7 := @gasPoolGenesisPolicy_rejects_off_gas_legs
        let _t8 := @gasPoolGenesisPolicy_rejects_non_sequencer
        let _t9 := @gasPoolGenesisPolicy_rejects_non_transfer
        let _t10 := @gasPoolGenesisPolicy_authorizes_sequencer_eth
        let _t11 := @gasPoolGenesisPolicy_authorizes_sequencer_bold
        let _t12 := @gasPoolGenesis_wires_both_halves
        -- The production budget-grant theorem the deposits rely on.
        let _t13 := @depositWithFee_grants_budget_bridge
        pure ()
    }
  ]

end GasPoolExampleTests
end LegalKernel.Test.Deployments

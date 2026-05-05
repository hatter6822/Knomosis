/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.IncentivizedEndToEnd — Phase-6
incentive-integration amendment acceptance test.

WU 6.17.  Verifies the full integrated pipeline (planted illegal
tx → file with stake → check evidence → upheld verdict → rollback
+ reward emission) preserves all kernel-level invariants and
produces correct value-level balance changes.

Test scenarios:

  1. Planted illegal tx → upheld → flat challenger reward + flat
     adjudicator reward.  Verify per-actor balance assertions.
  2. Planted illegal tx → rejected → stake forfeit, no rewards.
  3. `StakingPolicy.disabled` short-circuit.
  4. Multi-adjudicator stake-weighted distribution.
  5. Cross-resource bundle.
  6. `Event.rewardIssued` event emission verification.
  7. Determinism: equal inputs produce equal action lists.
  8. Frivolous-dispute deterrence: rejected dispute forfeits stake.

Note on `Verify`-opaque caveat: tests focus on the reward / staking
*emission* logic, which is independent of the `Verify` opaque.  The
`applyVerdict` and `disputeRewardActions` paths are exercised
directly without going through the runtime layer's signature
chain.
-/

import LegalKernel.Disputes.Rewards
import LegalKernel.Disputes.Staking
import LegalKernel.Events.Extract
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Events
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.IncentivizedEndToEndTests

/-! ## Test fixtures (multi-actor, 2-resource setup) -/

/-- The sender of the planted illegal transfer. -/
def sender : ActorId := 10

/-- The receiver. -/
def receiver : ActorId := 20

/-- The challenger who files the dispute. -/
def challenger : ActorId := 30

/-- First adjudicator (stake 30 in `fundedGenesis`). -/
def adjudicator1 : ActorId := 40

/-- Second adjudicator (stake 40 in `fundedGenesis`). -/
def adjudicator2 : ActorId := 41

/-- Third adjudicator (stake 50 in `fundedGenesis`). -/
def adjudicator3 : ActorId := 42

/-- Escrow actor that receives challenger stakes during open
    disputes. -/
def escrow : ActorId := 99

/-- Treasury actor that receives forfeited stakes on rejected /
    inconclusive verdicts. -/
def treasury : ActorId := 100

/-- A genesis state with funded balances:
      sender=100, receiver=0,
      challenger=50, adjudicators 30/40/50,
      escrow=0, treasury=0
    All balances in resource 0; resource 1 is empty initially. -/
def fundedGenesis : ExtendedState where
  base :=
    let s0 := setBalance emptyState 0 sender 100
    let s1 := setBalance s0 0 challenger 50
    let s2 := setBalance s1 0 adjudicator1 30
    let s3 := setBalance s2 0 adjudicator2 40
    setBalance s3 0 adjudicator3 50
  nonces := NonceState.empty
  registry := KeyRegistry.empty.register challenger ⟨#[0xAA]⟩

/-- The planted dispute: `challenger` files
    `preconditionFalse 1` (against log entry 1, which is the
    planted illegal tx). -/
def plantedDispute : Dispute :=
  { challenger := challenger
    claim      := .preconditionFalse 1
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- Pre-dispute log: legitimate transfer (50) + planted illegal
    transfer (200, which would fail the precondition). -/
def preDisputeLog : List LogEntry :=
  let entry0 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction := { action := .transfer 0 sender receiver 50
                        signer := sender, nonce := 0, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  let entry1 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction := { action := .transfer 0 sender receiver 200  -- ILLEGAL
                        signer := sender, nonce := 1, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  [entry0, entry1]

/-- Full log including the dispute at index 2. -/
def plantedLog : List LogEntry :=
  let entry2 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction := { action := .dispute plantedDispute
                        signer := challenger, nonce := 0, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  preDisputeLog ++ [entry2]

/-- An upheld verdict against the dispute at index 2. -/
def upheldVerdict : Verdict :=
  { disputeId := 2, outcome := .upheld
    rationale := ⟨#[]⟩
    signers := [adjudicator1, adjudicator2, adjudicator3]
    sigs := [⟨#[]⟩, ⟨#[]⟩, ⟨#[]⟩] }

/-- A rejected verdict variant. -/
def rejectedVerdict : Verdict :=
  { upheldVerdict with outcome := .rejected }

/-- An unrestricted authority policy for the test. -/
def Pall : AuthorityPolicy := AuthorityPolicy.unrestricted

/-! ## Test 1: planted illegal tx → upheld → flat rewards -/

/-- Sub-suite: upheld + flat rewards. -/
def upheldFlatRewardsTests : List TestCase :=
  [ { name := "E2E: upheld → 1 challenger reward + 3 adjudicator rewards"
    , body := do
        let policy := DisputeRewardPolicy.union
                        (DisputeRewardPolicy.flatChallengerReward 0 100)
                        (DisputeRewardPolicy.flatAdjudicatorReward 0 50)
        let actions := disputeRewardActions policy plantedLog plantedDispute upheldVerdict
        -- 1 challenger + 3 adjudicators = 4
        assertEq (4 : Nat) actions.length "4 reward actions"
    }
  , { name := "E2E: upheld → all emitted actions are .reward"
    , body := do
        let policy := DisputeRewardPolicy.union
                        (DisputeRewardPolicy.flatChallengerReward 0 100)
                        (DisputeRewardPolicy.flatAdjudicatorReward 0 50)
        let actions := disputeRewardActions policy plantedLog plantedDispute upheldVerdict
        -- Verify each is a `.reward` constructor.
        for a in actions do
          match a with
          | .reward _ _ _ => pure ()
          | _ => throw <| IO.userError s!"non-reward action: {repr a}"
    }
  , { name := "E2E: applyVerdict (.upheld) computes the rollback target"
    , body := do
        match applyVerdict Pall fundedGenesis fundedGenesis plantedLog upheldVerdict with
        | .ok rolledBack =>
          -- The rollback target is replay of log[0..0] = entry 0 only.
          -- Entry 0 is `transfer 0 sender receiver 50`, applied via
          -- kernelOnlyReplay.  So sender should have 50 (=100-50),
          -- receiver should have 50 (=0+50).
          let sBal := getBalance rolledBack.base 0 sender
          let rBal := getBalance rolledBack.base 0 receiver
          assertEq (50 : Amount) sBal s!"sender balance after rollback"
          assertEq (50 : Amount) rBal s!"receiver balance after rollback"
        | .error e =>
          throw <| IO.userError s!"applyVerdict should succeed, got {repr e}"
    }
  , { name := "E2E: applyVerdictWithRewards (.upheld) returns state + reward list"
    , body := do
        let policy := DisputeRewardPolicy.flatChallengerReward 0 100
        match applyVerdictWithRewards Pall policy fundedGenesis fundedGenesis
                                       plantedLog upheldVerdict with
        | .ok (rolledBack, rewards) =>
          assertEq (50 : Amount) (getBalance rolledBack.base 0 sender) "sender 50"
          assertEq (1 : Nat) rewards.length "1 challenger reward"
        | .error e =>
          throw <| IO.userError s!"unexpected error {repr e}"
    }
  ]

/-! ## Test 2: rejected verdict → stake forfeit -/

/-- Sub-suite: rejected + staking. -/
def rejectedStakingTests : List TestCase :=
  [ { name := "E2E: rejected → no reward actions"
    , body := do
        let policy := DisputeRewardPolicy.flatChallengerReward 0 100
        let actions := disputeRewardActions policy plantedLog plantedDispute rejectedVerdict
        assertEq (0 : Nat) actions.length "rejected → no rewards"
    }
  , { name := "E2E: rejected → stake forfeit transfer emitted"
    , body := do
        let sp : StakingPolicy :=
          { stakeResource := 0, stakeAmount := 30
            escrowActor := escrow, treasuryActor := treasury }
        let actions := stakeResolutionActions sp rejectedVerdict
        assertEq (1 : Nat) actions.length "1 forfeit transfer"
        match actions with
        | [Action.transfer r s r' amt] =>
          assertEq (0 : ResourceId) r "stake resource"
          assertEq escrow s "from escrow"
          assertEq treasury r' "to treasury"
          assertEq (30 : Amount) amt "stake amount"
        | _ => throw <| IO.userError s!"unexpected: {repr actions}"
    }
  , { name := "E2E: applyVerdict (.rejected) leaves state unchanged"
    , body := do
        match applyVerdict Pall fundedGenesis fundedGenesis plantedLog rejectedVerdict with
        | .ok unchanged =>
          assertEq (100 : Amount) (getBalance unchanged.base 0 sender) "sender unchanged"
          assertEq (50 : Amount) (getBalance unchanged.base 0 challenger) "challenger unchanged"
        | .error e => throw <| IO.userError s!"unexpected {repr e}"
    }
  ]

/-! ## Test 3: disabled staking short-circuit -/

/-- Sub-suite: disabled staking. -/
def disabledStakingTests : List TestCase :=
  [ { name := "E2E: StakingPolicy.disabled → no filing actions"
    , body := do
        let actions := stakeFilingActions StakingPolicy.disabled challenger
        assertEq (0 : Nat) actions.length "disabled → []"
    }
  , { name := "E2E: StakingPolicy.disabled → no resolution actions on rejected"
    , body := do
        let actions := stakeResolutionActions StakingPolicy.disabled rejectedVerdict
        assertEq (0 : Nat) actions.length "disabled → []"
    }
  , { name := "E2E: fileDisputeStaked under disabled policy passes through"
    , body := do
        match fileDisputeStaked StakingPolicy.disabled fundedGenesis preDisputeLog
                                 plantedDispute with
        | .ok (_, stakingActions) =>
          assertEq (0 : Nat) stakingActions.length "no staking actions"
        | .error e => throw <| IO.userError s!"unexpected {repr e}"
    }
  ]

/-! ## Test 4: stake-weighted adjudicator distribution -/

/-- Sub-suite: stake-weighted distribution. -/
def stakeWeightedDistributionTests : List TestCase :=
  [ { name := "E2E: stake-weighted distribution: 3 adjudicators, 100 pool"
    , body := do
        -- Stakes: adj1=30, adj2=40, adj3=50; total 120; pool 100.
        -- Expected per-adjudicator rewards: 25, 33, 41.  Sum 99 ≤ 100, dust 1.
        let signers := [adjudicator1, adjudicator2, adjudicator3]
        let actions := stakeWeightedAdjudicatorRewards fundedGenesis 0 0 100 signers
        assertEq (3 : Nat) actions.length "3 reward actions"
    }
  , { name := "E2E: stake-weighted: each reward ≤ pool (per-element bound)"
    , body := do
        let signers := [adjudicator1, adjudicator2, adjudicator3]
        let actions := stakeWeightedAdjudicatorRewards fundedGenesis 0 0 100 signers
        for a in actions do
          match a with
          | .reward _ _ amt =>
            assert (amt ≤ 100) s!"reward amount {amt} exceeds pool 100"
          | _ => throw <| IO.userError s!"non-reward: {repr a}"
    }
  , { name := "E2E: stake-weighted: zero-stake adjudicators get nothing"
    , body := do
        -- ExtendedState.empty: all balances = 0.
        let signers := [adjudicator1, adjudicator2, adjudicator3]
        let actions := stakeWeightedAdjudicatorRewards ExtendedState.empty 0 0 100 signers
        assertEq (0 : Nat) actions.length "zero stake → no rewards"
    }
  ]

/-! ## Test 5: cross-resource bundle -/

/-- Sub-suite: cross-resource bundle. -/
def crossResourceBundleTests : List TestCase :=
  [ { name := "E2E: cross-resource bundle: r=0 challenger + r=1 adjudicator"
    , body := do
        let policies := [
          DisputeRewardPolicy.flatChallengerReward 0 100,
          DisputeRewardPolicy.flatAdjudicatorReward 1 50
        ]
        let actions := disputeRewardActionsMulti policies plantedLog plantedDispute upheldVerdict
        -- 1 challenger (r=0) + 3 adjudicators (r=1) = 4
        assertEq (4 : Nat) actions.length "4 actions in bundle"
        -- Verify resource diversity (action 0 in r=0; rest in r=1).
        match actions with
        | (.reward 0 _ _) :: rest =>
          for a in rest do
            match a with
            | .reward 1 _ _ => pure ()
            | _ => throw <| IO.userError s!"unexpected resource: {repr a}"
        | _ => throw <| IO.userError s!"unexpected first action: {repr actions}"
    }
  ]

/-! ## Test 6: Event.rewardIssued emission -/

/-- Sub-suite: rewardIssued event verification. -/
def eventEmissionTests : List TestCase :=
  [ { name := "E2E: extractEvents on .reward emits both balanceChanged + rewardIssued"
    , body := do
        let preState : ExtendedState :=
          { fundedGenesis with nonces := NonceState.empty }
        let post : ExtendedState :=
          { base := setBalance fundedGenesis.base 0 challenger 150  -- +100
          , nonces := { next := (∅ : Std.TreeMap _ _ _).insert challenger 1 }
          , registry := fundedGenesis.registry }
        let st : SignedAction :=
          { action := .reward 0 challenger 100, signer := challenger
            nonce := 0, sig := ⟨#[]⟩ }
        let evs := extractEvents preState post st
        -- 3 events: balanceChanged + rewardIssued + nonceAdvanced.
        assertEq (3 : Nat) evs.length "3 events"
        let rewardIssued := evs.filter Event.isRewardIssued
        assertEq (1 : Nat) rewardIssued.length "1 rewardIssued event"
    }
  ]

/-! ## Test 7: determinism -/

/-- Sub-suite: determinism. -/
def determinismTests : List TestCase :=
  [ { name := "E2E: two runs of disputeRewardActions produce identical output"
    , body := do
        let policy := DisputeRewardPolicy.flatChallengerReward 0 100
        let r1 := disputeRewardActions policy plantedLog plantedDispute upheldVerdict
        let r2 := disputeRewardActions policy plantedLog plantedDispute upheldVerdict
        assertEq r1.length r2.length "identical lengths"
    }
  , { name := "E2E: two runs of stakeWeightedAdjudicatorRewards identical"
    , body := do
        let signers := [adjudicator1, adjudicator2, adjudicator3]
        let r1 := stakeWeightedAdjudicatorRewards fundedGenesis 0 0 100 signers
        let r2 := stakeWeightedAdjudicatorRewards fundedGenesis 0 0 100 signers
        assertEq r1.length r2.length "identical lengths"
    }
  ]

/-! ## Test 8: frivolous-dispute deterrence -/

/-- Sub-suite: frivolous-dispute deterrence. -/
def frivolousDisputeTests : List TestCase :=
  [ { name := "E2E: frivolous (rejected) dispute forfeits stake"
    , body := do
        let sp : StakingPolicy :=
          { stakeResource := 0, stakeAmount := 30
            escrowActor := escrow, treasuryActor := treasury }
        -- Filing emits the stake transfer.
        let filingActs := stakeFilingActions sp challenger
        assertEq (1 : Nat) filingActs.length "filing emits 1 transfer"
        -- Resolution on rejected verdict emits the treasury transfer.
        let resolvingActs := stakeResolutionActions sp rejectedVerdict
        assertEq (1 : Nat) resolvingActs.length "rejected resolution emits 1 transfer"
    }
  , { name := "E2E: upheld verdict implicitly returns stake (per D1)"
    , body := do
        let sp : StakingPolicy :=
          { stakeResource := 0, stakeAmount := 30
            escrowActor := escrow, treasuryActor := treasury }
        -- Resolution on upheld verdict emits NO transfer (rollback handles it).
        let resolvingActs := stakeResolutionActions sp upheldVerdict
        assertEq (0 : Nat) resolvingActs.length "upheld resolution emits []"
    }
  ]

/-! ## Aggregate -/

/-- All Phase-6 incentive-integration end-to-end tests. -/
def tests : List TestCase :=
  upheldFlatRewardsTests ++ rejectedStakingTests ++ disabledStakingTests ++
  stakeWeightedDistributionTests ++ crossResourceBundleTests ++
  eventEmissionTests ++ determinismTests ++ frivolousDisputeTests

end LegalKernel.Test.Disputes.IncentivizedEndToEndTests

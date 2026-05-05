/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.Rewards — runtime tests for the Phase-6
incentive-integration amendment's reward-policy infrastructure.

Exercises:

  * `DisputeRewardPolicy` atomic constructors (`empty`,
    `flatChallengerReward`, `flatAdjudicatorReward`, `union`).
  * `disputeRewardActions` value-level emission + theorem API
    stability.
  * `applyVerdictWithRewards` wrapper.
  * Multi-policy bundle (`disputeRewardActionsMulti`).
  * Graduated policies (`byClaimVariant`,
    `proportionalChallengerReward`).
  * Stake-weighted adjudicator rewards (per-element bound +
    edge cases).
-/

import LegalKernel.Disputes.Rewards
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.RewardsTests

/-! ## Test fixtures -/

/-- A trivial Dispute fixture. -/
def fixtureDispute : Dispute :=
  { challenger := 1
    claim      := .preconditionFalse 0
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- A trivial upheld Verdict fixture (challenger 1, two
    adjudicators 10, 20). -/
def fixtureVerdictUpheld : Verdict :=
  { disputeId := 1, outcome := .upheld
    rationale := ⟨#[]⟩, signers := [10, 20], sigs := [⟨#[]⟩, ⟨#[]⟩] }

/-- A rejected variant of `fixtureVerdictUpheld`. -/
def fixtureVerdictRejected : Verdict :=
  { fixtureVerdictUpheld with outcome := .rejected }

/-! ## Atomic constructors -/

/-- Sub-suite: atomic policies. -/
def atomicConstructorTests : List TestCase :=
  [ { name := "empty policy emits no actions"
    , body := do
        let actions := disputeRewardActions DisputeRewardPolicy.empty
                          [] fixtureDispute fixtureVerdictUpheld
        assertEq (0 : Nat) actions.length "empty policy action count"
    }
  , { name := "flatChallengerReward emits 1 action on upheld"
    , body := do
        let policy := DisputeRewardPolicy.flatChallengerReward 0 100
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictUpheld
        assertEq (1 : Nat) actions.length "challenger reward action count"
    }
  , { name := "flatChallengerReward emits 0 actions on rejected"
    , body := do
        let policy := DisputeRewardPolicy.flatChallengerReward 0 100
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictRejected
        assertEq (0 : Nat) actions.length "challenger reward action count on rejected"
    }
  , { name := "flatAdjudicatorReward emits 1 action per signer"
    , body := do
        let policy := DisputeRewardPolicy.flatAdjudicatorReward 0 50
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictUpheld
        -- 2 signers in fixtureVerdictUpheld
        assertEq (2 : Nat) actions.length "adjudicator reward action count"
    }
  , { name := "flatAdjudicatorReward emits per-signer rewards on rejected too"
    , body := do
        -- Adjudicators are paid for their work regardless of outcome.
        let policy := DisputeRewardPolicy.flatAdjudicatorReward 0 50
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictRejected
        assertEq (2 : Nat) actions.length "adjudicator paid even on rejected"
    }
  , { name := "union: combines challenger + adjudicator rewards"
    , body := do
        let policy := DisputeRewardPolicy.union
                        (DisputeRewardPolicy.flatChallengerReward 0 100)
                        (DisputeRewardPolicy.flatAdjudicatorReward 0 50)
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictUpheld
        -- 1 challenger + 2 adjudicators = 3
        assertEq (3 : Nat) actions.length "union action count"
    }
  ]

/-! ## Theorem API stability -/

/-- Sub-suite: API stability. -/
def apiStabilityTests : List TestCase :=
  [ { name := "disputeRewardActions_deterministic API stability"
    , body := do
        let _proof : ∀ (policy : DisputeRewardPolicy)
                       (log₁ log₂ : List LogEntry)
                       (d₁ d₂ : Dispute) (v₁ v₂ : Verdict),
            log₁ = log₂ → d₁ = d₂ → v₁ = v₂ →
            disputeRewardActions policy log₁ d₁ v₁ =
            disputeRewardActions policy log₂ d₂ v₂ :=
          fun policy l₁ l₂ d₁ d₂ v₁ v₂ hl hd hv =>
            disputeRewardActions_deterministic policy l₁ l₂ d₁ d₂ v₁ v₂ hl hd hv
        pure ()
    }
  , { name := "disputeRewardActions_emits_only_rewards API stability"
    , body := do
        let _proof : ∀ (policy : DisputeRewardPolicy)
                       (log : List LogEntry) (d : Dispute) (v : Verdict),
            ∀ a ∈ disputeRewardActions policy log d v,
              ∃ r to amt, a = Action.reward r to amt :=
          fun policy log d v => disputeRewardActions_emits_only_rewards policy log d v
        pure ()
    }
  , { name := "disputeRewardActions_length_bound API stability"
    , body := do
        let _proof : ∀ (policy : DisputeRewardPolicy)
                       (log : List LogEntry) (d : Dispute) (v : Verdict),
            (disputeRewardActions policy log d v).length ≤ 1 + v.signers.length :=
          fun policy log d v => disputeRewardActions_length_bound policy log d v
        pure ()
    }
  , { name := "applyVerdictWithRewards_deterministic API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (rewardPolicy : DisputeRewardPolicy)
                       (es₁ es₂ g₁ g₂ : ExtendedState)
                       (l₁ l₂ : List LogEntry) (v₁ v₂ : Verdict),
            es₁ = es₂ → g₁ = g₂ → l₁ = l₂ → v₁ = v₂ →
            applyVerdictWithRewards P rewardPolicy es₁ g₁ l₁ v₁ =
            applyVerdictWithRewards P rewardPolicy es₂ g₂ l₂ v₂ :=
          fun P rp e₁ e₂ g₁ g₂ l₁ l₂ v₁ v₂ he hg hl hv =>
            applyVerdictWithRewards_deterministic P rp e₁ e₂ g₁ g₂ l₁ l₂ v₁ v₂ he hg hl hv
        pure ()
    }
  ]

/-! ## Multi-policy bundle -/

/-- Sub-suite: multi-policy bundle. -/
def multiPolicyTests : List TestCase :=
  [ { name := "disputeRewardActionsMulti []: no actions"
    , body := do
        let actions := disputeRewardActionsMulti [] [] fixtureDispute fixtureVerdictUpheld
        assertEq (0 : Nat) actions.length "empty bundle action count"
    }
  , { name := "disputeRewardActionsMulti: cross-resource bundle"
    , body := do
        -- challenger reward in r=0; adjudicator reward in r=1.
        let policies := [
          DisputeRewardPolicy.flatChallengerReward 0 100,
          DisputeRewardPolicy.flatAdjudicatorReward 1 50
        ]
        let actions := disputeRewardActionsMulti policies [] fixtureDispute fixtureVerdictUpheld
        -- 1 challenger + 2 adjudicators = 3.
        assertEq (3 : Nat) actions.length "bundle action count"
    }
  , { name := "disputeRewardActionsMulti single-policy: equiv to atomic"
    , body := do
        let policy := DisputeRewardPolicy.flatChallengerReward 0 100
        let multi := disputeRewardActionsMulti [policy] [] fixtureDispute fixtureVerdictUpheld
        let atomic := disputeRewardActions policy [] fixtureDispute fixtureVerdictUpheld
        assertEq atomic.length multi.length "single-policy equiv"
    }
  ]

/-! ## Graduated rewards (WU 6.21) -/

/-- Sub-suite: graduated rewards. -/
def graduatedRewardTests : List TestCase :=
  [ { name := "byClaimVariant: rejected outcome → no reward"
    , body := do
        let policy := DisputeRewardPolicy.byClaimVariant 0 100 50 30 200 1000
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictRejected
        assertEq (0 : Nat) actions.length "rejected → no reward"
    }
  , { name := "byClaimVariant: upheld preconditionFalse → 100"
    , body := do
        -- fixtureDispute has claim = preconditionFalse 0
        let policy := DisputeRewardPolicy.byClaimVariant 0 100 50 30 200 1000
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictUpheld
        assertEq (1 : Nat) actions.length "preconditionFalse upheld emits 1"
    }
  , { name := "proportionalChallengerReward: rejected → no reward"
    , body := do
        let policy := DisputeRewardPolicy.proportionalChallengerReward 0 1 10
        let actions := disputeRewardActions policy [] fixtureDispute fixtureVerdictRejected
        assertEq (0 : Nat) actions.length "rejected → no reward"
    }
  , { name := "claimImpugnedAmount: returns none on empty log"
    , body := do
        match claimImpugnedAmount [] (.preconditionFalse 0) with
        | none => pure ()
        | some _ => throw <| IO.userError "expected none on empty log"
    }
  , { name := "claimImpugnedAmount: returns none on freezeResource impugned"
    , body := do
        let frozenEntry : LogEntry :=
          { prevHash := ⟨#[]⟩
            signedAction := { action := .freezeResource 1, signer := 1
                              nonce := 0, sig := ⟨#[]⟩ }
            postStateHash := ⟨#[]⟩ }
        match claimImpugnedAmount [frozenEntry] (.preconditionFalse 0) with
        | none => pure ()
        | some _ => throw <| IO.userError "expected none on freeze action"
    }
  , { name := "claimImpugnedAmount: returns transfer's amount field"
    , body := do
        let entry : LogEntry :=
          { prevHash := ⟨#[]⟩
            signedAction := { action := .transfer 0 1 2 100, signer := 1
                              nonce := 0, sig := ⟨#[]⟩ }
            postStateHash := ⟨#[]⟩ }
        match claimImpugnedAmount [entry] (.preconditionFalse 0) with
        | some 100 => pure ()
        | other => throw <| IO.userError s!"expected some 100, got {repr other}"
    }
  ]

/-! ## Stake-weighted adjudicator rewards (WU 6.22) -/

/-- Sub-suite: stake-weighted distribution. -/
def stakeWeightedTests : List TestCase :=
  [ { name := "stakeWeightedAdjudicatorRewards: zero pool → []"
    , body := do
        let actions := stakeWeightedAdjudicatorRewards
                          ExtendedState.empty 0 0 0 [10, 20]
        assertEq (0 : Nat) actions.length "zero pool actions"
    }
  , { name := "stakeWeightedAdjudicatorRewards: zero total stake → []"
    , body := do
        -- Empty ExtendedState: all balances are 0.
        let actions := stakeWeightedAdjudicatorRewards
                          ExtendedState.empty 0 0 100 [10, 20]
        assertEq (0 : Nat) actions.length "zero total stake actions"
    }
  , { name := "stakeWeightedAdjudicatorRewards: 3-adjudicator distribution"
    , body := do
        -- Set up 3 adjudicators with stakes 30, 40, 50; pool 100.
        -- Total stake 120; expected rewards: 100 * 30 / 120 = 25,
        -- 100 * 40 / 120 = 33, 100 * 50 / 120 = 41.  (Sum 99; dust 1.)
        let es : ExtendedState :=
          { base := setBalance (setBalance (setBalance emptyState 0 10 30)
                                            0 20 40)
                                0 30 50
            nonces := NonceState.empty
            registry := KeyRegistry.empty }
        let actions := stakeWeightedAdjudicatorRewards es 0 0 100 [10, 20, 30]
        assertEq (3 : Nat) actions.length "3 reward actions emitted"
    }
  , { name := "stakeWeightedAdjudicatorRewards: each_le_pool API stability"
    , body := do
        let _proof : ∀ (es : ExtendedState) (sR rR : ResourceId) (pool : Amount)
                       (signers : List ActorId),
            ∀ a ∈ stakeWeightedAdjudicatorRewards es sR rR pool signers,
              ∃ r to amt, a = Action.reward r to amt ∧ amt ≤ pool :=
          fun es sR rR pool signers =>
            stakeWeightedAdjudicatorRewards_each_le_pool es sR rR pool signers
        pure ()
    }
  , { name := "stakeWeightedAdjudicatorRewards: emits_only_rewards"
    , body := do
        let _proof : ∀ (es : ExtendedState) (sR rR : ResourceId) (pool : Amount)
                       (signers : List ActorId),
            ∀ a ∈ stakeWeightedAdjudicatorRewards es sR rR pool signers,
              ∃ r to amt, a = Action.reward r to amt :=
          fun es sR rR pool signers =>
            stakeWeightedAdjudicatorRewards_emits_only_rewards es sR rR pool signers
        pure ()
    }
  , { name := "getBalance_le_totalSignerStake API stability"
    , body := do
        let _proof : ∀ (es : ExtendedState) (resource : ResourceId)
                       (signer : ActorId) (signers : List ActorId),
            signer ∈ signers →
            getBalance es.base resource signer ≤
              totalSignerStake es resource signers :=
          fun es resource signer signers h =>
            getBalance_le_totalSignerStake es resource signer signers h
        pure ()
    }
  ]

/-! ## Aggregate -/

/-- All Phase-6 incentive-integration reward-policy tests. -/
def tests : List TestCase :=
  atomicConstructorTests ++ apiStabilityTests ++ multiPolicyTests ++
  graduatedRewardTests ++ stakeWeightedTests

end LegalKernel.Test.Disputes.RewardsTests

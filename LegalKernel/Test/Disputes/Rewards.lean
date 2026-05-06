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
    rationale := ⟨#[]⟩, signatures := [(10, ⟨#[]⟩), (20, ⟨#[]⟩)] }

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
  , { name := "applyVerdictWithRewardsUnchecked_deterministic API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (rewardPolicy : DisputeRewardPolicy)
                       (es₁ es₂ g₁ g₂ : ExtendedState)
                       (l₁ l₂ : List LogEntry) (v₁ v₂ : Verdict),
            es₁ = es₂ → g₁ = g₂ → l₁ = l₂ → v₁ = v₂ →
            applyVerdictWithRewardsUnchecked P rewardPolicy es₁ g₁ l₁ v₁ =
            applyVerdictWithRewardsUnchecked P rewardPolicy es₂ g₂ l₂ v₂ :=
          fun P rp e₁ e₂ g₁ g₂ l₁ l₂ v₁ v₂ he hg hl hv =>
            applyVerdictWithRewardsUnchecked_deterministic P rp e₁ e₂ g₁ g₂ l₁ l₂ v₁ v₂ he hg hl hv
        pure ()
    }
  , { name := "union_challenger_left_bias_some API stability"
    , body := do
        let _proof : ∀ (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry)
                       (d : Dispute) (outcome : EvidenceVerdict)
                       (r : ResourceId) (amt : Amount),
            p₁.challengerReward log d outcome = some (r, amt) →
            (p₁.union p₂).challengerReward log d outcome = some (r, amt) :=
          fun p₁ p₂ log d outcome r amt h =>
            union_challenger_left_bias_some p₁ p₂ log d outcome r amt h
        pure ()
    }
  , { name := "union_challenger_left_bias_fallthrough API stability"
    , body := do
        let _proof : ∀ (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry)
                       (d : Dispute) (outcome : EvidenceVerdict),
            p₁.challengerReward log d outcome = none →
            (p₁.union p₂).challengerReward log d outcome =
            p₂.challengerReward log d outcome :=
          fun p₁ p₂ log d outcome h =>
            union_challenger_left_bias_fallthrough p₁ p₂ log d outcome h
        pure ()
    }
  , { name := "union_adjudicator_left_bias_some API stability"
    , body := do
        let _proof : ∀ (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry)
                       (v : Verdict) (r : ResourceId) (amt : Amount),
            p₁.adjudicatorReward log v = some (r, amt) →
            (p₁.union p₂).adjudicatorReward log v = some (r, amt) :=
          fun p₁ p₂ log v r amt h =>
            union_adjudicator_left_bias_some p₁ p₂ log v r amt h
        pure ()
    }
  , { name := "union_adjudicator_left_bias_fallthrough API stability"
    , body := do
        let _proof : ∀ (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry)
                       (v : Verdict),
            p₁.adjudicatorReward log v = none →
            (p₁.union p₂).adjudicatorReward log v =
            p₂.adjudicatorReward log v :=
          fun p₁ p₂ log v h =>
            union_adjudicator_left_bias_fallthrough p₁ p₂ log v h
        pure ()
    }
  , { name := "union: empty + flatChallengerReward = flatChallengerReward (left fallthrough)"
    , body := do
        -- empty.challengerReward = none, so union falls through to p₂.
        let p₁ := DisputeRewardPolicy.empty
        let p₂ := DisputeRewardPolicy.flatChallengerReward 0 100
        let unionPolicy := p₁.union p₂
        match unionPolicy.challengerReward [] fixtureDispute .upheld with
        | some (0, 100) => pure ()
        | other => throw <| IO.userError s!"expected some (0, 100), got {repr other}"
    }
  , { name := "union: flatAdjudicatorReward + empty = flatAdjudicatorReward (left bias)"
    , body := do
        -- Adjudicator branch: p₁ returns some, so union returns p₁'s value.
        let p₁ := DisputeRewardPolicy.flatAdjudicatorReward 1 50
        let p₂ := DisputeRewardPolicy.empty
        let unionPolicy := p₁.union p₂
        match unionPolicy.adjudicatorReward [] fixtureVerdictUpheld with
        | some (1, 50) => pure ()
        | other => throw <| IO.userError s!"expected some (1, 50), got {repr other}"
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
  , { name := "proportionalChallengerReward: 10% reward (factor=1, divisor=10) on 100-amount transfer"
    , body := do
        -- transfer of 100 → reward = 1 * 100 / 10 = 10.
        let entry : LogEntry :=
          { prevHash := ⟨#[]⟩
            signedAction := { action := .transfer 0 1 2 100, signer := 1
                              nonce := 0, sig := ⟨#[]⟩ }
            postStateHash := ⟨#[]⟩ }
        let policy := DisputeRewardPolicy.proportionalChallengerReward 0 1 10
        match policy.challengerReward [entry] fixtureDispute .upheld with
        | some (0, 10) => pure ()
        | other => throw <| IO.userError s!"expected some (0, 10), got {repr other}"
    }
  , { name := "proportionalChallengerReward: divisor=0 returns some (resource, 0) (Nat n/0 = 0)"
    , body := do
        -- Documented edge case: divisor=0 produces 0 (not an error or `none`).
        let entry : LogEntry :=
          { prevHash := ⟨#[]⟩
            signedAction := { action := .transfer 0 1 2 100, signer := 1
                              nonce := 0, sig := ⟨#[]⟩ }
            postStateHash := ⟨#[]⟩ }
        let policy := DisputeRewardPolicy.proportionalChallengerReward 0 1 0
        match policy.challengerReward [entry] fixtureDispute .upheld with
        | some (0, 0) => pure ()
        | other => throw <| IO.userError s!"expected some (0, 0), got {repr other}"
    }
  , { name := "proportionalChallengerReward_value_correct API stability"
    , body := do
        let _proof : ∀ (resource : ResourceId) (factor divisor amt : Amount)
                       (log : List LogEntry) (d : Dispute),
            claimImpugnedAmount log d.claim = some amt →
            (DisputeRewardPolicy.proportionalChallengerReward resource factor divisor).challengerReward
                log d .upheld = some (resource, factor * amt / divisor) :=
          fun r f d a log dis h =>
            proportionalChallengerReward_value_correct r f d a log dis h
        pure ()
    }
  , { name := "proportionalChallengerReward_returns_none_on_amountless_impugned API stability"
    , body := do
        let _proof : ∀ (resource : ResourceId) (factor divisor : Amount)
                       (log : List LogEntry) (d : Dispute),
            claimImpugnedAmount log d.claim = none →
            (DisputeRewardPolicy.proportionalChallengerReward resource factor divisor).challengerReward
                log d .upheld = none :=
          fun r f div log dis h =>
            proportionalChallengerReward_returns_none_on_amountless_impugned r f div log dis h
        pure ()
    }
  , { name := "byClaimVariant: signatureInvalid claim → second-tier amount"
    , body := do
        let dSigInv : Dispute :=
          { fixtureDispute with claim := .signatureInvalid 0 }
        -- byClaimVariant 0 100 50 30 200 1000 — sigInv tier is 50.
        let policy := DisputeRewardPolicy.byClaimVariant 0 100 50 30 200 1000
        match policy.challengerReward [] dSigInv .upheld with
        | some (0, 50) => pure ()
        | other => throw <| IO.userError s!"expected some (0, 50), got {repr other}"
    }
  , { name := "byClaimVariant: doubleApply claim → fifth-tier amount"
    , body := do
        let dDouble : Dispute :=
          { fixtureDispute with claim := .doubleApply 0 1 }
        let policy := DisputeRewardPolicy.byClaimVariant 0 100 50 30 200 1000
        match policy.challengerReward [] dDouble .upheld with
        | some (0, 1000) => pure ()
        | other => throw <| IO.userError s!"expected some (0, 1000), got {repr other}"
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

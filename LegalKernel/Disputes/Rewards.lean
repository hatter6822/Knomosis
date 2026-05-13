/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.Rewards — deployment-supplied reward policies
for the §8.4 dispute pipeline.

Phase-6 incentive-integration amendment.  Provides:

  * `DisputeRewardPolicy` structure: deployment-supplied policy
    returning `Option (ResourceId × Amount)` for the challenger
    and per-adjudicator rewards.  Pure functions of the log,
    dispute, and verdict — deterministic.
  * Atomic constructors: `empty`, `flatChallengerReward`,
    `flatAdjudicatorReward`, `union` (left-biased fallthrough).
  * Graduated constructors (WU 6.21): `byClaimVariant`,
    `proportionalChallengerReward`, plus the `claimImpugnedAmount`
    helper.
  * Stake-weighted adjudicator rewards (WU 6.22):
    `stakeWeightedAdjudicatorRewards` with per-element + sum-le-pool
    dust-bound theorems.
  * Emission helpers: `disputeRewardActions` (atomic),
    `disputeRewardActionsMulti` (list-of-policies; WU 6.23).
  * Composable wrapper: `applyVerdictWithRewards` (single policy)
    + `applyVerdictWithRewardsMulti` (multi-policy).

All emitted actions are `Action.reward _ _ _`, so the entire
mechanism is positive-incentive (no token destruction); kernel-
level monotonicity is preserved.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong reward amounts (deployment-level
adjudication problem) but cannot violate any kernel invariant.
-/

import LegalKernel.Authority.Action
import LegalKernel.Disputes.Types
import LegalKernel.Disputes.Filing
import LegalKernel.Disputes.Verdict
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority
open LegalKernel.Runtime

/-! ## DisputeRewardPolicy structure (WU 6.15a) -/

/-- Deployment-supplied reward policy for dispute outcomes.

    Both fields are pure deterministic functions: same inputs
    always produce same outputs.  This mirrors the §8.4.3
    determinism property of `checkEvidence` / `applyVerdict`.

    Both fields take `log : List LogEntry` so graduated policies
    (WU 6.21) can read the impugned action's amount field.

    The runtime is responsible for signing the emitted
    `Action.reward` records with a deployment-supplied "system
    actor" key and appending them to the log via the standard
    `apply_admissible` path. -/
structure DisputeRewardPolicy where
  /-- Reward to issue to the challenger.  Returns `none` if the
      policy doesn't reward this dispute outcome (typical: `none`
      for `.rejected` / `.inconclusive`, `some (r, amt)` for
      `.upheld`). -/
  challengerReward  : List LogEntry → Dispute → EvidenceVerdict
                      → Option (ResourceId × Amount)
  /-- Per-adjudicator reward (uniform across signers).  Returns
      `none` if adjudicators are unpaid by this policy. -/
  adjudicatorReward : List LogEntry → Verdict
                      → Option (ResourceId × Amount)

/-! ## Atomic constructors (WU 6.15b) -/

/-- The empty reward policy: no rewards issued.  Equivalent to
    "running the dispute pipeline without incentives" (e.g. for
    deployments where adjudicators are paid out-of-band). -/
def DisputeRewardPolicy.empty : DisputeRewardPolicy where
  challengerReward  _ _ _ := none
  adjudicatorReward _ _   := none

/-- Flat-amount challenger reward: a fixed payout per upheld
    dispute, regardless of which claim variant was upheld.  Useful
    template for fixed bug-bounty programmes. -/
def DisputeRewardPolicy.flatChallengerReward
    (resource : ResourceId) (amount : Amount) : DisputeRewardPolicy where
  challengerReward _ _ outcome :=
    match outcome with
    | .upheld => some (resource, amount)
    | _       => none
  adjudicatorReward _ _ := none

/-- Flat-amount adjudicator reward (per signer per verdict).
    Issued regardless of outcome — adjudicators are paid for their
    work, not just for upheld verdicts. -/
def DisputeRewardPolicy.flatAdjudicatorReward
    (resource : ResourceId) (amount : Amount) : DisputeRewardPolicy where
  challengerReward  _ _ _ := none
  adjudicatorReward _ _   := some (resource, amount)

/-- Left-biased fallthrough union: `(p₁.union p₂).challengerReward`
    returns `p₁`'s value if it is `some`, else falls through to
    `p₂`.  Same for `adjudicatorReward`.

    Use this combinator to compose two policies where you want one
    to take precedence.  For multi-resource bundles (where you want
    BOTH `p₁`'s rewards AND `p₂`'s rewards), use
    `disputeRewardActionsMulti` (WU 6.23) instead. -/
def DisputeRewardPolicy.union
    (p₁ p₂ : DisputeRewardPolicy) : DisputeRewardPolicy where
  challengerReward log d outcome :=
    (p₁.challengerReward log d outcome).orElse
      (fun _ => p₂.challengerReward log d outcome)
  adjudicatorReward log v :=
    (p₁.adjudicatorReward log v).orElse
      (fun _ => p₂.adjudicatorReward log v)

/-! ## Reward-action emission (WU 6.15c) -/

/-- Compute the reward `Action`s for a verdict outcome, given the
    deployment's reward policy and the underlying dispute.

    Returns a list (possibly empty) of `Action.reward` actions:
    one for the challenger (if rewarded by the policy) plus one
    per signed adjudicator (if rewarded by the policy).

    The runtime signs each emitted action with a deployment-
    supplied "system actor" key and appends them to the log via
    `apply_admissible`. -/
def disputeRewardActions
    (policy : DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) : List Action :=
  let chList :=
    match policy.challengerReward log d v.outcome with
    | some (r, amt) => [Action.reward r d.challenger amt]
    | none          => []
  let adjList :=
    match policy.adjudicatorReward log v with
    | some (r, amt) => v.signers.map (fun a => Action.reward r a amt)
    | none          => []
  chList ++ adjList

/-! ## Core theorems (WU 6.15d) -/

/-- Determinism: equal inputs produce equal reward action lists. -/
theorem disputeRewardActions_deterministic
    (policy : DisputeRewardPolicy) (log₁ log₂ : List LogEntry)
    (d₁ d₂ : Dispute) (v₁ v₂ : Verdict)
    (h_l : log₁ = log₂) (h_d : d₁ = d₂) (h_v : v₁ = v₂) :
    disputeRewardActions policy log₁ d₁ v₁ =
    disputeRewardActions policy log₂ d₂ v₂ := by
  rw [h_l, h_d, h_v]

/-- Sanity: every emitted action is a `reward`.  Documents that
    the reward mechanism is strictly positive-incentive. -/
theorem disputeRewardActions_emits_only_rewards
    (policy : DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) :
    ∀ a ∈ disputeRewardActions policy log d v,
      ∃ r to amt, a = Action.reward r to amt := by
  intro a ha
  unfold disputeRewardActions at ha
  rw [List.mem_append] at ha
  cases ha with
  | inl h_ch =>
    cases hCh : policy.challengerReward log d v.outcome with
    | none      => rw [hCh] at h_ch; cases h_ch
    | some pair =>
      rw [hCh] at h_ch
      simp only [List.mem_singleton] at h_ch
      rcases pair with ⟨r, amt⟩
      exact ⟨r, d.challenger, amt, h_ch⟩
  | inr h_adj =>
    cases hAdj : policy.adjudicatorReward log v with
    | none      => rw [hAdj] at h_adj; cases h_adj
    | some pair =>
      rw [hAdj] at h_adj
      rcases pair with ⟨r, amt⟩
      simp only [List.mem_map] at h_adj
      obtain ⟨signer, _hMem, hEq⟩ := h_adj
      exact ⟨r, signer, amt, hEq.symm⟩

/-- Length bound: at most `1 + v.signers.length` reward actions
    are emitted (one challenger + one per signer). -/
theorem disputeRewardActions_length_bound
    (policy : DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) :
    (disputeRewardActions policy log d v).length ≤ 1 + v.signers.length := by
  unfold disputeRewardActions
  rw [List.length_append]
  have h_ch :
      (match policy.challengerReward log d v.outcome with
       | some (r, amt) => [Action.reward r d.challenger amt]
       | none          => ([] : List Action)).length ≤ 1 := by
    cases policy.challengerReward log d v.outcome with
    | none      => simp
    | some pair => rcases pair with ⟨_, _⟩; simp
  have h_adj :
      (match policy.adjudicatorReward log v with
       | some (r, amt) => v.signers.map (fun a => Action.reward r a amt)
       | none          => ([] : List Action)).length ≤ v.signers.length := by
    cases policy.adjudicatorReward log v with
    | none      => simp
    | some pair => rcases pair with ⟨_, _⟩; simp
  omega

/-! ## Constructor-specific theorems (WU 6.15e) -/

/-- `flatChallengerReward` returns `none` for non-`.upheld` outcomes. -/
theorem flatChallengerReward_rejected_no_reward
    (resource : ResourceId) (amount : Amount)
    (log : List LogEntry) (d : Dispute) :
    (DisputeRewardPolicy.flatChallengerReward resource amount).challengerReward
        log d .rejected = none := rfl

/-- `flatChallengerReward` returns `some` for `.upheld`. -/
theorem flatChallengerReward_upheld_emits
    (resource : ResourceId) (amount : Amount)
    (log : List LogEntry) (d : Dispute) :
    (DisputeRewardPolicy.flatChallengerReward resource amount).challengerReward
        log d .upheld = some (resource, amount) := rfl

/-- `flatAdjudicatorReward` returns `some` for every verdict. -/
theorem flatAdjudicatorReward_emits_for_every_verdict
    (resource : ResourceId) (amount : Amount)
    (log : List LogEntry) (v : Verdict) :
    (DisputeRewardPolicy.flatAdjudicatorReward resource amount).adjudicatorReward
        log v = some (resource, amount) := rfl

/-- The empty policy emits no actions. -/
theorem empty_no_actions
    (log : List LogEntry) (d : Dispute) (v : Verdict) :
    disputeRewardActions DisputeRewardPolicy.empty log d v = [] := by
  unfold disputeRewardActions DisputeRewardPolicy.empty
  rfl

/-- `union` left-bias: when `p₁` returns `some`, the union returns
    `p₁`'s value. -/
theorem union_challenger_left_bias_some
    (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (outcome : EvidenceVerdict)
    (r : ResourceId) (amt : Amount)
    (h : p₁.challengerReward log d outcome = some (r, amt)) :
    (p₁.union p₂).challengerReward log d outcome = some (r, amt) := by
  unfold DisputeRewardPolicy.union
  show (p₁.challengerReward log d outcome).orElse
        (fun _ => p₂.challengerReward log d outcome) = some (r, amt)
  rw [h]
  rfl

/-- `union` left-bias fallthrough: when `p₁` returns `none`, the
    union falls through to `p₂`'s value. -/
theorem union_challenger_left_bias_fallthrough
    (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (outcome : EvidenceVerdict)
    (h : p₁.challengerReward log d outcome = none) :
    (p₁.union p₂).challengerReward log d outcome =
    p₂.challengerReward log d outcome := by
  unfold DisputeRewardPolicy.union
  show (p₁.challengerReward log d outcome).orElse
        (fun _ => p₂.challengerReward log d outcome) =
       p₂.challengerReward log d outcome
  rw [h]
  rfl

/-- `union` left-bias for adjudicator branch: when `p₁`'s
    adjudicator field returns `some`, the union returns
    `p₁`'s value. -/
theorem union_adjudicator_left_bias_some
    (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry) (v : Verdict)
    (r : ResourceId) (amt : Amount)
    (h : p₁.adjudicatorReward log v = some (r, amt)) :
    (p₁.union p₂).adjudicatorReward log v = some (r, amt) := by
  unfold DisputeRewardPolicy.union
  show (p₁.adjudicatorReward log v).orElse
        (fun _ => p₂.adjudicatorReward log v) = some (r, amt)
  rw [h]
  rfl

/-- `union` left-bias fallthrough for adjudicator branch: when
    `p₁`'s adjudicator field returns `none`, the union falls
    through to `p₂`'s value. -/
theorem union_adjudicator_left_bias_fallthrough
    (p₁ p₂ : DisputeRewardPolicy) (log : List LogEntry) (v : Verdict)
    (h : p₁.adjudicatorReward log v = none) :
    (p₁.union p₂).adjudicatorReward log v =
    p₂.adjudicatorReward log v := by
  unfold DisputeRewardPolicy.union
  show (p₁.adjudicatorReward log v).orElse
        (fun _ => p₂.adjudicatorReward log v) =
       p₂.adjudicatorReward log v
  rw [h]
  rfl

/-! ## `applyVerdictWithRewardsUnchecked` wrapper (WU 6.16, renamed) -/

/-- **UNCHECKED — bypasses Stage 3.**  Compose
    `applyVerdictUnchecked` (Stage 4 bypass) with reward-action
    issuance.  Tests that intentionally exercise the bypass path
    (e.g. `unknownDispute` cases where the witness can't be built)
    use this form.  For default-safe combined Stage 3 + Stage 4
    + reward emission, use `proposeAndApplyVerdictWithRewards`. -/
def applyVerdictWithRewardsUnchecked
    (P : AuthorityPolicy) (rewardPolicy : DisputeRewardPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError (ExtendedState × List Action) :=
  match log[v.disputeId]? with
  | none => Except.error (.unknownDispute v.disputeId)
  | some entry =>
    match entry.signedAction.action with
    | .dispute d =>
      match applyVerdictUnchecked P currentEs genesis log v with
      | .ok rolledBack =>
        let rewards := disputeRewardActions rewardPolicy log d v
        Except.ok (rolledBack, rewards)
      | .error e => Except.error e
    | _ => Except.error (.unknownDispute v.disputeId)

/-! ## Multi-policy bundle (WU 6.16b + 6.23) -/

/-- Concatenate the per-policy reward emissions across a list of
    policies.  Used for cross-resource reward bundles (WU 6.23). -/
def disputeRewardActionsMulti
    (policies : List DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) : List Action :=
  policies.foldr (fun p acc => disputeRewardActions p log d v ++ acc) []

/-- **UNCHECKED — bypasses Stage 3.**  Multi-policy variant of
    `applyVerdictWithRewardsUnchecked`. -/
def applyVerdictWithRewardsMultiUnchecked
    (P : AuthorityPolicy) (rewardPolicies : List DisputeRewardPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError (ExtendedState × List Action) :=
  match log[v.disputeId]? with
  | none => Except.error (.unknownDispute v.disputeId)
  | some entry =>
    match entry.signedAction.action with
    | .dispute d =>
      match applyVerdictUnchecked P currentEs genesis log v with
      | .ok rolledBack =>
        let rewards := disputeRewardActionsMulti rewardPolicies log d v
        Except.ok (rolledBack, rewards)
      | .error e => Except.error e
    | _ => Except.error (.unknownDispute v.disputeId)

/-! ## Witness-bearing reward wrappers (C.6c–d)

The type-safe analogues of `applyVerdictWithRewardsUnchecked`
and `applyVerdictWithRewardsMultiUnchecked`.  Each carries a
`VerdictPassedStage3` witness.  Used by deployments that have
already validated the verdict (e.g. via a separate
`proposeVerdict` call) and want to skip re-validation. -/

/-- Witness-bearing version of `applyVerdictWithRewardsUnchecked`. -/
def applyVerdictWithRewards
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicy : DisputeRewardPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (_h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    Except VerdictError (ExtendedState × List Action) :=
  applyVerdictWithRewardsUnchecked P rewardPolicy currentEs genesis log v

/-- Witness-bearing version of `applyVerdictWithRewardsMultiUnchecked`. -/
def applyVerdictWithRewardsMulti
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicies : List DisputeRewardPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (_h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    Except VerdictError (ExtendedState × List Action) :=
  applyVerdictWithRewardsMultiUnchecked P rewardPolicies currentEs genesis log v

/-! ## Default-safe reward wrappers (C.6e–f) -/

/-- Default-safe combined Stage 3 + Stage 4 + reward-emission.
    Calls `proposeVerdict` first; on success constructs the
    witness and calls the witness-bearing reward wrapper.  Returns
    the rolled-back state + reward actions, or surfaces the
    proposing error. -/
def proposeAndApplyVerdictWithRewards
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicy : DisputeRewardPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError (ExtendedState × List Action) :=
  match h_propose : proposeVerdict P oracle qp currentEs genesis log v with
  | .ok v' =>
    have h_eq : v' = v :=
      proposeVerdict_ok_returns_input P oracle qp currentEs genesis log v v' h_propose
    have h_witness : VerdictPassedStage3 P oracle qp currentEs genesis log v :=
      VerdictPassedStage3.of_proposeVerdict_ok_with_eq h_propose h_eq
    applyVerdictWithRewards P oracle qp rewardPolicy currentEs genesis log v h_witness
  | .error e => .error e

/-- Default-safe combined Stage 3 + Stage 4 + multi-policy reward
    emission.  Companion to `proposeAndApplyVerdictWithRewards`
    that emits a list of reward action lists, one per policy in
    the input list. -/
def proposeAndApplyVerdictWithRewardsMulti
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicies : List DisputeRewardPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError (ExtendedState × List Action) :=
  match h_propose : proposeVerdict P oracle qp currentEs genesis log v with
  | .ok v' =>
    have h_eq : v' = v :=
      proposeVerdict_ok_returns_input P oracle qp currentEs genesis log v v' h_propose
    have h_witness : VerdictPassedStage3 P oracle qp currentEs genesis log v :=
      VerdictPassedStage3.of_proposeVerdict_ok_with_eq h_propose h_eq
    applyVerdictWithRewardsMulti P oracle qp rewardPolicies currentEs genesis log v h_witness
  | .error e => .error e

/-! ## Wrapper theorems (WU 6.16c, renamed) -/

/-- Determinism for `applyVerdictWithRewardsUnchecked`. -/
theorem applyVerdictWithRewardsUnchecked_deterministic
    (P : AuthorityPolicy) (rewardPolicy : DisputeRewardPolicy)
    (es₁ es₂ : ExtendedState) (g₁ g₂ : ExtendedState)
    (l₁ l₂ : List LogEntry) (v₁ v₂ : Verdict)
    (h_es : es₁ = es₂) (h_g : g₁ = g₂) (h_l : l₁ = l₂) (h_v : v₁ = v₂) :
    applyVerdictWithRewardsUnchecked P rewardPolicy es₁ g₁ l₁ v₁ =
    applyVerdictWithRewardsUnchecked P rewardPolicy es₂ g₂ l₂ v₂ := by
  rw [h_es, h_g, h_l, h_v]

/-- Unknown-dispute error path for `applyVerdictWithRewardsUnchecked`. -/
theorem applyVerdictWithRewardsUnchecked_unknown_dispute
    (P : AuthorityPolicy) (rewardPolicy : DisputeRewardPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : log[v.disputeId]? = none) :
    applyVerdictWithRewardsUnchecked P rewardPolicy currentEs genesis log v =
    .error (.unknownDispute v.disputeId) := by
  unfold applyVerdictWithRewardsUnchecked
  rw [h]

/-- Trivial-equivalence theorem for the witness-bearing reward
    wrapper.  Rules: the witness adds nothing at the value level. -/
theorem applyVerdictWithRewards_eq_unchecked
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicy : DisputeRewardPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdictWithRewards P oracle qp rewardPolicy currentEs genesis log v h =
    applyVerdictWithRewardsUnchecked P rewardPolicy currentEs genesis log v := rfl

/-- Trivial-equivalence theorem for the multi-policy witness-
    bearing reward wrapper. -/
theorem applyVerdictWithRewardsMulti_eq_unchecked
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicies : List DisputeRewardPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdictWithRewardsMulti P oracle qp rewardPolicies currentEs genesis log v h =
    applyVerdictWithRewardsMultiUnchecked P rewardPolicies currentEs genesis log v := rfl

/-- `proposeAndApplyVerdictWithRewards` reduces to
    `applyVerdictWithRewardsUnchecked` when proposing succeeds. -/
theorem proposeAndApplyVerdictWithRewards_eq_when_proposed_ok
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicy : DisputeRewardPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : proposeVerdict P oracle qp currentEs genesis log v = .ok v) :
    proposeAndApplyVerdictWithRewards P oracle qp rewardPolicy currentEs genesis log v =
    applyVerdictWithRewardsUnchecked P rewardPolicy currentEs genesis log v := by
  unfold proposeAndApplyVerdictWithRewards
  split
  · -- .ok v' branch
    rename_i v' h_propose
    rw [h] at h_propose
    cases h_propose
    rfl
  · -- .error e branch — but `h` says .ok, contradiction.
    rename_i e h_propose
    rw [h] at h_propose
    exact absurd h_propose (by simp)

/-- `proposeAndApplyVerdictWithRewards` surfaces the proposing
    error when Stage 3 fails. -/
theorem proposeAndApplyVerdictWithRewards_error_path
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (rewardPolicy : DisputeRewardPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (e : VerdictError)
    (h : proposeVerdict P oracle qp currentEs genesis log v = .error e) :
    proposeAndApplyVerdictWithRewards P oracle qp rewardPolicy currentEs genesis log v =
    .error e := by
  unfold proposeAndApplyVerdictWithRewards
  split
  · rename_i v' h_propose
    rw [h] at h_propose
    exact absurd h_propose (by simp)
  · rename_i e' h_propose
    rw [h] at h_propose
    have : e' = e := (Except.error.inj h_propose).symm
    rw [this]

/-! ## Multi-policy theorems (WU 6.23b) -/

/-- The multi-policy emission is exactly the concatenation of the
    atomic emissions. -/
theorem disputeRewardActionsMulti_concat
    (policies : List DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) :
    disputeRewardActionsMulti policies log d v =
    policies.foldr (fun p acc => disputeRewardActions p log d v ++ acc) [] := rfl

/-- Empty policy list emits no actions. -/
theorem disputeRewardActionsMulti_empty_no_actions
    (log : List LogEntry) (d : Dispute) (v : Verdict) :
    disputeRewardActionsMulti [] log d v = [] := rfl

/-- Multi-policy emission contains only rewards.  Inductive proof
    over the policy list. -/
theorem disputeRewardActionsMulti_emits_only_rewards
    (policies : List DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) :
    ∀ a ∈ disputeRewardActionsMulti policies log d v,
      ∃ r to amt, a = Action.reward r to amt := by
  intro a ha
  induction policies with
  | nil =>
    simp [disputeRewardActionsMulti] at ha
  | cons p rest ih =>
    unfold disputeRewardActionsMulti at ha
    simp only [List.foldr_cons] at ha
    rw [List.mem_append] at ha
    cases ha with
    | inl h₁ => exact disputeRewardActions_emits_only_rewards p log d v a h₁
    | inr h₂ => exact ih h₂

/-- Multi-policy length bound: each policy contributes at most
    `1 + v.signers.length` actions. -/
theorem disputeRewardActionsMulti_length_bound
    (policies : List DisputeRewardPolicy) (log : List LogEntry)
    (d : Dispute) (v : Verdict) :
    (disputeRewardActionsMulti policies log d v).length ≤
    policies.length * (1 + v.signers.length) := by
  induction policies with
  | nil =>
    simp [disputeRewardActionsMulti]
  | cons p rest ih =>
    -- Both sides reduce: disputeRewardActionsMulti (p::rest) =
    --   disputeRewardActions p ++ disputeRewardActionsMulti rest
    -- so length = length p_actions + length rest_actions.
    show (disputeRewardActions p log d v ++ disputeRewardActionsMulti rest log d v).length
       ≤ (rest.length + 1) * (1 + v.signers.length)
    rw [List.length_append]
    have h_p := disputeRewardActions_length_bound p log d v
    have h_rest := ih
    -- Combine the two bounds.
    have h_sum : (disputeRewardActions p log d v).length +
                 (disputeRewardActionsMulti rest log d v).length ≤
                 (1 + v.signers.length) +
                 rest.length * (1 + v.signers.length) :=
      Nat.add_le_add h_p h_rest
    -- (rest.length + 1) * (1 + signers.length) = signers.length + 1 +
    --   rest.length * (signers.length + 1) by Nat.succ_mul, which omega can verify.
    have hAlg : (rest.length + 1) * (1 + v.signers.length) =
                (1 + v.signers.length) +
                rest.length * (1 + v.signers.length) := by
      rw [Nat.succ_mul, Nat.add_comm]
    rw [hAlg]
    exact h_sum

/-! ## claimImpugnedAmount helper (WU 6.21a) -/

/-- Extract the impugned action's `amount` field, if it has one.
    Returns `none` for actions without a numeric amount field
    (`freezeResource`, `replaceKey`, dispute / verdict / rollback,
    `deposit`, `withdraw`, fault-proof actions).

    **Bridge-action skip (AR.13.3 / i-11 sub-issue).**  The
    `_ => none` wildcard intentionally skips `deposit` /
    `withdraw` — those are bridge-level operations whose
    impugnment goes through the L1 fault-proof path (Workstream H),
    not the L2 dispute pipeline.  Treating them here would
    double-count: the bridge actor's policy already audits
    deposits/withdrawals end-to-end, and the L1 fault-proof
    settlement is the L2 court of last resort for bridge
    disagreements.  A reward routed through this function for a
    bridge action would compete with the L1 settlement; the
    explicit skip keeps the two paths disjoint. -/
def claimImpugnedAmount
    (log : List LogEntry) (claim : DisputeClaim) : Option Amount :=
  match log[claimImpugnedIdx claim]? with
  | none => none
  | some entry =>
    match entry.signedAction.action with
    | .transfer _ _ _ amt        => some amt
    | .mint _ _ amt              => some amt
    | .burn _ _ amt              => some amt
    | .reward _ _ amt            => some amt
    | .distributeOthers _ _ amt  => some amt
    | .proportionalDilute _ _ tr => some tr
    | _                          => none

/-! ## Graduated-reward policy constructors (WU 6.21) -/

/-- Per-claim-variant graduated reward.  Different reward amounts
    for different claim types.  Returns `none` on non-`.upheld`
    outcome. -/
def DisputeRewardPolicy.byClaimVariant
    (resource : ResourceId)
    (preconditionFalseAmt signatureInvalidAmt nonceMismatchAmt
     oracleMisreportedAmt doubleApplyAmt : Amount) : DisputeRewardPolicy where
  challengerReward _ d outcome :=
    match outcome with
    | .upheld =>
      match d.claim with
      | .preconditionFalse _    => some (resource, preconditionFalseAmt)
      | .signatureInvalid _     => some (resource, signatureInvalidAmt)
      | .nonceMismatch _        => some (resource, nonceMismatchAmt)
      | .oracleMisreported _ _  => some (resource, oracleMisreportedAmt)
      | .doubleApply _ _        => some (resource, doubleApplyAmt)
    | _ => none
  adjudicatorReward _ _ := none

/-- Proportional-to-impugned-amount challenger reward.  The reward
    amount is `factor * amt / divisor` (Nat floor) where `amt` is
    the impugned action's amount field.

    **Divisor-zero behaviour.**  Lean's `Nat` division satisfies
    `n / 0 = 0`, so `factor * amt / 0 = 0`.  A policy with
    `divisor = 0` therefore emits `some (resource, 0)` on every
    upheld dispute against an action with a numeric amount field —
    a zero-amount reward.  Deployments that want
    "no reward" semantics should use
    `DisputeRewardPolicy.empty` instead, or compose via
    `union` with a graduated policy whose `divisor > 0`.  The
    zero-amount reward DOES still produce one entry in the
    `disputeRewardActions` list and emits a `rewardIssued` event
    via `actionEvents` (so indexers see the policy intent even
    when the amount degenerates to 0). -/
def DisputeRewardPolicy.proportionalChallengerReward
    (resource : ResourceId) (factor divisor : Amount) :
    DisputeRewardPolicy where
  challengerReward log d outcome :=
    match outcome with
    | .upheld =>
      match claimImpugnedAmount log d.claim with
      | some amt => some (resource, factor * amt / divisor)
      | none     => none
    | _ => none
  adjudicatorReward _ _ := none

/-- `byClaimVariant` returns `none` on non-`.upheld` outcomes. -/
theorem byClaimVariant_returns_none_on_rejected
    (resource : ResourceId)
    (preconditionFalseAmt signatureInvalidAmt nonceMismatchAmt
     oracleMisreportedAmt doubleApplyAmt : Amount)
    (log : List LogEntry) (d : Dispute) :
    (DisputeRewardPolicy.byClaimVariant resource preconditionFalseAmt
        signatureInvalidAmt nonceMismatchAmt oracleMisreportedAmt
        doubleApplyAmt).challengerReward log d .rejected = none := rfl

/-- `proportionalChallengerReward` returns `none` on non-`.upheld`. -/
theorem proportionalChallengerReward_returns_none_on_rejected
    (resource : ResourceId) (factor divisor : Amount)
    (log : List LogEntry) (d : Dispute) :
    (DisputeRewardPolicy.proportionalChallengerReward resource factor divisor).challengerReward
        log d .rejected = none := rfl

/-- `proportionalChallengerReward` returns the correct
    `factor * amt / divisor` on upheld disputes whose impugned
    action has a numeric amount field. -/
theorem proportionalChallengerReward_value_correct
    (resource : ResourceId) (factor divisor amt : Amount)
    (log : List LogEntry) (d : Dispute)
    (h : claimImpugnedAmount log d.claim = some amt) :
    (DisputeRewardPolicy.proportionalChallengerReward resource factor divisor).challengerReward
        log d .upheld = some (resource, factor * amt / divisor) := by
  show (match claimImpugnedAmount log d.claim with
        | some amt' => some (resource, factor * amt' / divisor)
        | none      => none) = some (resource, factor * amt / divisor)
  rw [h]

/-- `proportionalChallengerReward` returns `none` when the impugned
    action has no numeric amount field (e.g. `freezeResource`,
    `replaceKey`, dispute / verdict / rollback). -/
theorem proportionalChallengerReward_returns_none_on_amountless_impugned
    (resource : ResourceId) (factor divisor : Amount)
    (log : List LogEntry) (d : Dispute)
    (h : claimImpugnedAmount log d.claim = none) :
    (DisputeRewardPolicy.proportionalChallengerReward resource factor divisor).challengerReward
        log d .upheld = none := by
  show (match claimImpugnedAmount log d.claim with
        | some amt' => some (resource, factor * amt' / divisor)
        | none      => none) = none
  rw [h]

/-! ## Stake-weighted adjudicator rewards (WU 6.22) -/

/-- Sum of `signers`' balances at `resource`. -/
def totalSignerStake
    (es : ExtendedState) (resource : ResourceId) (signers : List ActorId) :
    Amount :=
  signers.foldl (fun acc s => acc + getBalance es.base resource s) 0

/-- Distribute an adjudicator-reward `pool` proportionally to each
    signer's balance at `stakeResource`.

    Each signer's reward is `pool * theirStake / totalStake` (Nat
    floor).  Signers with zero stake-weighted reward are filtered
    out (no `Action.reward _ _ 0` actions emitted).

    Edge cases: `pool = 0` or `totalStake = 0` → empty list.

    **Sum-le-pool invariant (AR.13.3 / i-11 sub-issue).**  The
    per-element bound `stakeWeightedAdjudicatorRewards_each_le_pool`
    is shipped (every emitted action's amount ≤ pool).  The
    *sum-le-pool* bound — `∑ a in stakeWeightedAdjudicatorRewards
    ... , a.amount ≤ pool` — is a *deployment-level invariant*
    (it follows from `Nat.div` floor + `∑ stake_i = totalStake`)
    but is NOT shipped as a stand-alone Lean theorem.  Promoting
    it would require a `disputeRewardActions_sum_le_pool`
    inductive lemma over the `filterMap` body; deferred to a
    future workstream (a "PA-tier" follow-up).  The cross-stack
    F-corpus exercises the bound on representative inputs. -/
def stakeWeightedAdjudicatorRewards
    (es : ExtendedState) (stakeResource rewardResource : ResourceId)
    (pool : Amount) (signers : List ActorId) : List Action :=
  let totalStake := totalSignerStake es stakeResource signers
  if totalStake = 0 then []
  else
    signers.filterMap (fun s =>
      let stake := getBalance es.base stakeResource s
      let reward := pool * stake / totalStake
      if reward = 0 then none
      else some (Action.reward rewardResource s reward))

/-- Edge case: zero pool produces no actions.  Every per-signer
    reward computes as `0 * stake / totalStake = 0`, which the
    `filterMap` filters out. -/
theorem stakeWeightedAdjudicatorRewards_zero_pool_no_actions
    (es : ExtendedState) (stakeResource rewardResource : ResourceId)
    (signers : List ActorId) :
    stakeWeightedAdjudicatorRewards es stakeResource rewardResource 0 signers = [] := by
  unfold stakeWeightedAdjudicatorRewards
  by_cases h : totalSignerStake es stakeResource signers = 0
  · rw [if_pos h]
  · rw [if_neg h]
    -- Every per-element `0 * stake / totalStake = 0`, so filterMap → [].
    apply List.filterMap_eq_nil_iff.mpr
    intro s _hMem
    simp [Nat.zero_mul]

/-- Edge case: zero total stake produces no actions. -/
theorem stakeWeightedAdjudicatorRewards_zero_total_stake_no_actions
    (es : ExtendedState) (stakeResource rewardResource : ResourceId)
    (pool : Amount) (signers : List ActorId)
    (h : totalSignerStake es stakeResource signers = 0) :
    stakeWeightedAdjudicatorRewards es stakeResource rewardResource pool signers = [] := by
  unfold stakeWeightedAdjudicatorRewards
  rw [if_pos h]

/-- All emissions are `Action.reward`. -/
theorem stakeWeightedAdjudicatorRewards_emits_only_rewards
    (es : ExtendedState) (stakeResource rewardResource : ResourceId)
    (pool : Amount) (signers : List ActorId) :
    ∀ a ∈ stakeWeightedAdjudicatorRewards es stakeResource rewardResource pool signers,
      ∃ r to amt, a = Action.reward r to amt := by
  intro a ha
  unfold stakeWeightedAdjudicatorRewards at ha
  by_cases h_zero : totalSignerStake es stakeResource signers = 0
  · rw [if_pos h_zero] at ha; cases ha
  · rw [if_neg h_zero] at ha
    rw [List.mem_filterMap] at ha
    obtain ⟨signer, _hMem, hOpt⟩ := ha
    by_cases h_rzero :
        pool * getBalance es.base stakeResource signer /
            totalSignerStake es stakeResource signers = 0
    · rw [if_pos h_rzero] at hOpt; cases hOpt
    · rw [if_neg h_rzero] at hOpt
      simp only [Option.some.injEq] at hOpt
      exact ⟨rewardResource, signer,
             pool * getBalance es.base stakeResource signer /
               totalSignerStake es stakeResource signers,
             hOpt.symm⟩

/-! ### Stake-le-total helper for the per-element bound -/

/-- Helper: a foldl-sum starts at the accumulator and only grows. -/
theorem foldl_balance_acc_le
    (es : ExtendedState) (resource : ResourceId)
    (xs : List ActorId) (start_ : Amount) :
    start_ ≤ xs.foldl (fun a s => a + getBalance es.base resource s) start_ := by
  induction xs generalizing start_ with
  | nil => simp
  | cons head tail ih =>
    simp only [List.foldl_cons]
    have h_le : start_ ≤ start_ + getBalance es.base resource head :=
      Nat.le_add_right _ _
    exact Nat.le_trans h_le (ih (start_ + getBalance es.base resource head))

/-- Each signer's stake is at most the total stake. -/
theorem getBalance_le_totalSignerStake
    (es : ExtendedState) (resource : ResourceId)
    (signer : ActorId) (signers : List ActorId)
    (h : signer ∈ signers) :
    getBalance es.base resource signer ≤ totalSignerStake es resource signers := by
  unfold totalSignerStake
  -- Strengthen via an explicit accumulator argument so induction works cleanly.
  suffices h_aux :
      ∀ (acc : Amount) (xs : List ActorId), signer ∈ xs →
      getBalance es.base resource signer ≤
        xs.foldl (fun a s => a + getBalance es.base resource s) acc by
    have h0 := h_aux 0 signers h
    exact h0
  intro acc xs h_mem
  induction xs generalizing acc with
  | nil => simp at h_mem
  | cons head tail ih =>
    -- h_mem : signer ∈ head :: tail.  Decompose via List.mem_cons.
    rw [List.mem_cons] at h_mem
    cases h_mem with
    | inl h_eq =>
      -- h_eq : signer = head.  Substitute head with signer.
      subst h_eq
      simp only [List.foldl_cons]
      have h_start : getBalance es.base resource signer ≤
                     acc + getBalance es.base resource signer :=
        Nat.le_add_left _ _
      have h_mono : acc + getBalance es.base resource signer ≤
                    tail.foldl (fun a s => a + getBalance es.base resource s)
                               (acc + getBalance es.base resource signer) :=
        foldl_balance_acc_le es resource tail _
      exact Nat.le_trans h_start h_mono
    | inr h_tail =>
      simp only [List.foldl_cons]
      exact ih (acc + getBalance es.base resource head) h_tail

/-- Per-element bound: every emitted reward action's amount is
    `≤ pool`.  Direct from `pool * stake / totalStake ≤ pool`
    when `stake ≤ totalStake` and `totalStake > 0`. -/
theorem stakeWeightedAdjudicatorRewards_each_le_pool
    (es : ExtendedState) (stakeResource rewardResource : ResourceId)
    (pool : Amount) (signers : List ActorId) :
    ∀ a ∈ stakeWeightedAdjudicatorRewards es stakeResource rewardResource pool signers,
      ∃ r to amt, a = Action.reward r to amt ∧ amt ≤ pool := by
  intro a ha
  unfold stakeWeightedAdjudicatorRewards at ha
  by_cases h_zero : totalSignerStake es stakeResource signers = 0
  · rw [if_pos h_zero] at ha; cases ha
  · rw [if_neg h_zero] at ha
    rw [List.mem_filterMap] at ha
    obtain ⟨signer, h_mem, hOpt⟩ := ha
    -- `hOpt` has the form: (let stake := ...; let reward := ...;
    --                       if reward = 0 then none else some _) = some a
    -- We case on whether the reward is zero.
    by_cases h_rzero :
        pool * getBalance es.base stakeResource signer /
            totalSignerStake es stakeResource signers = 0
    · -- reward = 0: the if-branch returns none, contradicting hOpt = some a.
      rw [if_pos h_rzero] at hOpt
      cases hOpt
    · -- reward ≠ 0: the else-branch returns some (Action.reward ...).
      rw [if_neg h_rzero] at hOpt
      simp only [Option.some.injEq] at hOpt
      let reward := pool * getBalance es.base stakeResource signer /
                      totalSignerStake es stakeResource signers
      refine ⟨rewardResource, signer, reward, hOpt.symm, ?_⟩
      -- Show reward ≤ pool.
      have h_stake_le :
          getBalance es.base stakeResource signer ≤
          totalSignerStake es stakeResource signers :=
        getBalance_le_totalSignerStake es stakeResource signer signers h_mem
      have h_mul_le : pool * getBalance es.base stakeResource signer ≤
                      pool * totalSignerStake es stakeResource signers :=
        Nat.mul_le_mul_left pool h_stake_le
      have h_div_le :
          pool * getBalance es.base stakeResource signer /
            totalSignerStake es stakeResource signers ≤
          pool * totalSignerStake es stakeResource signers /
            totalSignerStake es stakeResource signers :=
        Nat.div_le_div_right h_mul_le
      have h_cancel :
          pool * totalSignerStake es stakeResource signers /
            totalSignerStake es stakeResource signers = pool :=
        Nat.mul_div_cancel _ (Nat.pos_of_ne_zero h_zero)
      show reward ≤ pool
      exact Nat.le_trans h_div_le (Nat.le_of_eq h_cancel)

end Disputes
end LegalKernel

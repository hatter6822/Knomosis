-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Reward — single-recipient positive-incentive credit.

Phase-4-prelude WU R.5.  Defines the `reward` law (a single-actor
credit at a specified resource) as the positive-incentive analogue of
`mint`: structurally identical to `mint` at the kernel level, but
deliberately *named differently* so that the deployment-facing
authority layer (Phase 3 `AuthorityPolicy`, Phase 4 `Action`
serialisation) can grant "may reward" permission without granting
"may mint" permission, and vice versa.

`reward` is the simplest positive-incentive law: the deployment
explicitly identifies a recipient and credits them.  More elaborate
positive-incentive forms (`distributeOthers`, `proportionalDilute`)
also live under this directory; together they form the natural
substitute for the negative `burn` mechanism, with the type-level
firewall provided by `IsMonotonic` / `MonotonicLawSet` (in
`LegalKernel/Conservation.lean`).

Classified `IsMonotonic` (supply non-decreasing); explicitly *not*
`IsConservative` (supply increases by exactly `amount`).

This module is **not** part of the trusted computing base.  It is
imported by `LegalKernel.lean` for re-export and by
`LegalKernel.Test.Laws.Reward` for runtime spot-checking.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

/-- Reward `to` with `amount` units of resource `r`.

    * Precondition: `amount > 0`.  Reward of zero is a no-op and
      excluded by policy (mirroring the `mint` precondition shape).
    * Effect: increases `to`'s balance under `r` by `amount`, leaving
      every other balance untouched.

    Definitional shape is identical to `mint`; the semantic
    distinction lives in the `Action.reward` constructor (Phase-4
    prelude WU R.17) and downstream authorisation policies, not in
    the kernel-level `Transition`.

    `decPre` is inferred: the precondition is a single decidable
    arithmetic comparison over `Nat`. -/
def reward (r : ResourceId) (to : ActorId) (amount : Amount) : Transition where
  pre        := fun _ => amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r to (getBalance s r to + amount)

/-! ## LX-M2 (LX.24) Lex re-expression of `reward` -/

set_option linter.missingDocs false in
lexlaw legalkernel_reward where
  lex_id              legalkernel.reward
  lex_version         "1.0.0"
  lex_action_index    5
  lex_intent          "Reward `to` with `amount` units of resource `r`.  Definitionally identical to `mint` at the kernel level; the semantic distinction lives in the `Action.reward` constructor and downstream authorisation policies."
  lex_signed_by       to
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (to : ActorId) (amount : Amount)
  lex_pre             := fun _ => amount > 0
  lex_impl            :=
    fun s => setBalance s r to (getBalance s r to + amount)
  -- Per plan §19.4 LX.24: `reward` claims `monotonic` (succeeds
  -- via synth_monotonic, like `mint`), `local`,
  -- `freeze_preserving`, `nonce_advances`, `registry_preserving`.
  -- `conservative` is correctly omitted (reward is non-
  -- conservative by design — it adds tokens, just like `mint`,
  -- modulo the action-layer authorisation distinction).
  lex_satisfies       := [monotonic, «local», freeze_preserving,
                          nonce_advances, registry_preserving]
  lex_events          := []

/-- LX-M2 LX.24 byte-equivalence regression for `reward`. -/
example (r : ResourceId) (to : ActorId) (amount : Amount) :
    legalkernel_reward_transition r to amount = reward r to amount := rfl

/-- Sanity decidability witness for `reward`'s precondition. -/
example (r : ResourceId) (to : ActorId) (amount : Amount) (s : State) :
    Decidable ((reward r to amount).pre s) :=
  inferInstance

/-! ## Effect on `TotalSupply` (positive change) -/

/-- Master-lemma corollary specialised to `reward`: the post-reward
    supply at the rewarded resource exceeds the pre-reward supply by
    exactly `amount`.  Proof mirrors `totalSupply_after_mint`: a single
    `totalSupply_setBalance` instance discharges the additive identity
    once the new balance is `getBalance s r to + amount`. -/
theorem totalSupply_after_reward
    (r : ResourceId) (to : ActorId) (amount : Amount) (s : State)
    (hpre : (reward r to amount).pre s) :
    TotalSupply (step_impl s (reward r to amount)) r =
    TotalSupply s r + amount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((reward r to amount).apply_impl s) r =
       TotalSupply s r + amount
  simp only [reward]
  have h := totalSupply_setBalance s r to (getBalance s r to + amount)
  omega

/-! ## Cross-resource independence

`reward` only writes at the rewarded resource `r`, so any other
resource `r' ≠ r` is left untouched at every level: per-actor balance,
per-resource `BalanceMap`, and per-resource total supply.  The lemmas
below mirror `Laws/Mint.lean`'s cross-resource block. -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a (legal or rejected) reward at `r`.  Proof: case-split on the
    precondition; in the legal branch, the outer-level
    `s.balances.insert r …` lookup at `r' ≠ r` is invisible. -/
theorem reward_other_resource_untouched
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    (step_impl s (reward r to amount)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (reward r to amount).pre s
  · simp only [if_pos hpre]
    show ((reward r to amount).apply_impl s).balances[r']? = s.balances[r']?
    simp only [reward, setBalance]
    rw [RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`.  Direct
    consequence of `reward_other_resource_untouched` collapsed at the
    `getBalance` level. -/
theorem reward_does_not_touch_other_resources
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (reward r to amount)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [reward_other_resource_untouched r r' to amount s h]

/-- Conservation at any `r' ≠ r`: reward doesn't touch the
    per-resource map there, so `TotalSupply` reduces to the same fold
    on both sides. -/
theorem reward_conserves_other_resource
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (reward r to amount)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [reward_other_resource_untouched r r' to amount s h]

/-! ## Monotonicity classification (positive-incentive tier) -/

/-- `reward` is monotonic at every resource: the supply at the
    rewarded resource grows by `amount`, and supply at every other
    resource is untouched.  No `IsConservative` instance exists
    (witnessed by `reward_not_conservative` below), so this instance
    is what places `reward` in the positive-incentive tier. -/
instance reward_isMonotonic
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    IsMonotonic (reward r to amount) where
  monotone := by
    intro r' s hpre
    by_cases hr : r = r'
    · subst hr
      have h := totalSupply_after_reward r to amount s hpre
      omega
    · have h := reward_conserves_other_resource r r' to amount s hr
      omega

/-! ## Non-conservation (positive-incentive tier negative witness) -/

/-- `reward` is *not* an `IsConservative` law.  Witness: apply `reward
    r to amount` to the empty `genesisState`; the post-reward supply is
    `amount > 0`, but the pre-reward supply is `0`.  Conservation
    would force `0 = amount`, contradicting `amount > 0`.

    The proof mirrors `mint_not_conservative` line-for-line — both laws
    have the same `apply_impl` shape and the same monotonicity-vs-
    conservation gap.  This negative witness is what formally places
    `reward` strictly in the monotonicity tier and outside the
    conservation tier. -/
theorem reward_not_conservative
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (hpos : amount > 0) :
    ¬ IsConservative (reward r to amount) := by
  intro hcons
  have hpre : (reward r to amount).pre genesisState := hpos
  have hcons_r := hcons.conserves r genesisState hpre
  rw [totalSupply_after_reward r to amount genesisState hpre] at hcons_r
  rw [totalSupply_genesis_eq_zero r] at hcons_r
  simp at hcons_r
  exact absurd hcons_r (Nat.pos_iff_ne_zero.mp hpos)

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `reward r …` is `LocalTo [r]`. -/
instance reward_localTo
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    LocalTo [r] (reward r to amount) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact reward_does_not_touch_other_resources r r' to amount a s hne

/-- `reward r …` preserves freeze for any resource set `S` not
    containing `r`. -/
theorem reward_freezePreserving
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (reward r to amount) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [reward_other_resource_untouched r r' to amount s (Ne.symm hne)]
    exact h_init

/-- Vacuous-case `FreezePreserving []` instance for `reward`. -/
instance reward_freezePreserving_empty
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    FreezePreserving [] (reward r to amount) :=
  reward_freezePreserving r to amount [] (by simp)

end Laws
end LegalKernel

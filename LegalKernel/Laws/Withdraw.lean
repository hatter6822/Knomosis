-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Withdraw — Workstream C.3
(`docs/planning/ethereum_integration_plan.md` §7.3).

The bridge `withdraw` law: debit an L2 actor's balance and schedule
an L1 redemption for `recipientL1`.

Kernel-level definition: `setBalance` of `sender` at `r` with the
debited amount.  Kernel-level precondition: `getBalance r sender s ≥
amount` (sufficient balance).  The `Bridge.PendingWithdrawal` record
is inserted at the bridge-admissibility level
(`applyActionToBridgeState`, defined in `Bridge/Admissible.lean`).

Theorem coverage (§7.3):

  * `withdraw_other_resource_untouched`     — locality at `r' ≠ r`.
  * `withdraw_other_actor_untouched`        — locality at `sender' ≠ sender`.
  * `totalSupply_after_withdraw`            — supply decreases by exactly `amount`.
  * `withdraw_not_monotonic`                — explicit non-monotonicity
                                              witness (withdraw decreases
                                              supply by construction).
  * `withdraw_not_conservative`             — explicit non-conservation
                                              witness.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Bridge.State
import LegalKernel.Bridge.AddressBook
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

/-- Bridge withdrawal: burn `amount` units of resource `r` from
    `sender`'s balance and schedule an L1 redemption for
    `recipientL1`.

    * Kernel precondition: sender's balance is at least `amount`.
    * Effect: decreases `sender`'s balance under `r` by `amount`,
      leaving every other balance untouched.

    `decPre` is inferred (the precondition is a conjunction of two
    decidable `Nat ≥`/`Nat <` checks).

    **AR.21 / m-4 amendment.**  The precondition NOW includes
    `0 < amount` in addition to the sufficient-balance check.
    Pre-AR, zero-amount withdrawals were admissible at the kernel
    level and produced no observable state change
    (`getBalance s r sender - 0 = getBalance s r sender`); the
    bridge actor's policy was the operational gate against
    zero-amount L1 redemptions.  Post-AR, the kernel admissibility
    layer rejects zero-amount withdrawals outright, so a
    zero-amount `Action.withdraw` cannot enter the log even if the
    bridge actor's policy is misconfigured to allow it. -/
def withdraw (r : ResourceId) (sender : ActorId) (amount : Amount)
    (_recipientL1 : Bridge.EthAddress) : Transition where
  pre        := fun s => 0 < amount ∧ getBalance s r sender ≥ amount
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r sender (getBalance s r sender - amount)

/-! ## LX-M2 (LX.26) Lex re-expression of `withdraw` -/

set_option linter.missingDocs false in
lexlaw legalkernel_withdraw where
  lex_id              legalkernel.withdraw
  lex_version         "1.0.0"
  lex_action_index    14
  lex_intent          "Bridge L2 → L1 withdrawal (Workstream C / Genesis Plan §7.4): debit `amount` units of resource `r` from `sender`'s balance and schedule an L1 redemption to `_recipientL1`.  Kernel-level effect is `burn`-shaped balance decrement (gated by sufficient-balance precondition)."
  lex_signed_by       sender
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (sender : ActorId)
                      (amount : Amount) (_recipientL1 : Bridge.EthAddress)
  lex_pre             := fun s => 0 < amount ∧ getBalance s r sender ≥ amount
  lex_impl            :=
    fun s => setBalance s r sender (getBalance s r sender - amount)
  -- Per plan §19.4 LX.26: `withdraw` is `burn`-style: claims
  -- `local`, `freeze_preserving`, `nonce_advances`,
  -- `registry_preserving`.  NOT `conservative` AND NOT
  -- `monotonic` (subtractive — supply decreases by `amount`).
  lex_satisfies       := [«local», freeze_preserving,
                          nonce_advances, registry_preserving]
  lex_events          := []

/-- LX-M2 LX.26 byte-equivalence regression for `withdraw`. -/
example (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) :
    legalkernel_withdraw_transition r sender amount recipientL1 =
    withdraw r sender amount recipientL1 := rfl

/-- Decidability sanity check. -/
example (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (s : State) :
    Decidable ((withdraw r sender amount recipientL1).pre s) :=
  inferInstance

/-! ## Effect on `TotalSupply` (negative change) -/

/-- Pure-arithmetic kernel of `totalSupply_after_withdraw`.  Same
    omega workaround as in `Laws/Burn.lean`: lift the deeply nested
    `TotalSupply` and `getBalance` sub-terms to plain `Nat`
    parameters so that omega's atom discovery succeeds. -/
private theorem withdraw_arithmetic
    (T0 T1 B amount : Nat)
    (h    : T1 + B = T0 + (B - amount))
    (hbal : amount ≤ B) :
    T1 + amount = T0 := by
  omega

/-- Per-resource accounting: under the sufficient-balance precondition,
    the post-withdrawal supply at `r` plus `amount` equals the pre-
    withdrawal supply.  Stated in additive form to avoid `Nat`-
    subtraction asymmetry — mirrors `totalSupply_after_burn` exactly. -/
theorem totalSupply_after_withdraw
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (s : State)
    (hpre : (withdraw r sender amount recipientL1).pre s) :
    TotalSupply (step_impl s (withdraw r sender amount recipientL1)) r + amount =
    TotalSupply s r := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((withdraw r sender amount recipientL1).apply_impl s) r + amount =
       TotalSupply s r
  simp only [withdraw]
  -- AR.21: pre is `0 < amount ∧ amount ≤ getBalance s r sender`; we
  -- only need the sufficient-balance conjunct here.
  exact withdraw_arithmetic
    (TotalSupply s r)
    (TotalSupply (setBalance s r sender (getBalance s r sender - amount)) r)
    (getBalance s r sender)
    amount
    (totalSupply_setBalance s r sender (getBalance s r sender - amount))
    hpre.2

/-! ## Cross-resource independence -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a (legal or rejected) withdrawal at `r`. -/
theorem withdraw_other_resource_untouched
    (r r' : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (s : State) (h : r ≠ r') :
    (step_impl s (withdraw r sender amount recipientL1)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (withdraw r sender amount recipientL1).pre s
  · simp only [if_pos hpre]
    show ((withdraw r sender amount recipientL1).apply_impl s).balances[r']? =
         s.balances[r']?
    simp only [withdraw, setBalance]
    rw [RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`. -/
theorem withdraw_does_not_touch_other_resources
    (r r' : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (withdraw r sender amount recipientL1)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [withdraw_other_resource_untouched r r' sender amount recipientL1 s h]

/-- Conservation at any `r' ≠ r`. -/
theorem withdraw_conserves_other_resource
    (r r' : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (withdraw r sender amount recipientL1)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [withdraw_other_resource_untouched r r' sender amount recipientL1 s h]

/-! ## Cross-actor independence -/

/-- The other actor's balance at the same resource is unchanged by a
    withdrawal targeted at `sender`. -/
theorem withdraw_other_actor_untouched
    (r : ResourceId) (sender sender' : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (s : State)
    (hne : sender ≠ sender') :
    getBalance (step_impl s (withdraw r sender amount recipientL1)) r sender' =
    getBalance s r sender' := by
  rw [step_impl]
  by_cases hpre : (withdraw r sender amount recipientL1).pre s
  · simp only [if_pos hpre]
    show getBalance ((withdraw r sender amount recipientL1).apply_impl s) r sender' =
         getBalance s r sender'
    simp only [withdraw]
    exact getBalance_setBalance_other s r r sender sender'
      (getBalance s r sender - amount) (Or.inr hne)
  · simp only [if_neg hpre]

/-! ## Non-monotonicity / Non-conservation -/

/-- §7.3 / WU C.3: `withdraw` is *not* `IsMonotonic`.  Witness: a
    state where `sender` has at least `amount` balance — the post-
    withdrawal supply is strictly less than the pre-withdrawal
    supply.  Mirrors `burn_not_monotonic` in proof shape. -/
theorem withdraw_not_monotonic
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (hpos : amount > 0) :
    ¬ IsMonotonic (withdraw r sender amount recipientL1) := by
  intro hmono
  -- Construct a witness state: sender has exactly `amount` balance at `r`.
  let s : State := setBalance genesisState r sender amount
  have hread : getBalance s r sender = amount :=
    getBalance_setBalance_same genesisState r sender amount
  have hpre : (withdraw r sender amount recipientL1).pre s := by
    -- AR.21: pre is now `0 < amount ∧ getBalance s r sender ≥ amount`.
    show 0 < amount ∧ getBalance s r sender ≥ amount
    refine ⟨hpos, ?_⟩
    rw [hread]
    exact Nat.le_refl amount
  -- Pre-state supply is exactly `amount`.
  have hT0 : TotalSupply s r = amount := by
    show TotalSupply (setBalance genesisState r sender amount) r = amount
    have h := totalSupply_setBalance genesisState r sender amount
    rw [totalSupply_genesis_eq_zero r] at h
    have hgen : getBalance genesisState r sender = 0 := by
      show getBalance ({ balances := ∅ } : State) r sender = 0
      simp [getBalance]
    rw [hgen] at h
    omega
  have hmono_r := hmono.monotone r s hpre
  have hpost := totalSupply_after_withdraw r sender amount recipientL1 s hpre
  rw [hT0] at hpost hmono_r
  -- hpost  : TotalSupply (step_impl …) r + amount = amount  ⟹  post = 0.
  have h_post_zero :
      TotalSupply (step_impl s (withdraw r sender amount recipientL1)) r = 0 := by
    omega
  rw [h_post_zero] at hmono_r
  exact absurd hmono_r (Nat.not_le.mpr hpos)

/-- §7.3 / WU C.3: `withdraw` is *not* `IsConservative`.  Direct
    consequence of `withdraw_not_monotonic`: every conservative law
    is monotonic, so a non-monotonic law is non-conservative. -/
theorem withdraw_not_conservative
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) (hpos : amount > 0) :
    ¬ IsConservative (withdraw r sender amount recipientL1) := by
  intro hcons
  have hmono : IsMonotonic (withdraw r sender amount recipientL1) := by
    -- monotonic_of_conservative is low-priority; invoke explicitly.
    exact monotonic_of_conservative
  exact withdraw_not_monotonic r sender amount recipientL1 hpos hmono

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `withdraw r …` is `LocalTo [r]`. -/
instance withdraw_localTo
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) :
    LocalTo [r] (withdraw r sender amount recipientL1) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact withdraw_does_not_touch_other_resources r r' sender amount
            recipientL1 a s hne

/-- `withdraw r …` preserves freeze for any resource set `S` not
    containing `r`. -/
theorem withdraw_freezePreserving
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (withdraw r sender amount recipientL1) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [withdraw_other_resource_untouched r r' sender amount recipientL1 s
          (Ne.symm hne)]
    exact h_init

/-- Vacuous-case `FreezePreserving []` instance for `withdraw`. -/
instance withdraw_freezePreserving_empty
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) :
    FreezePreserving [] (withdraw r sender amount recipientL1) :=
  withdraw_freezePreserving r sender amount recipientL1 [] (by simp)

end Laws
end LegalKernel

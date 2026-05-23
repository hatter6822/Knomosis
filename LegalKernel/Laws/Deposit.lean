/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Deposit — Workstream C.2
(`docs/planning/ethereum_integration_plan.md` §7.2).

The bridge `deposit` law: credit an L1-attested deposit on L2.

Kernel-level definition: `setBalance` of `recipient` at `r` with the
incremented amount.  The kernel `Transition.pre` is trivial (`True`) —
*the deposit-id-uniqueness check lives at the bridge-admissibility
level*, alongside the registry-mutation-only check that already
governs `replaceKey` / `registerIdentity` (kernel-pre is `True`,
authority-level effect lives in `applyActionToRegistry` /
`applyActionToBridgeState`).

Theorem coverage (§7.2):

  * `deposit_other_resource_untouched`     — locality at `r' ≠ r`.
  * `deposit_other_actor_untouched`        — locality at `recipient' ≠ recipient`.
  * `totalSupply_after_deposit`            — supply increases by exactly `amount`.
  * `deposit_isMonotonic`                  — typeclass instance.
  * `deposit_not_conservative`             — explicit non-conservation
                                              witness (deposits expand
                                              supply by construction).

This module is **not** part of the trusted computing base.  It is
imported by `LegalKernel.lean` for re-export to deployments and by
`LegalKernel.Test.Laws.Deposit` for runtime spot-checking.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Bridge.State
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

/-- Bridge deposit: credit `amount` units of resource `r` to actor
    `recipient`, marking `depositId` as consumed (the bridge-level
    effect happens in `applyActionToBridgeState`).

    * Kernel precondition: `True`.  The bridge-level deposit-id
      uniqueness check lives in `BridgeAdmissibleWith` (§7.0); the
      kernel-level `pre` is trivial because `Transition.pre`
      operates on `State`, not `BridgeState`.
    * Effect: increases `recipient`'s balance under `r` by `amount`,
      leaving every other balance untouched.

    `decPre` is inferred (the precondition is `True`).

    **AR.13.5 / m-5 note.**  The precondition is unconditionally
    `True` *by design*: the deposit-id uniqueness gate is enforced
    entirely by `applyActionToBridgeState`'s `consumed`-membership
    check (`BridgeAdmissibleWith` conjunct 6 in §7.0).  The Lean
    `Transition.pre` operates on the kernel `State` only and has
    no view into the bridge sub-state, so the kernel pre is
    permissive; the *combined* admissibility predicate (kernel pre
    AND bridge admissibility) is the operational gate.  See
    `docs/planning/ethereum_integration_plan.md` §C.3 for the bridge-level
    layering. -/
def deposit (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (_depositId : Bridge.DepositId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r recipient (getBalance s r recipient + amount)

/-- Decidability sanity check: `deposit`'s precondition is decidable
    on every state. -/
example (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) (s : State) :
    Decidable ((deposit r recipient amount depositId).pre s) :=
  inferInstance

/-! ## LX-M2 (LX.26) Lex re-expression of `deposit` -/

set_option linter.missingDocs false in
lexlaw legalkernel_deposit where
  lex_id              legalkernel.deposit
  lex_version         "1.0.0"
  lex_action_index    13
  lex_intent          "Bridge L1 → L2 deposit (Workstream C / Genesis Plan §7.4): credit `amount` units of resource `r` to `recipient` on L2, marking `_depositId` as consumed (the bridge-level effect happens in `applyActionToBridgeState`).  Kernel-level effect is `mint`-shaped balance increment."
  lex_signed_by       bridge
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (recipient : ActorId)
                      (amount : Amount) (_depositId : Bridge.DepositId)
  lex_pre             := fun _ => True
  lex_impl            :=
    fun s => setBalance s r recipient (getBalance s r recipient + amount)
  -- Per plan §19.4 LX.26: `deposit` is `mint`-style: claims
  -- `monotonic`, `local`, `freeze_preserving`, `nonce_advances`,
  -- `registry_preserving`.  NOT `conservative` (additive supply
  -- increase by `amount`).
  lex_satisfies       := [monotonic, «local», freeze_preserving,
                          nonce_advances, registry_preserving]
  lex_events          := []

/-- LX-M2 LX.26 byte-equivalence regression for `deposit`. -/
example (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) :
    legalkernel_deposit_transition r recipient amount depositId =
    deposit r recipient amount depositId := rfl

/-! ## Effect on `TotalSupply` (positive change) -/

/-- Per-resource accounting: total supply at `r` increases by exactly
    `amount` after a deposit at `r`.  Direct consequence of the §8.1
    master-lemma `totalSupply_setBalance` after rewriting `step_impl`
    via the `True` precondition.  Mirrors `totalSupply_after_mint`
    in proof shape. -/
theorem totalSupply_after_deposit
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) (s : State) :
    TotalSupply (step_impl s (deposit r recipient amount depositId)) r =
    TotalSupply s r + amount := by
  rw [step_impl]
  have hpre : (deposit r recipient amount depositId).pre s := trivial
  simp only [if_pos hpre]
  show TotalSupply ((deposit r recipient amount depositId).apply_impl s) r =
       TotalSupply s r + amount
  simp only [deposit]
  have h := totalSupply_setBalance s r recipient
              (getBalance s r recipient + amount)
  omega

/-! ## Cross-resource independence -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a deposit at `r`. -/
theorem deposit_other_resource_untouched
    (r r' : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) (s : State) (h : r ≠ r') :
    (step_impl s (deposit r recipient amount depositId)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  have hpre : (deposit r recipient amount depositId).pre s := trivial
  simp only [if_pos hpre]
  show ((deposit r recipient amount depositId).apply_impl s).balances[r']? =
       s.balances[r']?
  simp only [deposit, setBalance]
  rw [RBMap.find?_insert_other _ r r' _ h]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`. -/
theorem deposit_does_not_touch_other_resources
    (r r' : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (deposit r recipient amount depositId)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [deposit_other_resource_untouched r r' recipient amount depositId s h]

/-- Conservation at any `r' ≠ r`. -/
theorem deposit_conserves_other_resource
    (r r' : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (deposit r recipient amount depositId)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [deposit_other_resource_untouched r r' recipient amount depositId s h]

/-! ## Cross-actor independence (locality at the same resource) -/

/-- The recipient's balance at `r' ≠ r` is unchanged by a deposit
    targeted at `r`.  Pointwise version of
    `deposit_does_not_touch_other_resources`. -/
theorem deposit_other_actor_untouched
    (r : ResourceId) (recipient recipient' : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) (s : State)
    (hne : recipient ≠ recipient') :
    getBalance (step_impl s (deposit r recipient amount depositId)) r recipient' =
    getBalance s r recipient' := by
  rw [step_impl]
  have hpre : (deposit r recipient amount depositId).pre s := trivial
  simp only [if_pos hpre]
  show getBalance ((deposit r recipient amount depositId).apply_impl s) r recipient' =
       getBalance s r recipient'
  simp only [deposit]
  exact getBalance_setBalance_other s r r recipient recipient'
    (getBalance s r recipient + amount) (Or.inr hne)

/-! ## Non-conservation -/

/-- §7.2 / WU C.2: `deposit` is *not* an `IsConservative` law.  Witness:
    apply `deposit r recipient amount depositId` to the empty
    `genesisState`; the post-deposit supply is `amount > 0`, but the
    pre-deposit supply is `0`. -/
theorem deposit_not_conservative
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId)
    (hpos : amount > 0) :
    ¬ IsConservative (deposit r recipient amount depositId) := by
  intro hcons
  have hpre : (deposit r recipient amount depositId).pre genesisState := trivial
  have hcons_r := hcons.conserves r genesisState hpre
  rw [totalSupply_after_deposit r recipient amount depositId genesisState] at hcons_r
  rw [totalSupply_genesis_eq_zero r] at hcons_r
  simp at hcons_r
  exact absurd hcons_r (Nat.pos_iff_ne_zero.mp hpos)

/-! ## Monotonicity classification -/

/-- `deposit` is monotonic at every resource: supply at the deposit's
    resource grows by `amount`, supply at every other resource is
    untouched. -/
instance deposit_isMonotonic
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) :
    IsMonotonic (deposit r recipient amount depositId) where
  monotone := by
    intro r' s _hpre
    by_cases hr : r = r'
    · subst hr
      have h := totalSupply_after_deposit r recipient amount depositId s
      omega
    · have h := deposit_conserves_other_resource r r' recipient amount depositId s hr
      omega

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `deposit r …` is `LocalTo [r]`. -/
instance deposit_localTo
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : LegalKernel.Bridge.DepositId) :
    LocalTo [r] (deposit r recipient amount depositId) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact deposit_does_not_touch_other_resources r r' recipient amount
            depositId a s hne

/-- `deposit r …` preserves freeze for any resource set `S` not
    containing `r`. -/
theorem deposit_freezePreserving
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : LegalKernel.Bridge.DepositId)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (deposit r recipient amount depositId) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [deposit_other_resource_untouched r r' recipient amount depositId s
          (Ne.symm hne)]
    exact h_init

/-- Vacuous-case `FreezePreserving []` instance for `deposit`. -/
instance deposit_freezePreserving_empty
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : LegalKernel.Bridge.DepositId) :
    FreezePreserving [] (deposit r recipient amount depositId) :=
  deposit_freezePreserving r recipient amount depositId [] (by simp)

end Laws
end LegalKernel

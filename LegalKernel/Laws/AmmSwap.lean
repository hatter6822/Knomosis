-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.Kernel
import LegalKernel.Conservation

/-!
LegalKernel.Laws.AmmSwap — Workstream GP.11.4 (L2-side AMM mirroring).

Mirror an L1 constant-product AMM swap onto L2 by adjusting the
AMM-reserve actor's balances.  When the L1 `KnomosisBridge.ammSwap`
executes, the L1 event watcher (`knomosis-l1-ingest`) emits a
bridge-signed `Action.ammSwap` that lands here.

Kernel-state effect.  Two sequential balance mutations at the
`ammReserveActor` slot:

  * `ammReserveActor`'s `fromResource` balance += `amountIn`
    (the pool RECEIVES the user's input token)
  * `ammReserveActor`'s `toResource` balance −= `amountOut`
    (the pool SENDS the user's output token)

The two resources MUST be distinct (`fromResource ≠ toResource`) to
avoid a collision between the two `setBalance` operations.

Conservation.  This law is NOT globally conserved:
  * Supply at `fromResource` INCREASES by `amountIn`
  * Supply at `toResource` DECREASES by `amountOut`

Any theorem set claiming `ConservativeLawSet` membership must exclude
`ammSwap`.  The kernel does NOT prove the constant-product invariant
(`k = R_in × R_out` non-decreasing); that property is enforced
operationally by the L1 contract (GP.11.3) and verified cross-stack
by the fixture corpus (GP.11.7).

Preconditions:
  * `getBalance s toResource ammReserveActor ≥ amountOut` — ensures
    truncation-safe `Nat` subtraction (no underflow / silent under-credit)
  * `fromResource ≠ toResource` — prevents same-slot collision between
    the two `setBalance` writes (soundness of the two-step state mutation)
  * `amountIn > 0` — prevents degenerate zero-input swaps (no-op tokens)

This module is **not** part of the trusted computing base: bugs here
are scoped to the AMM deployment-facing law, never a kernel invariant.
-/

namespace LegalKernel
namespace Laws

/-- GP.11.4 AMM swap — kernel leg.

    `ammReserveActor` receives `amountIn` of `fromResource` and sends
    `amountOut` of `toResource`.  Signed by `bridgeActor` in response
    to the L1 `AmmSwapExecuted` event.

    * Preconditions:
      - the reserve actor holds at least `amountOut` of `toResource`
      - `fromResource ≠ toResource`
      - `amountIn > 0`
    * Effect: credit `ammReserveActor` at `fromResource`, then debit at
      `toResource`, reading from the post-credit intermediate state (the
      two resources are distinct, so the reads are independent).

    `decPre` is inferred: the precondition is built from decidable `Nat`
    comparisons and `UInt64` equality. -/
def ammSwap (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) : Transition where
  pre := fun s =>
    getBalance s toResource ammReserveActor ≥ amountOut ∧
    fromResource ≠ toResource ∧
    amountIn > 0
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s fromResource ammReserveActor
                (getBalance s fromResource ammReserveActor + amountIn)
    setBalance s1 toResource ammReserveActor
      (getBalance s1 toResource ammReserveActor - amountOut)

/-! ## Cross-resource independence (§4.11.2 analogue)

The AMM swap touches EXACTLY two resources (`fromResource` and
`toResource`); any third resource is structurally untouched. -/

/-- State-level: the per-resource `BalanceMap` at any resource
    `r' ∉ {fromResource, toResource}` is unchanged by `ammSwap`. -/
theorem ammSwap_other_resource_untouched
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    {r' : ResourceId}
    (h1 : fromResource ≠ r') (h2 : toResource ≠ r') :
    (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)).balances[r']? = s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s
  · simp only [if_pos hpre]
    show ((setBalance
      (setBalance s fromResource ammReserveActor _)
      toResource ammReserveActor _).balances)[r']? = s.balances[r']?
    unfold setBalance
    rw [RBMap.find?_insert_other _ toResource r' _ h2,
        RBMap.find?_insert_other _ fromResource r' _ h1]
  · simp only [if_neg hpre]

/-- Per-actor: any actor's balance at a resource outside
    `{fromResource, toResource}` is unchanged. -/
theorem ammSwap_does_not_touch_other_resources
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (r' : ResourceId) (a : ActorId) (s : State)
    (h1 : fromResource ≠ r') (h2 : toResource ≠ r') :
    getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [ammSwap_other_resource_untouched fromResource toResource amountIn amountOut
        ammReserveActor s h1 h2]

/-- Total supply at a resource outside `{fromResource, toResource}` is
    unchanged by the swap. -/
theorem ammSwap_conserves_other_resource
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (r' : ResourceId) (s : State)
    (h1 : fromResource ≠ r') (h2 : toResource ≠ r') :
    TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [ammSwap_other_resource_untouched fromResource toResource amountIn amountOut
        ammReserveActor s h1 h2]

/-! ## Per-actor balance deltas (GP.11.4 kernel-leg theorems)

These pin the "reserve actor gains at fromResource, loses at
toResource, everyone else untouched" property. -/

/-- After a successful swap, the reserve actor's `fromResource` balance
    increases by exactly `amountIn`. -/
theorem ammSwap_increases_from_balance
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s) :
    getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) fromResource ammReserveActor =
    getBalance s fromResource ammReserveActor + amountIn := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((ammSwap fromResource toResource amountIn amountOut
          ammReserveActor).apply_impl s) fromResource ammReserveActor = _
  simp only [ammSwap]
  have hne : fromResource ≠ toResource := hpre.2.1
  rw [getBalance_setBalance_other _ toResource fromResource ammReserveActor ammReserveActor _
        (Or.inl (Ne.symm hne))]
  rw [getBalance_setBalance_same]

/-- After a successful swap, the reserve actor's `toResource` balance
    decreases by exactly `amountOut`. -/
theorem ammSwap_decreases_to_balance
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s) :
    getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) toResource ammReserveActor =
    getBalance s toResource ammReserveActor - amountOut := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((ammSwap fromResource toResource amountIn amountOut
          ammReserveActor).apply_impl s) toResource ammReserveActor = _
  simp only [ammSwap]
  rw [getBalance_setBalance_same]
  have hne : fromResource ≠ toResource := hpre.2.1
  rw [getBalance_setBalance_other _ fromResource toResource ammReserveActor ammReserveActor _
        (Or.inl hne)]

/-- A successful swap leaves untouched any actor OTHER than the AMM
    reserve actor, at both the `fromResource` and `toResource`. -/
theorem ammSwap_other_actor_untouched
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (other : ActorId) (r : ResourceId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s)
    (hne : other ≠ ammReserveActor) :
    getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) r other =
    getBalance s r other := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((ammSwap fromResource toResource amountIn amountOut
          ammReserveActor).apply_impl s) r other = _
  simp only [ammSwap]
  by_cases hr_to : toResource = r
  · subst hr_to
    rw [getBalance_setBalance_other _ toResource toResource ammReserveActor other _
          (Or.inr (Ne.symm hne))]
    by_cases hr_from : fromResource = toResource
    · exact absurd hr_from hpre.2.1
    · rw [getBalance_setBalance_other _ fromResource toResource ammReserveActor other _
            (Or.inl hr_from)]
  · rw [getBalance_setBalance_other _ toResource r ammReserveActor other _
          (Or.inl hr_to)]
    by_cases hr_from : fromResource = r
    · subst hr_from
      rw [getBalance_setBalance_other _ fromResource fromResource ammReserveActor other _
            (Or.inr (Ne.symm hne))]
    · rw [getBalance_setBalance_other _ fromResource r ammReserveActor other _
            (Or.inl hr_from)]

/-! ## Supply-change characterisation (non-conservation)

`ammSwap` is NOT globally conservative.  We prove per-resource supply
CHANGE theorems (not equalities) characterising the exact delta. -/

/-- Pure-arithmetic helper for `ammSwap_fromResource_supply_increase`.
    `setBalance` at the same resource: the master lemma
    `totalSupply_setBalance` gives
    `TS(s') + old = TS(s) + new`, rearranging to `TS(s') = TS(s) + (new - old)`. -/
private theorem swap_from_arithmetic
    (T0 T1 balance amountIn : Nat)
    (h1 : T1 + balance = T0 + (balance + amountIn)) :
    T1 = T0 + amountIn := by
  omega

/-- Total supply at `fromResource` INCREASES by exactly `amountIn`
    after a successful swap (provided the write at `fromResource`
    does not collide with the write at `toResource`, guaranteed by
    the `fromResource ≠ toResource` precondition). -/
theorem ammSwap_fromResource_supply_increase
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s) :
    TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) fromResource =
    TotalSupply s fromResource + amountIn := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((ammSwap fromResource toResource amountIn amountOut
          ammReserveActor).apply_impl s) fromResource = _
  simp only [ammSwap]
  have hne : fromResource ≠ toResource := hpre.2.1
  unfold TotalSupply
  rw [show (setBalance (setBalance s fromResource ammReserveActor _) toResource
            ammReserveActor _).balances[fromResource]? =
          (setBalance s fromResource ammReserveActor _).balances[fromResource]? from by
    unfold setBalance
    rw [RBMap.find?_insert_other _ toResource fromResource _ (Ne.symm hne)]]
  exact swap_from_arithmetic
    (TotalSupply s fromResource)
    (TotalSupply (setBalance s fromResource ammReserveActor
        (getBalance s fromResource ammReserveActor + amountIn)) fromResource)
    (getBalance s fromResource ammReserveActor)
    amountIn
    (totalSupply_setBalance s fromResource ammReserveActor
        (getBalance s fromResource ammReserveActor + amountIn))

/-- Pure-arithmetic helper for `ammSwap_toResource_supply_decrease`. -/
private theorem swap_to_arithmetic
    (T0 T1 balance amountOut : Nat)
    (h1 : T1 + balance = T0 + (balance - amountOut))
    (hbal : amountOut ≤ balance) :
    T1 + amountOut = T0 := by
  omega

/-- Total supply at `toResource` DECREASES by exactly `amountOut`
    after a successful swap (stated as `TS(post) + amountOut = TS(pre)`
    to stay in `Nat`). -/
theorem ammSwap_toResource_supply_decrease
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s) :
    TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) toResource + amountOut =
    TotalSupply s toResource := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((ammSwap fromResource toResource amountIn amountOut
          ammReserveActor).apply_impl s) toResource + amountOut = _
  simp only [ammSwap]
  have hne : fromResource ≠ toResource := hpre.2.1
  -- The intermediate state `setBalance s fromResource …` has the same
  -- TotalSupply at `toResource` as `s` (cross-resource independence).
  have hTS_mid : TotalSupply (setBalance s fromResource ammReserveActor
      (getBalance s fromResource ammReserveActor + amountIn)) toResource =
      TotalSupply s toResource := by
    unfold TotalSupply setBalance
    rw [RBMap.find?_insert_other _ fromResource toResource _ hne]
  -- The balance reads through the first write unperturbed.
  have hbal_mid : getBalance (setBalance s fromResource ammReserveActor
      (getBalance s fromResource ammReserveActor + amountIn)) toResource ammReserveActor =
      getBalance s toResource ammReserveActor :=
    getBalance_setBalance_other _ fromResource toResource ammReserveActor
      ammReserveActor _ (Or.inl hne)
  -- Apply the master accounting lemma at the second write.
  rw [hbal_mid]
  have hmast := totalSupply_setBalance
    (setBalance s fromResource ammReserveActor
      (getBalance s fromResource ammReserveActor + amountIn))
    toResource ammReserveActor
    (getBalance s toResource ammReserveActor - amountOut)
  rw [hTS_mid, hbal_mid] at hmast
  have hbal : amountOut ≤ getBalance s toResource ammReserveActor := hpre.1
  exact swap_to_arithmetic
    (TotalSupply s toResource)
    _
    (getBalance s toResource ammReserveActor)
    amountOut
    hmast
    hbal

/-! ## Classification instances (§5.3 / LX.3)

`ammSwap` is LocalTo [fromResource, toResource] and FreezePreserving
for any resource set disjoint from the affected pair.  It is explicitly
NOT conservative and NOT monotonic at the individual resources. -/

/-- `ammSwap fromResource toResource … ammReserveActor` is
    `LocalTo [fromResource, toResource]`: no actor's balance changes at
    any resource outside the swap pair. -/
instance ammSwap_localTo
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) :
    LocalTo [fromResource, toResource]
      (ammSwap fromResource toResource amountIn amountOut ammReserveActor) where
  local_to := by
    intro r' a s hr_not_in _
    have h1 : fromResource ≠ r' := by
      intro heq; apply hr_not_in; subst heq; simp
    have h2 : toResource ≠ r' := by
      intro heq; apply hr_not_in; subst heq; simp
    exact ammSwap_does_not_touch_other_resources fromResource toResource amountIn amountOut
      ammReserveActor r' a s h1 h2

/-- `ammSwap` preserves freeze for any resource set `S` disjoint from
    `{fromResource, toResource}`.  A theorem (not an instance) because
    `S` is not inferable from the goal. -/
theorem ammSwap_freezePreserving
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId)
    (S : List ResourceId) (h1 : fromResource ∉ S) (h2 : toResource ∉ S) :
    FreezePreserving S (ammSwap fromResource toResource amountIn amountOut ammReserveActor) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne1 : fromResource ≠ r' := fun heq => h1 (heq ▸ hr')
    have hne2 : toResource ≠ r' := fun heq => h2 (heq ▸ hr')
    rw [ammSwap_other_resource_untouched fromResource toResource amountIn amountOut
          ammReserveActor s hne1 hne2]
    exact h_init

/-- Empty-resource-set freeze preservation (vacuous case). -/
instance ammSwap_freezePreserving_empty
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) :
    FreezePreserving [] (ammSwap fromResource toResource amountIn amountOut ammReserveActor) :=
  ammSwap_freezePreserving fromResource toResource amountIn amountOut ammReserveActor []
    (by simp) (by simp)

/-- Explicit non-conservation witness: total supply at `fromResource`
    changes (increases by `amountIn`) when `amountIn > 0`, so no
    `IsConservative` instance exists for `ammSwap` in the non-degenerate
    case. -/
theorem ammSwap_not_conservative_at_from
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s)
    (hpos : amountIn > 0) :
    TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) fromResource ≠
    TotalSupply s fromResource := by
  rw [ammSwap_fromResource_supply_increase fromResource toResource amountIn amountOut
        ammReserveActor s hpre]
  exact Nat.ne_of_gt (Nat.lt_add_of_pos_right hpos)

/-- Explicit non-monotonicity witness: total supply at `toResource`
    DECREASES (by `amountOut`) when `amountOut > 0`, violating the
    `TotalSupply s ≤ TotalSupply s'` monotonicity condition. -/
theorem ammSwap_not_monotonic_at_to
    (fromResource toResource : ResourceId)
    (amountIn amountOut : Amount)
    (ammReserveActor : ActorId) (s : State)
    (hpre : (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s)
    (hpos : amountOut > 0) :
    TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) toResource <
    TotalSupply s toResource := by
  have heq := ammSwap_toResource_supply_decrease fromResource toResource amountIn amountOut
                ammReserveActor s hpre
  have hlt : TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) toResource <
      TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
      ammReserveActor)) toResource + amountOut := Nat.lt_add_of_pos_right hpos
  rw [heq] at hlt
  exact hlt

end Laws
end LegalKernel

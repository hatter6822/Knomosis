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
import Lex.DSL.Law

/-!
LegalKernel.Laws.ReclaimAmmReserves — Workstream GP.11.10 (post-disable
AMM reserve reclamation).

Once the L1 `emergencyDisableAmm()` kill switch fires (one-way; mirrored
on L2 as `BridgeState.ammDisabled`), the embedded AMM's reserves are
frozen capital: `ammSwap` reverts forever on L1, and the GP.11.6
`ammReservePolicy` bars the reserve actor's L2 balances from moving
through any other action.  This law is the sanctioned recovery path —
a bridge-attested EXACT SWEEP of the reserve actor's balance at one
resource into the gas-pool actor, re-tagging the frozen liquidity as
ordinary sequencer-claimable free-pool funds.

Kernel-state effect.  Two balance mutations at a single resource `r`:

  * `reserveActor`'s `r` balance −= `amount` (drained to exactly 0
    under the exact-sweep precondition)
  * `poolActor`'s `r` balance += `amount`

The two actors MUST be distinct (`reserveActor ≠ poolActor`) so the
two `setBalance` writes cannot collide.

Exact-sweep discipline.  The precondition pins
`getBalance s r reserveActor = amount` — the action must reclaim the
ENTIRE reserve balance, not a fragment.  Three consequences:

  * the post-state reserve balance is exactly `0`
    (`reclaimAmmReserves_zeroes_reserve`), so no dust lingers and a
    replayed sweep fails its own precondition (`amount > 0` against a
    zero balance);
  * the swept `amount` is an action field, so the emitted
    `Event.ammReservesReclaimed`, the CBE wire format, and the L1
    step-VM commit are all deterministic functions of the action;
  * partial-drain games are impossible by construction — there is no
    admissible action shape that moves *some* of the reserve.

Conservation.  Unlike `ammSwap` (a cross-resource trade), the sweep is
a SINGLE-RESOURCE transfer between two actors, so it is genuinely
conservative: `TotalSupply` is unchanged at every resource
(`reclaimAmmReserves_isConservative`), and monotonicity follows via
`monotonic_of_conservative`.  A deployment's `ConservativeLawSet` may
therefore include this law.

Admission gating (NOT in this file).  The kernel law is deliberately
actor-parametric (the `Laws` layer sits below `Bridge` in the module
graph); the deployment-critical pins live at the admission layer:
`BridgeAdmissibleWith` conjunct (9) requires the threaded actors to be
the canonical `ammReserveActor` / `gasPoolActor`, the L2 kill-switch
mirror `es.bridge.ammDisabled = true`, and (via `Action.isBridgeOnly`)
the signer to be `bridgeActor`.  See `Bridge/Admissible.lean`.

This module is **not** part of the trusted computing base: bugs here
are scoped to the disaster-recovery deployment-facing law, never a
kernel invariant.
-/

namespace LegalKernel
namespace Laws

/-- GP.11.10 post-disable reserve reclamation — kernel leg.

    `reserveActor` is drained of exactly `amount` (its entire balance,
    by the exact-sweep precondition) at resource `r`; `poolActor` is
    credited the same `amount`.  Signed by `bridgeActor` after the L1
    `AmmDisabled` event, gated at admission on the L2 kill-switch
    mirror.

    * Preconditions:
      - exact sweep: the reserve actor's `r` balance equals `amount`
      - `reserveActor ≠ poolActor`
      - `amount > 0`
    * Effect: debit `reserveActor` at `r` (to zero), then credit
      `poolActor` at `r`, reading from the post-debit intermediate
      state (the two actors are distinct, so the reads are
      independent).

    `decPre` is inferred: the precondition is built from decidable
    `Nat` equality / comparison and `UInt64` inequality. -/
def reclaimAmmReserves (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) : Transition where
  pre := fun s =>
    getBalance s r reserveActor = amount ∧
    reserveActor ≠ poolActor ∧
    amount > 0
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s r reserveActor
                (getBalance s r reserveActor - amount)
    setBalance s1 r poolActor
      (getBalance s1 r poolActor + amount)

/-! ## Cross-resource independence

Both writes land at the single resource `r`; any other resource is
structurally untouched. -/

/-- State-level: the per-resource `BalanceMap` at any `r' ≠ r` is
    unchanged by the sweep. -/
theorem reclaimAmmReserves_other_resource_untouched
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) (s : State)
    {r' : ResourceId} (h : r ≠ r') :
    (step_impl s (reclaimAmmReserves r amount reserveActor
      poolActor)).balances[r']? = s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (reclaimAmmReserves r amount reserveActor poolActor).pre s
  · simp only [if_pos hpre]
    show ((setBalance (setBalance s r reserveActor _) r poolActor _).balances)[r']?
        = s.balances[r']?
    unfold setBalance
    rw [RBMap.find?_insert_other _ r r' _ h,
        RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

/-- Per-actor: any actor's balance at a resource `r' ≠ r` is
    unchanged. -/
theorem reclaimAmmReserves_does_not_touch_other_resources
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId)
    (r' : ResourceId) (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (reclaimAmmReserves r amount reserveActor
      poolActor)) r' a = getBalance s r' a := by
  unfold getBalance
  rw [reclaimAmmReserves_other_resource_untouched r amount reserveActor poolActor s h]

/-! ## Per-actor balance deltas (the sweep characterisation) -/

/-- After a successful sweep, the reserve actor's balance at `r` is
    exactly `0` — the exact-sweep precondition (`balance = amount`)
    drains it completely. -/
theorem reclaimAmmReserves_zeroes_reserve
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) (s : State)
    (hpre : (reclaimAmmReserves r amount reserveActor poolActor).pre s) :
    getBalance (step_impl s (reclaimAmmReserves r amount reserveActor
      poolActor)) r reserveActor = 0 := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((reclaimAmmReserves r amount reserveActor
          poolActor).apply_impl s) r reserveActor = 0
  simp only [reclaimAmmReserves]
  have hne : reserveActor ≠ poolActor := hpre.2.1
  rw [getBalance_setBalance_other _ r r poolActor reserveActor _ (Or.inr (Ne.symm hne))]
  rw [getBalance_setBalance_same]
  rw [hpre.1]
  exact Nat.sub_self amount

/-- After a successful sweep, the pool actor's balance at `r`
    increases by exactly `amount`. -/
theorem reclaimAmmReserves_credits_pool
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) (s : State)
    (hpre : (reclaimAmmReserves r amount reserveActor poolActor).pre s) :
    getBalance (step_impl s (reclaimAmmReserves r amount reserveActor
      poolActor)) r poolActor =
    getBalance s r poolActor + amount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((reclaimAmmReserves r amount reserveActor
          poolActor).apply_impl s) r poolActor = _
  simp only [reclaimAmmReserves]
  have hne : reserveActor ≠ poolActor := hpre.2.1
  rw [getBalance_setBalance_same]
  rw [getBalance_setBalance_other _ r r reserveActor poolActor _ (Or.inr hne)]

/-- A successful sweep leaves untouched any actor other than
    `reserveActor` and `poolActor`, at every resource. -/
theorem reclaimAmmReserves_other_actor_untouched
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId)
    (other : ActorId) (rq : ResourceId) (s : State)
    (hpre : (reclaimAmmReserves r amount reserveActor poolActor).pre s)
    (hne_res : other ≠ reserveActor) (hne_pool : other ≠ poolActor) :
    getBalance (step_impl s (reclaimAmmReserves r amount reserveActor
      poolActor)) rq other = getBalance s rq other := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((reclaimAmmReserves r amount reserveActor
          poolActor).apply_impl s) rq other = _
  simp only [reclaimAmmReserves]
  by_cases hr : r = rq
  · subst hr
    rw [getBalance_setBalance_other _ r r poolActor other _ (Or.inr (Ne.symm hne_pool))]
    rw [getBalance_setBalance_other _ r r reserveActor other _ (Or.inr (Ne.symm hne_res))]
  · rw [getBalance_setBalance_other _ r rq poolActor other _ (Or.inl hr)]
    rw [getBalance_setBalance_other _ r rq reserveActor other _ (Or.inl hr)]

/-! ## Conservation (the headline classification)

The sweep is a single-resource two-actor move, so — unlike `ammSwap` —
it conserves `TotalSupply` at EVERY resource.  `IsConservative` holds,
and `IsMonotonic` follows via `monotonic_of_conservative`. -/

/-- Pure-arithmetic helper for the same-resource conservation case:
    chaining the two `totalSupply_setBalance` master-lemma instances
    under the exact-sweep hypothesis collapses to equality. -/
private theorem reclaim_conservation_arithmetic
    (T0 T1 T2 balRes bal1Pool amount : Nat)
    (h_sweep : balRes = amount)
    (h1 : T1 + balRes = T0 + (balRes - amount))
    (h2 : T2 + bal1Pool = T1 + (bal1Pool + amount)) :
    T2 = T0 := by
  omega

/-- Total supply at the swept resource `r` is unchanged: the debit and
    the credit cancel exactly. -/
theorem reclaimAmmReserves_conserves_at
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) (s : State)
    (hpre : (reclaimAmmReserves r amount reserveActor poolActor).pre s) :
    TotalSupply (step_impl s (reclaimAmmReserves r amount reserveActor
      poolActor)) r = TotalSupply s r := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((reclaimAmmReserves r amount reserveActor
          poolActor).apply_impl s) r = _
  simp only [reclaimAmmReserves]
  have h1 := totalSupply_setBalance s r reserveActor
    (getBalance s r reserveActor - amount)
  have h2 := totalSupply_setBalance
    (setBalance s r reserveActor (getBalance s r reserveActor - amount))
    r poolActor
    (getBalance (setBalance s r reserveActor
        (getBalance s r reserveActor - amount)) r poolActor + amount)
  exact reclaim_conservation_arithmetic
    (TotalSupply s r) _ _
    (getBalance s r reserveActor)
    (getBalance (setBalance s r reserveActor
        (getBalance s r reserveActor - amount)) r poolActor)
    amount hpre.1 h1 h2

/-- `reclaimAmmReserves` is conservative at EVERY resource: the swept
    resource by the cancellation above, every other resource by
    cross-resource independence. -/
instance reclaimAmmReserves_isConservative
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) :
    IsConservative (reclaimAmmReserves r amount reserveActor poolActor) where
  conserves := by
    intro rq s hpre
    by_cases hr : r = rq
    · subst hr
      exact reclaimAmmReserves_conserves_at r amount reserveActor poolActor s hpre
    · unfold TotalSupply
      rw [reclaimAmmReserves_other_resource_untouched r amount reserveActor
            poolActor s hr]

/-! ## Classification instances (§5.3 / LX.3) -/

/-- `reclaimAmmReserves r …` is `LocalTo [r]`: no actor's balance
    changes at any resource other than `r`. -/
instance reclaimAmmReserves_localTo
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) :
    LocalTo [r] (reclaimAmmReserves r amount reserveActor poolActor) where
  local_to := by
    intro r' a s hr_not_in _
    have h : r ≠ r' := by
      intro heq; apply hr_not_in; subst heq; simp
    exact reclaimAmmReserves_does_not_touch_other_resources r amount
      reserveActor poolActor r' a s h

/-- `reclaimAmmReserves` preserves freeze for any resource set `S`
    with `r ∉ S`.  A theorem (not an instance) because `S` is not
    inferable from the goal. -/
theorem reclaimAmmReserves_freezePreserving
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (reclaimAmmReserves r amount reserveActor poolActor) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r ≠ r' := fun heq => h (heq ▸ hr')
    rw [reclaimAmmReserves_other_resource_untouched r amount reserveActor
          poolActor s hne]
    exact h_init

/-- Empty-resource-set freeze preservation (vacuous case). -/
instance reclaimAmmReserves_freezePreserving_empty
    (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) :
    FreezePreserving [] (reclaimAmmReserves r amount reserveActor poolActor) :=
  reclaimAmmReserves_freezePreserving r amount reserveActor poolActor [] (by simp)

/-! ## LX (GP.11.10) Lex re-expression of `reclaimAmmReserves` -/

set_option linter.missingDocs false in
lexlaw reserved_gp_reclaimAmmReserves where
  lex_id              reserved.gp.reclaimAmmReserves
  lex_version         "1.0.0"
  lex_action_index    21
  lex_intent          "Sweep the disabled AMM's frozen L2 reserve balance at one resource into the gas-pool actor.  The bridge actor signs this action after the L1 `emergencyDisableAmm()` kill switch fires; admission additionally requires the L2 `ammDisabled` state-root mirror to be set.  The sweep is exact (the action's `amount` must equal the reserve actor's entire balance), so the reserve drains to zero and the reclaimed liquidity becomes ordinary sequencer-claimable free-pool funds."
  lex_signed_by       bridge
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (amount : Amount)
                      (reserveActor poolActor : ActorId)
  lex_pre             :=
    fun s => getBalance s r reserveActor = amount ∧
             reserveActor ≠ poolActor ∧
             amount > 0
  lex_impl            :=
    fun s =>
      let s1 := setBalance s r reserveActor
                  (getBalance s r reserveActor - amount)
      let s2 := setBalance s1 r poolActor
                  (getBalance s1 r poolActor + amount)
      s2
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- GP.11.10 byte-equivalence regression: the Lex-generated transition
    is definitionally equal to the hand-written `reclaimAmmReserves`. -/
example (r : ResourceId) (amount : Amount)
    (reserveActor poolActor : ActorId) :
    reserved_gp_reclaimAmmReserves_transition r amount reserveActor poolActor =
    reclaimAmmReserves r amount reserveActor poolActor := rfl

end Laws
end LegalKernel

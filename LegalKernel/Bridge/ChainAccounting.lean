-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.ChainAccounting — Workstream CA (chain-level bridge
accounting; GENESIS_PLAN §7.6.4 / §7.6.5; audit finding m-16).

`Accounting.lean` ships the per-action accounting deltas at the unit-step
level and notes that the chain closure "just lifts what is already
proved here" over "a custom `BridgeReachable` predicate [that] Phase-3 /
Phase-4-prelude / Phase-6 do not currently expose."  `Bridge/Reachable.lean`
now exposes that predicate; this module performs the lift.

The conservation invariant `BridgeConserves` states, at every resource,
that the L2 escrow backing (deposits minus withdrawals) is mirrored by
the L2 circulating supply — written additively to avoid `Nat`
truncation: `totalWithdrawn + TotalSupply = totalDeposited`.  Each bridge
transition moves the deposit/withdrawal ledger and the L2 supply in
lockstep (deposit mints, withdrawal burns), so the invariant is preserved
along any `BridgeReachable` chain; from a genesis base case it yields
solvency (`totalWithdrawn ≤ totalDeposited`), which makes the §7.6.4
accounting equation hold unconditionally along bridge chains.

This module is **not** part of the kernel TCB.
-/

import LegalKernel.Bridge.Reachable
import LegalKernel.Bridge.Accounting

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-- The base-state advance of a `deposit` bridge step reduces to the
    kernel `step_impl` of the `deposit` law: the bridge override leaves
    `.base` untouched, and `toTransition` of a non-signer-aware action
    is its `compileTransition`, which for `deposit` is `Laws.deposit`. -/
theorem deposit_step_base
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip : ActorId} {amt : Amount} {dpid : DepositId}
    (haction : st.action = Action.deposit r₀ recip amt dpid)
    (h : BridgeAdmissibleWith verify P dep es st) :
    (apply_bridge_admissible_with verify P dep es st idx h).base
      = step_impl es.base (Laws.deposit r₀ recip amt dpid) := by
  rw [apply_bridge_admissible_with_base, haction]
  rfl

/-- The per-resource L2 supply delta of a `deposit` bridge step: supply
    at `r` rises by `amt` if the deposit is for `r`, else is unchanged.
    Folds the existing `totalSupply_after_deposit` (at the deposit's
    resource) and `deposit_conserves_other_resource` (elsewhere) through
    `deposit_step_base`. -/
theorem deposit_step_supply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip : ActorId} {amt : Amount} {dpid : DepositId}
    (haction : st.action = Action.deposit r₀ recip amt dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    TotalSupply (apply_bridge_admissible_with verify P dep es st idx h).base r
      = TotalSupply es.base r + (if r₀ = r then amt else 0) := by
  rw [deposit_step_base haction h]
  by_cases hr : r₀ = r
  · subst hr
    rw [if_pos rfl]
    exact Laws.totalSupply_after_deposit r₀ recip amt dpid es.base
  · rw [if_neg hr]
    exact Laws.deposit_conserves_other_resource r₀ r recip amt dpid es.base hr

/-- The base-state advance of a `withdraw` bridge step reduces to the
    kernel `step_impl` of the `withdraw` law. -/
theorem withdraw_step_base
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {sender : ActorId} {amt : Amount} {rcp : EthAddress}
    (haction : st.action = Action.withdraw r₀ sender amt rcp)
    (h : BridgeAdmissibleWith verify P dep es st) :
    (apply_bridge_admissible_with verify P dep es st idx h).base
      = step_impl es.base (Laws.withdraw r₀ sender amt rcp) := by
  rw [apply_bridge_admissible_with_base, haction]
  rfl

/-- The per-resource L2 supply delta of a `withdraw` bridge step: supply
    at `r` falls by `amt` if the withdrawal is for `r`, else is
    unchanged.  Stated additively (`supply' + burned = supply`) to avoid
    `Nat` truncation.  The burn is *exact* because admissibility forces
    the withdraw precondition `getBalance ≥ amt` (conjunct 5). -/
theorem withdraw_step_supply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {sender : ActorId} {amt : Amount} {rcp : EthAddress}
    (haction : st.action = Action.withdraw r₀ sender amt rcp)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    TotalSupply (apply_bridge_admissible_with verify P dep es st idx h).base r
        + (if r₀ = r then amt else 0)
      = TotalSupply es.base r := by
  rw [withdraw_step_base haction h]
  by_cases hr : r₀ = r
  · subst hr
    rw [if_pos rfl]
    have hpre : (Laws.withdraw r₀ sender amt rcp).pre es.base := by
      have hp := h.1.2.2.2.1
      rw [haction] at hp
      exact hp
    exact Laws.totalSupply_after_withdraw r₀ sender amt rcp es.base hpre
  · rw [if_neg hr, Nat.add_zero]
    exact Laws.withdraw_conserves_other_resource r₀ r sender amt rcp es.base hr

/-- At-resource L2 supply delta of the `depositWithFee` law: total
    supply at the deposit's resource rises by `userAmount + poolAmount`
    (the two mints to `recipient` and `poolActor`).  Mirrors the
    `totalSupply_after_deposit` law lemma; derived by applying the §8.1
    master lemma `totalSupply_setBalance` once per mint. -/
private theorem totalSupply_after_depositWithFee
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (d : DepositId)
    (s : State)
    (hpre : (Laws.depositWithFee r recipient poolActor userAmount poolAmount
              budgetGrant d).pre s) :
    TotalSupply (step_impl s (Laws.depositWithFee r recipient poolActor
        userAmount poolAmount budgetGrant d)) r
      = TotalSupply s r + (userAmount + poolAmount) := by
  rw [step_impl, if_pos hpre]
  show TotalSupply (setBalance (setBalance s r recipient
          (getBalance s r recipient + userAmount)) r poolActor
          (getBalance (setBalance s r recipient
            (getBalance s r recipient + userAmount)) r poolActor + poolAmount)) r
      = TotalSupply s r + (userAmount + poolAmount)
  have h1 := totalSupply_setBalance s r recipient (getBalance s r recipient + userAmount)
  have h2 := totalSupply_setBalance
      (setBalance s r recipient (getBalance s r recipient + userAmount)) r poolActor
      (getBalance (setBalance s r recipient (getBalance s r recipient + userAmount))
        r poolActor + poolAmount)
  omega

/-- The base-state advance of a `depositWithFee` bridge step reduces to
    the kernel `step_impl` of the `depositWithFee` law. -/
theorem depositWithFee_step_base
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip pool : ActorId} {ua pa : Amount}
    {bg : Nat} {dpid : DepositId}
    (haction : st.action = Action.depositWithFee r₀ recip pool ua pa bg dpid)
    (h : BridgeAdmissibleWith verify P dep es st) :
    (apply_bridge_admissible_with verify P dep es st idx h).base
      = step_impl es.base (Laws.depositWithFee r₀ recip pool ua pa bg dpid) := by
  rw [apply_bridge_admissible_with_base, haction]
  rfl

/-- The per-resource L2 supply delta of a `depositWithFee` bridge step:
    supply at `r` rises by `ua + pa` if the deposit is for `r`, else is
    unchanged. -/
theorem depositWithFee_step_supply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {dep : ByteArray} {es : ExtendedState}
    {st : SignedAction} {idx : Nat}
    {r₀ : ResourceId} {recip pool : ActorId} {ua pa : Amount}
    {bg : Nat} {dpid : DepositId}
    (haction : st.action = Action.depositWithFee r₀ recip pool ua pa bg dpid)
    (h : BridgeAdmissibleWith verify P dep es st)
    (r : ResourceId) :
    TotalSupply (apply_bridge_admissible_with verify P dep es st idx h).base r
      = TotalSupply es.base r + (if r₀ = r then ua + pa else 0) := by
  rw [depositWithFee_step_base haction h]
  have hpre : (Laws.depositWithFee r₀ recip pool ua pa bg dpid).pre es.base := by
    have hp := h.1.2.2.2.1
    rw [haction] at hp
    exact hp
  by_cases hr : r₀ = r
  · subst hr
    rw [if_pos rfl]
    exact totalSupply_after_depositWithFee r₀ recip pool ua pa bg dpid es.base hpre
  · rw [if_neg hr, Nat.add_zero]
    unfold TotalSupply
    rw [Laws.depositWithFee_other_resource_untouched r₀ r recip pool ua pa bg dpid es.base hr]

end Bridge
end LegalKernel

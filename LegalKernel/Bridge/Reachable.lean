-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.Reachable — Workstream CA (chain-level bridge
accounting; GENESIS_PLAN §7.6.4 / §7.6.5; audit finding m-16).

`BridgeReachable` is a reachability predicate restricted to the
bridge-state-mutating transitions and advanced through the production
`apply_bridge_admissible_with` stepper.  It is the substrate for the
chain-level bridge accounting identities (`Accounting.lean`): the
per-action deltas already shipped there compose along a
`BridgeReachable` chain into the conservation theorem
`totalWithdrawn es r + TotalSupply es.base r = totalDeposited es r`,
hence the escrow identity
`totalDeposited es r = totalWithdrawn es r + bridgeEscrowBalance es r`.

`BridgeAction` enumerates exactly the three `Action` constructors whose
`applyActionToBridgeState` arm is non-identity — `deposit`,
`depositWithFee`, and `withdraw` (see
`Bridge/Admissible.lean:applyActionToBridgeState`).  These are also
exactly the constructors that move the per-resource L2 supply
(`TotalSupply`): a deposit mints, a withdrawal burns, in lockstep with
`totalDeposited` / `totalWithdrawn`.  Every other action either leaves
the bridge ledger untouched or is supply-non-conservative (mint / burn /
reward), so the chain-level identity is stated over this restricted set.

This is a Lean-level proof artefact: nothing here serialises, and
`BridgeAction` is **not** a wire extension of `Action`.

This module is **not** part of the kernel TCB.

Design note (CA grounding pass): the original CA plan sketched an L1
escrow *ledger* and an `ExtendedState → ExtendedState` shape for the
kernel `Reachable`.  Neither matches the shipped code: the model is
L2-only (`BridgeState = { consumed, pending, nextWdId, …AMM mirrors }`),
the kernel `Reachable` is `Reachable (s0 : State) : State → Prop`, and
the escrow is the derived quantity `totalDeposited − totalWithdrawn`.
This module is designed against that real model.
-/

import LegalKernel.Bridge.Admissible

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-- The bridge-state-mutating actions: exactly the three `Action`
    constructors whose `applyActionToBridgeState` arm is non-identity. -/
inductive BridgeAction where
  /-- An L1 → L2 deposit (no fee): credits `amount` of `r` to
      `recipient`, recording `depositId` as consumed. -/
  | deposit (r : ResourceId) (recipient : ActorId) (amount : Amount)
      (depositId : DepositId)
  /-- A Workstream-GP deposit with a fee split: credits `userAmount` to
      `recipient` and `poolAmount` to `poolActor`, grants `budgetGrant`,
      and records `depositId` as consumed. -/
  | depositWithFee (r : ResourceId) (recipient poolActor : ActorId)
      (userAmount poolAmount : Amount) (budgetGrant : Nat) (depositId : DepositId)
  /-- An L2 → L1 withdrawal: burns `amount` of `r` from `sender` and
      appends a pending withdrawal to `recipient`. -/
  | withdraw (r : ResourceId) (sender : ActorId) (amount : Amount)
      (recipient : EthAddress)
  deriving Repr, DecidableEq

/-- Embed a `BridgeAction` into the full `Action` type. -/
def BridgeAction.toAction : BridgeAction → Action
  | .deposit r recipient amount d => Action.deposit r recipient amount d
  | .depositWithFee r recipient poolActor ua pa bg d =>
      Action.depositWithFee r recipient poolActor ua pa bg d
  | .withdraw r sender amount rcp => Action.withdraw r sender amount rcp

/-- `BridgeAction.toAction` is injective: distinct bridge actions embed
    to distinct `Action`s.  Each target `Action` constructor is
    injective and the three are pairwise distinct. -/
theorem BridgeAction.toAction_injective {a b : BridgeAction}
    (h : a.toAction = b.toAction) : a = b := by
  cases a <;> cases b <;> simp_all [BridgeAction.toAction]

/-- `BridgeReachable verify P deploymentId es es'`: `es'` is reachable
    from `es` by a finite sequence of bridge-admissible *bridge*
    transitions (`deposit` / `depositWithFee` / `withdraw`), each
    advanced through the production `apply_bridge_admissible_with`
    stepper.  Reflexive-transitive closure of single bridge steps. -/
inductive BridgeReachable
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray) :
    ExtendedState → ExtendedState → Prop where
  /-- A state is bridge-reachable from itself in zero steps. -/
  | refl (es : ExtendedState) : BridgeReachable verify P deploymentId es es
  /-- Prepend one bridge-admissible bridge transition to a chain. -/
  | step {es es'' : ExtendedState} (ba : BridgeAction) (st : SignedAction)
      (l2LogIndex : Nat)
      (haction : st.action = ba.toAction)
      (h : BridgeAdmissibleWith verify P deploymentId es st)
      (hnext : BridgeReachable verify P deploymentId
                 (apply_bridge_admissible_with verify P deploymentId es st
                   l2LogIndex h) es'') :
      BridgeReachable verify P deploymentId es es''

/-- The kernel `base` field after one bridge step is exactly the
    `step_impl` of the signer-aware compiled transition: the bridge
    override `{ … with bridge := … }` leaves `.base` untouched and the
    underlying `apply_admissible_with` reduces by
    `apply_admissible_with_base`.  Holds definitionally. -/
theorem apply_bridge_admissible_with_base
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    (apply_bridge_admissible_with verify P d es st idx h).base =
      step_impl es.base (Action.toTransition st.action st.signer) := rfl

/-- Bridge reachability composes: chain `es → es'` then `es' → es''`. -/
theorem BridgeReachable.trans
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {deploymentId : ByteArray}
    {es es' es'' : ExtendedState}
    (h₁ : BridgeReachable verify P deploymentId es es')
    (h₂ : BridgeReachable verify P deploymentId es' es'') :
    BridgeReachable verify P deploymentId es es'' := by
  induction h₁ with
  | refl _ => exact h₂
  | step ba st idx haction h _hnext ih =>
      exact BridgeReachable.step ba st idx haction h (ih h₂)

end Bridge
end LegalKernel

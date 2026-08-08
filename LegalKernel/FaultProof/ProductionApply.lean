-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.ProductionApply — a total, production-faithful
semantic core for the fault-proof layer.

## Why this exists

`FaultProof/Coherence.lean`'s semantic core
`applyCellWrites_to_state` is `kernelOnlyApply`, the dispute
pipeline's analytical replay.  That function deliberately models
neither bridge nor budget effects — its own comments say so — while
the runtime advances state through
`Bridge.apply_bridge_admissible_with_budget`, whose bridge leg
records consumed deposits and appends pending withdrawals.

For a deposit the two therefore produce DIFFERENT states with
different roots.  That is invisible today, because nothing compares
a step-VM output against a real state root; it becomes an
adjudication error the moment the state-root swap makes exactly that
comparison, on every bridge action.  An honest sequencer's published
root would not match what the game computes — the same class of
failure B-3 exists to remove, reached by a different route.

The obstacle to using the production stepper as the reference is
that it is *guarded*: `apply_bridge_admissible_with` takes a
`BridgeAdmissibleWith` witness, so it is not a total function of
`(state, action)` and cannot be the step VM's reference directly.
`productionApply` is the total function it computes, and
`apply_bridge_admissible_with_eq_productionApply` is the proof that
the two agree wherever the guarded form is defined.

## Scope

Both legs are covered.  The bridge leg is `productionApply`.  The
budget leg — `apply_bridge_admissible_with_budget`'s `epochBudgets`
grant and consume — is `productionApplyBudget`, split from the
five-gate admission predicate `budgetGateAdmits` because the guarded
entry point returns `Option ExtendedState` and a step VM needs the
computation, not the gate: by the time a bisection game reaches a
single step, admission already happened on L2 and the dispute is
over what the state became.  `apply_bridge_admissible_with_budget_eq`
composes the two back into the guarded entry point.
-/

import LegalKernel.Bridge.Admissible
import LegalKernel.Disputes.Evidence

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## Wrapping a `SignedAction` for the replay core -/

/-- The zero-context log entry `kernelOnlyApply` consumes.  Neither
    hash field is read by it. -/
def signedActionEntry (st : SignedAction) : LogEntry :=
  { prevHash := ByteArray.empty
  , signedAction := st
  , postStateHash := ByteArray.empty }

/-! ## The kernel/authority leg

`apply_admissible_with` and `kernelOnlyApply` compute the same
state: kernel step, nonce advance, registry effect, local-policy
effect.  They are written differently on purpose —
`kernelOnlyApply` inlines an exhaustive match so the dispute
pipeline's determinism theorems do not depend on
`Authority/SignedAction.lean`'s import surface — so the agreement
is a theorem rather than a definition. -/

/-- The registry effect agrees between the canonical function and
    `kernelOnlyApply`'s inlined match. -/
theorem applyActionToRegistry_eq_inlined
    (kr : KeyRegistry) (action : Action) :
    applyActionToRegistry kr action =
      (match action with
       | .replaceKey actor newKey => kr.insert actor newKey
       | .registerIdentity actor pk => kr.insert actor pk
       | _ => kr) := by
  cases action <;> rfl

/-- The guarded production stepper's kernel/authority leg is
    `kernelOnlyApply`. -/
theorem apply_admissible_with_eq_kernelOnlyApply
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st) :
    apply_admissible_with verify P d es st h =
      kernelOnlyApply es (signedActionEntry st) := by
  unfold apply_admissible_with kernelOnlyApply signedActionEntry
  cases st.action <;> rfl

/-- `kernelOnlyApply` leaves the bridge sub-state alone.  This is the
    omission the production advance fills, stated positively. -/
theorem kernelOnlyApply_bridge (es : ExtendedState) (entry : LogEntry) :
    (kernelOnlyApply es entry).bridge = es.bridge := by
  unfold kernelOnlyApply
  cases entry.signedAction.action <;> rfl

/-! ## The production state advance, as a total function -/

/-- What the runtime's bridge-aware entry point computes, without
    the admissibility witness.

    `apply_bridge_admissible_with` is
    `apply_admissible_with` followed by the bridge-state effect;
    this is the same composition with the guarded call replaced by
    the total `kernelOnlyApply` it equals. -/
def productionApply (es : ExtendedState) (st : SignedAction)
    (l2LogIndex : Nat) : ExtendedState :=
  let es' := kernelOnlyApply es (signedActionEntry st)
  { es' with bridge := applyActionToBridgeState es.bridge st.action l2LogIndex }

/-- **The total core is faithful.**  Wherever the guarded production
    stepper is defined, it computes exactly `productionApply`.

    This is what lets the fault-proof layer re-anchor on the
    production advance without carrying an admissibility witness
    into the step VM. -/
theorem apply_bridge_admissible_with_eq_productionApply
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat)
    (h : BridgeAdmissibleWith verify P deploymentId es st) :
    apply_bridge_admissible_with verify P deploymentId es st l2LogIndex h =
      productionApply es st l2LogIndex := by
  unfold apply_bridge_admissible_with productionApply
  rw [apply_admissible_with_eq_kernelOnlyApply]

/-! ## The budget leg

`apply_bridge_admissible_with_budget` is the entry point the runtime
actually calls (`Runtime/Loop.lean:220`, `:558`).  On top of the
bridge-aware advance it mutates `epochBudgets`: a grant for the three
budget-granting actions, and a consume for every signer except
`bridgeActor`.  It returns `Option ExtendedState` because five
admission gates can refuse — which is exactly why its total form has
to separate "what it computes when it admits" from "whether it
admits".

`productionApplyBudget` is the former.  `budgetGateAdmits` is the
latter, and the two compose back into the guarded entry point by
`apply_bridge_admissible_with_budget_eq`.  The step VM needs the
computation, not the gate: by the time the bisection game reaches a
single step, admission already happened on L2 and the dispute is
over what the state became. -/

/-- The epoch-budget grant leg: the three actions that mint budget,
    and the identity for every other action. -/
def budgetGrant (signer : ActorId) (action : Action)
    (freeTier currentEpoch : Nat) (ebs : EpochBudgetState) : EpochBudgetState :=
  match action with
  | .depositWithFee _ recipient _ _ _ g _ _ =>
      ebs.topUp recipient currentEpoch freeTier g
  | .topUpActionBudget _ _ inc _ =>
      ebs.topUp signer currentEpoch freeTier inc
  | .topUpActionBudgetFor recipient _ _ inc _ =>
      ebs.topUp recipient currentEpoch freeTier inc
  | _ => ebs

/-- Whether the five admission gates plus the consume succeed.  Split
    out from the computation because the step VM needs what the
    advance produces, not whether admission would have allowed it —
    admission already happened on L2. -/
def budgetGateAdmits (es : ExtendedState) (st : SignedAction)
    (refundRate : ResourceId → Nat) : Bool :=
  match es.budgetPolicy with
  | .bounded freeTier actionCost currentEpoch =>
      topUpActionBudget_gasCheck st.action st.signer es &&
      depositWithFee_signerCheck st.action st.signer &&
      topUpActionBudgetFor_gate st.action st.signer es &&
      topUpRoundTripCheck st.action refundRate &&
      claimBudgetRefund_gate st.action st.signer es refundRate &&
      (st.signer = bridgeActor ||
        (EpochBudgetState.consume es.epochBudgets st.signer currentEpoch freeTier
          (actionCost + refundConsumeExtra st.action)).isSome)

/-- What the runtime's budget-aware entry point computes when it
    admits: the bridge-aware advance, then the consume (skipped for
    `bridgeActor`), then the grant. -/
def productionApplyBudget (es : ExtendedState) (st : SignedAction)
    (l2LogIndex : Nat) : ExtendedState :=
  match es.budgetPolicy with
  | .bounded freeTier actionCost currentEpoch =>
      let applied := productionApply es st l2LogIndex
      if st.signer = bridgeActor then
        { applied with
            epochBudgets :=
              budgetGrant st.signer st.action freeTier currentEpoch es.epochBudgets }
      else
        match EpochBudgetState.consume es.epochBudgets st.signer currentEpoch freeTier
                (actionCost + refundConsumeExtra st.action) with
        | none      => applied
        | some ebs' =>
            { applied with
                epochBudgets :=
                  budgetGrant st.signer st.action freeTier currentEpoch ebs' }

/-- **The budget-aware core is faithful.**  Wherever the guarded
    entry point admits, it returns exactly `productionApplyBudget`;
    wherever it refuses, `budgetGateAdmits` is false.

    This is the shape the step VM needs: one total function for the
    computation, one decidable predicate for the gate, and a proof
    that together they are the production entry point. -/
theorem apply_bridge_admissible_with_budget_eq
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (l2LogIndex : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (refundRate : ResourceId → Nat) :
    apply_bridge_admissible_with_budget verify P d es st l2LogIndex h refundRate =
      (if budgetGateAdmits es st refundRate then
         some (productionApplyBudget es st l2LogIndex)
       else none) := by
  unfold apply_bridge_admissible_with_budget budgetGateAdmits productionApplyBudget
  cases _h_pol : es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    -- Peel the five gates in order; each false arm is `none` on both
    -- sides, and the surviving arm splits on the bridgeActor
    -- exemption and then on the consume.
    by_cases g₁ : topUpActionBudget_gasCheck st.action st.signer es
    case neg => simp [g₁]
    by_cases g₂ : depositWithFee_signerCheck st.action st.signer
    case neg => simp [g₁, g₂]
    by_cases g₃ : topUpActionBudgetFor_gate st.action st.signer es
    case neg => simp [g₁, g₂, g₃]
    by_cases g₄ : topUpRoundTripCheck st.action refundRate
    case neg => simp [g₁, g₂, g₃, g₄]
    by_cases g₅ : claimBudgetRefund_gate st.action st.signer es refundRate
    case neg => simp [g₁, g₂, g₃, g₄, g₅]
    simp only [g₁, g₂, g₃, g₄, g₅, Bool.true_and, Bool.and_true]
    by_cases hb : st.signer = bridgeActor
    · simp only [hb, if_pos, decide_true, Bool.true_or]
      rw [apply_bridge_admissible_with_eq_productionApply]
      simp only [budgetGrant]
      cases st.action <;> rfl
    · cases h_c : EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
                    freeTier (actionCost + refundConsumeExtra st.action) with
      | none   => simp [hb]
      | some _ =>
        simp only [hb, decide_false, Bool.false_or, Option.isSome_some]
        rw [apply_bridge_admissible_with_eq_productionApply]
        simp only [budgetGrant]
        cases st.action <;> rfl

/-! ## What the current fault-proof core misses

The two theorems below are the divergence, stated rather than left
to a test: the fault-proof layer's core agrees with the production
one exactly on the non-bridge actions, and differs on the three
bridge-mutating ones. -/

/-- On every non-bridge action the production advance and the
    dispute pipeline's replay agree, so the fault-proof layer's
    current choice of core is correct there. -/
theorem productionApply_eq_kernelOnlyApply_of_non_bridge
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat)
    (hne_dep : ∀ r recipient amount d, st.action ≠ .deposit r recipient amount d)
    (hne_dwf : ∀ r recipient poolActor ua pa bg d sa,
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg d sa)
    (hne_wd : ∀ r sender amount rcp, st.action ≠ .withdraw r sender amount rcp) :
    productionApply es st l2LogIndex = kernelOnlyApply es (signedActionEntry st) := by
  unfold productionApply
  rw [applyActionToBridgeState_non_bridge es.bridge st.action l2LogIndex
    hne_dep hne_dwf hne_wd,
    ← kernelOnlyApply_bridge es (signedActionEntry st)]

/-- On a deposit the two differ: the production advance marks the
    deposit consumed and the replay does not.  Stated as the
    concrete witness rather than as a bare inequality, so the
    difference is exhibited rather than asserted. -/
theorem productionApply_marks_deposit_consumed
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat)
    (r : ResourceId) (recipient : ActorId) (amount : Amount) (d : DepositId)
    (h : st.action = .deposit r recipient amount d) :
    (productionApply es st l2LogIndex).bridge =
      es.bridge.markConsumed d
        { resource := r, userAmount := amount, poolAmount := 0, budgetGrant := 0 } := by
  unfold productionApply
  rw [h]
  rfl

/-! ## Multi-step

`kernelOnlyReplay` is `entries.foldl kernelOnlyApply genesis` — no
index to thread, because `kernelOnlyApply` has no bridge leg that
needs one.  The production advance does, and the index it wants is
the entry's own position in the log, so the production replay is a
fold that counts. -/

/-- The production advance folded over a log, threading the L2 log
    index from `startIdx`.  This is what a chain of adjudicated steps
    computes, and the target the fault-proof layer's multi-step
    coherence is stated against. -/
def productionReplayBudget (es : ExtendedState) (startIdx : Nat) :
    List SignedAction → ExtendedState
  | []        => es
  | st :: rest =>
      productionReplayBudget (productionApplyBudget es st startIdx)
        (startIdx + 1) rest

/-- The empty-log reduction. -/
theorem productionReplayBudget_nil (es : ExtendedState) (i : Nat) :
    productionReplayBudget es i [] = es := rfl

/-- The cons-step reduction: one production advance at `i`, then the
    rest from `i + 1`. -/
theorem productionReplayBudget_cons
    (es : ExtendedState) (i : Nat) (st : SignedAction) (rest : List SignedAction) :
    productionReplayBudget es i (st :: rest)
      = productionReplayBudget (productionApplyBudget es st i) (i + 1) rest := rfl

/-- The bridge sub-state after one production advance.  Stated because
    the fault-proof layer used to assert the OPPOSITE — that its
    reference apply left the bridge alone — which was true of
    `kernelOnlyApply` and is the divergence the repoint closes. -/
theorem productionApplyBudget_bridge
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    (productionApplyBudget es st l2LogIndex).bridge
      = applyActionToBridgeState es.bridge st.action l2LogIndex := by
  unfold productionApplyBudget productionApply
  -- Only `epochBudgets` differs between the three branches; the
  -- bridge field is written once, before any of them.  The consume is
  -- a match on a non-constructor, so generalise it rather than
  -- hoping for iota.
  cases h_pol : es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    simp only []
    by_cases h : st.signer = bridgeActor
    · simp only [if_pos h]
    · simp only [if_neg h]
      cases _hc : EpochBudgetState.consume es.epochBudgets st.signer currentEpoch
                    freeTier (actionCost + refundConsumeExtra st.action) with
      | none   => simp only []
      | some _ => simp only []

end FaultProof
end LegalKernel

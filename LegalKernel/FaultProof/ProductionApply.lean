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

This covers the bridge leg.  The budget leg —
`apply_bridge_admissible_with_budget`'s `epochBudgets` grant and
consume — is a further difference between the guarded entry point
and this core, and is called out rather than silently folded in:
that stepper returns `Option ExtendedState` because five admission
gates can refuse, so its total form has a different shape.  The
epoch-budget cells are already in the cell space (tag 13), so
representing it is a matter of extending this module, not of
extending the root.
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
    (hne_dwf : ∀ r recipient poolActor ua pa bg d,
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg d)
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

end FaultProof
end LegalKernel

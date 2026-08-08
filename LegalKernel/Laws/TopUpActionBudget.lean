-- SPDX-License-Identifier: GPL-3.0-or-later
import LegalKernel.Kernel
import LegalKernel.Laws.AmountBound

namespace LegalKernel
namespace Laws

/-- Kernel-level transfer leg of action-budget top-up.

    `transfer`-shaped, ceiling conjunct included: the credit reads the
    POST-DEBIT state, so a top-up by the pool actor itself (`a =
    poolActor`, which the reserved-actor policy does not forbid) is
    bounded by its own balance rather than by twice it.  See
    `Laws/AmountBound.lean` for why the bound is a precondition. -/
def topUpActionBudget (a : ActorId) (gasResource : ResourceId)
    (gasAmount : Amount) (_budgetIncrement : Nat) (poolActor : ActorId) : Transition where
  pre := fun s =>
    getBalance s gasResource a ≥ gasAmount ∧
    AmountBounded (setBalance s gasResource a (getBalance s gasResource a - gasAmount))
      gasResource poolActor gasAmount
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s gasResource a (getBalance s gasResource a - gasAmount)
    setBalance s1 gasResource poolActor (getBalance s1 gasResource poolActor + gasAmount)

/-- Decidability sanity check: `topUpActionBudget`'s precondition is
    decidable on every state. -/
example (a : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (s : State) :
    Decidable ((topUpActionBudget a gasResource gasAmount budgetIncrement
      poolActor).pre s) :=
  inferInstance

end Laws
end LegalKernel

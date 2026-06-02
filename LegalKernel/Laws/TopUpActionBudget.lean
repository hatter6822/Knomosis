-- SPDX-License-Identifier: GPL-3.0-or-later
import LegalKernel.Kernel

namespace LegalKernel
namespace Laws

/-- Kernel-level transfer leg of action-budget top-up. -/
def topUpActionBudget (a : ActorId) (gasResource : ResourceId)
    (gasAmount : Amount) (_budgetIncrement : Nat) (poolActor : ActorId) : Transition where
  pre := fun s => getBalance s gasResource a ≥ gasAmount
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s gasResource a (getBalance s gasResource a - gasAmount)
    setBalance s1 gasResource poolActor (getBalance s1 gasResource poolActor + gasAmount)

end Laws
end LegalKernel

import LegalKernel.Kernel

namespace LegalKernel
namespace Laws

/-- Kernel-level transfer leg of an action-budget top-up. Debits
`gasAmount` from signer `a` at `gasResource`, then credits `poolActor`
by the same amount at that resource. The `_budgetIncrement` payload is
consumed by authority-layer admission logic, not by kernel `State`. -/
def topUpActionBudget (a : ActorId) (gasResource : ResourceId)
    (gasAmount : Amount) (_budgetIncrement : Nat) (poolActor : ActorId) : Transition where
  pre := fun s => getBalance s gasResource a ≥ gasAmount
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s gasResource a (getBalance s gasResource a - gasAmount)
    setBalance s1 gasResource poolActor (getBalance s1 gasResource poolActor + gasAmount)

end Laws
end LegalKernel

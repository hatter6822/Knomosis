-- SPDX-License-Identifier: GPL-3.0-or-later
import LegalKernel.Kernel
import LegalKernel.Bridge.State

namespace LegalKernel
namespace Laws

/-- Bridge deposit with user-chosen fee split. -/
def depositWithFee (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (_budgetGrant : Nat)
    (_depositId : Bridge.DepositId) : Transition where
  pre := fun _ => True
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s r recipient (getBalance s r recipient + userAmount)
    setBalance s1 r poolActor (getBalance s1 r poolActor + poolAmount)

/-- Per-resource map at `r' ≠ r` is unchanged by `depositWithFee`. -/
theorem depositWithFee_other_resource_untouched
    (r r' : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId) (s : State) (h : r ≠ r') :
    (step_impl s
      (depositWithFee r recipient poolActor userAmount poolAmount budgetGrant depositId)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  simp [depositWithFee, setBalance]
  rw [RBMap.find?_insert_other _ r r' _ h]
  rw [RBMap.find?_insert_other _ r r' _ h]

end Laws
end LegalKernel

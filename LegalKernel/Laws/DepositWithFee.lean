-- SPDX-License-Identifier: GPL-3.0-or-later
import LegalKernel.Kernel
import LegalKernel.Bridge.State
import LegalKernel.Laws.AmountBound

namespace LegalKernel
namespace Laws

/-- Bridge deposit with user-chosen fee split.

    Both legs carry the C-3 ceiling conjunct
    (`Laws/AmountBound.lean`), and the pool leg reads the state the
    user leg already wrote: `recipient` and `poolActor` can coincide
    — a depositor who is also the fee pool — and bounding the two
    credits independently would then miss their sum. -/
def depositWithFee (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (_budgetGrant : Nat)
    (_depositId : Bridge.DepositId) : Transition where
  pre := fun s =>
    AmountBounded s r recipient userAmount ∧
    AmountBounded (setBalance s r recipient (getBalance s r recipient + userAmount))
      r poolActor poolAmount
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
  by_cases hpre : (depositWithFee r recipient poolActor userAmount poolAmount
                    budgetGrant depositId).pre s
  · simp only [if_pos hpre]
    simp [depositWithFee, setBalance]
    rw [RBMap.find?_insert_other _ r r' _ h]
    rw [RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

end Laws
end LegalKernel

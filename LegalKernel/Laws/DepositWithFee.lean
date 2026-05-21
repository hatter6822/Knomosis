import LegalKernel.Kernel
import LegalKernel.Bridge.State

namespace LegalKernel
namespace Laws

/-- Bridge deposit with user-chosen fee split. Credits `userAmount` to
`recipient` and `poolAmount` to `poolActor` under resource `r`. The
`budgetGrant` and `depositId` payload fields are carried for cross-stack
compatibility; kernel-level balance updates depend only on the amounts. -/
def depositWithFee (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (_budgetGrant : Nat)
    (_depositId : Bridge.DepositId) : Transition where
  pre := fun _ => True
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s r recipient (getBalance s r recipient + userAmount)
    setBalance s1 r poolActor (getBalance s1 r poolActor + poolAmount)

end Laws
end LegalKernel

-- SPDX-License-Identifier: GPL-3.0-or-later
import LegalKernel.Kernel
import LegalKernel.Bridge.State
import LegalKernel.Laws.AmountBound

namespace LegalKernel
namespace Laws

/-- Bridge deposit with user-chosen fee split and the AMM seed leg
    (Workstream GP §15E v1.0 + Workstream SB).

    THREE chained credits at one resource: the recipient's
    `userAmount`, the pool's NET share `poolAmount - seedAmount`, and
    the reserve's `seedAmount` — the L2 mirror of the L1
    `_seedAmmReserves` fee split, leg for leg, so the total supply
    delta stays `userAmount + poolAmount` and the chain-accounting
    escrow identity is unchanged.

    Every leg carries the C-3 ceiling conjunct
    (`Laws/AmountBound.lean`), each stated over the state the credit
    actually reads: the actors can coincide pairwise (a depositor who
    is also the fee pool; a deployment whose pool IS the reserve), and
    bounding the credits independently would then miss their sums.
    `seedAmount ≤ poolAmount` is a conjunct rather than a truncation:
    a split that claims more seed than fee is a NO-OP, not a
    re-balanced write.

    `reserveActor` is a LAW parameter, not an action field: the
    compiler (`Action.compileTransition`) pins it to the canonical
    `Bridge.ammReserveActor`, so no admissibility conjunct is needed
    to stop a forged seed target. -/
def depositWithFee (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (_budgetGrant : Nat)
    (_depositId : Bridge.DepositId) (seedAmount : Amount)
    (reserveActor : ActorId) : Transition where
  pre := fun s =>
    AmountBounded s r recipient userAmount ∧
    AmountBounded (setBalance s r recipient (getBalance s r recipient + userAmount))
      r poolActor (poolAmount - seedAmount) ∧
    seedAmount ≤ poolAmount ∧
    AmountBounded
      (setBalance
        (setBalance s r recipient (getBalance s r recipient + userAmount))
        r poolActor
        (getBalance
          (setBalance s r recipient (getBalance s r recipient + userAmount))
          r poolActor + (poolAmount - seedAmount)))
      r reserveActor seedAmount
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s r recipient (getBalance s r recipient + userAmount)
    let s2 := setBalance s1 r poolActor
                (getBalance s1 r poolActor + (poolAmount - seedAmount))
    setBalance s2 r reserveActor (getBalance s2 r reserveActor + seedAmount)

/-- Decidability sanity check: `depositWithFee`'s precondition is
    decidable on every state. -/
example (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId) (seedAmount : Amount)
    (reserveActor : ActorId) (s : State) :
    Decidable ((depositWithFee r recipient poolActor userAmount poolAmount
      budgetGrant depositId seedAmount reserveActor).pre s) :=
  inferInstance

/-- Per-resource map at `r' ≠ r` is unchanged by `depositWithFee`. -/
theorem depositWithFee_other_resource_untouched
    (r r' : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId) (seedAmount : Amount)
    (reserveActor : ActorId) (s : State) (h : r ≠ r') :
    (step_impl s
      (depositWithFee r recipient poolActor userAmount poolAmount budgetGrant
        depositId seedAmount reserveActor)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (depositWithFee r recipient poolActor userAmount poolAmount
                    budgetGrant depositId seedAmount reserveActor).pre s
  · simp only [if_pos hpre]
    simp [depositWithFee, setBalance]
    rw [RBMap.find?_insert_other _ r r' _ h]
    rw [RBMap.find?_insert_other _ r r' _ h]
    rw [RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

end Laws
end LegalKernel

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.BulkBound — the recipient bound the bulk laws
enforce.

`distributeOthers` and `proportionalDilute` credit every non-excluded
actor at a resource.  That is unboundedly many balance cells, and the
fault-proof game decomposes a bulk action into one sub-step per
recipient so the L1 can execute them one at a time
(`FaultProof/SubStep.lean`).

The decomposition is capped, because the L1 cannot carry an unbounded
bisection.  The LAW was not, which meant a bulk action with more
recipients than the cap had a post-state the game could not reach: a
terminal step over it would settle on a root the L2 never published.
With `maxRecipientsPerBulkAction` actors an ordinary deployment size,
that was reachable rather than theoretical.

The bound lives here, in the precondition, rather than in the
admission gate — it is a property of the transition, not of who
submits it, and `step_impl` is `if pre then apply_impl else id`, so
above the bound the step is a no-op and the decomposition is complete
by construction.  Fail-closed in the direction that matters: an action
the L1 cannot adjudicate is one the L2 does not admit.

This module is intentionally tiny and sits below both bulk laws so the
constant has exactly one definition; `FaultProof/SubStep.lean` reads
it from here too.
-/

import LegalKernel.Kernel

namespace LegalKernel
namespace Laws

/-- Maximum recipients a single bulk action may credit.

    Matches the L1's per-`executeStep` cell-proof cap
    (`KnomosisStepVM.MAX_RECIPIENTS_PER_BULK_ACTION`), and the two must
    stay equal: the number is what makes the game's decomposition
    cover the law's effect exactly. -/
def maxRecipientsPerBulkAction : Nat := 256

/-- The recipients a bulk action at `r` credits: the resource's
    balance-map entries minus the excluded actor, in map order.

    The ORDER is consensus, not incidental.  Both bulk laws fold over
    this list, the fault-proof decomposition walks it, and an SMT fold
    is order-sensitive — so the order has to be a function of
    `(state, action)` rather than of anything a caller supplies. -/
def bulkRecipients (s : State) (r : ResourceId) (excluded : ActorId) :
    List (ActorId × Amount) :=
  (s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded)

/-- The bulk-action recipient bound, as a state predicate. -/
def BulkBounded (s : State) (r : ResourceId) (excluded : ActorId) : Prop :=
  (bulkRecipients s r excluded).length ≤ maxRecipientsPerBulkAction

/-- Decidable, so it composes into a `Transition.decPre` built by
    `inferInstance` like every other precondition on this project. -/
instance BulkBounded.decidable (s : State) (r : ResourceId) (excluded : ActorId) :
    Decidable (BulkBounded s r excluded) := by
  unfold BulkBounded; exact inferInstance

/-- A resource the state does not hold has no recipients, so the bound
    is satisfied vacuously.  The genesis case, and the one every
    small-fixture proof needs. -/
theorem bulkBounded_of_absent (s : State) (r : ResourceId) (excluded : ActorId)
    (h : s.balances[r]? = none) : BulkBounded s r excluded := by
  unfold BulkBounded bulkRecipients
  rw [h]
  exact Nat.zero_le _

/-- Any state whose resource-`r` map is no bigger than the cap
    satisfies the bound, since filtering only shrinks the list. -/
theorem bulkBounded_of_map_length_le (s : State) (r : ResourceId) (excluded : ActorId)
    (h : (s.balances[r]?.getD ∅).toList.length ≤ maxRecipientsPerBulkAction) :
    BulkBounded s r excluded :=
  Nat.le_trans (List.length_filter_le _ _) h

end Laws
end LegalKernel

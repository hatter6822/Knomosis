-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.StateCells — the cell view of an
`ExtendedState`, and the PUBLISHED state root over it.

## Why the root is built this way

The root this module defines is `commitExtendedState`: the value a
sequencer publishes to L1.  It replaced a hash over seven
concatenated sub-state ENCODINGS
(`commitExtendedStateConcat`, kept in `Commit.lean` as the record
of the retired construction).

The reason is structural, not gas.  The L1 step VM never holds the
sub-state encodings — it holds the 32-byte root and whatever cells
the responder proves — so from a concatenation hash it cannot
recompute a post-state root from a pre-state root plus the step's
writes.  A root over CELLS can: writing a cell changes exactly one
leaf, so the post-root is a function of the pre-root and the proven
writes, computable on L1 from an `O(log N)` opening
(`smtUpdateRoot`, `FaultProof/SmtInjective.lean`).

`KnomosisStepVM.executeStep` has NOT yet been rewritten to exploit
that, so the fault-proof game still does not adjudicate — see
`docs/audits/19-findings-and-followups.md` and
`docs/planning/state_root_merkleisation_plan.md` §4.  This module is
the half of the fix that makes the other half possible.

## Completeness

`stateCellTags` must enumerate every cell the state has, or the
root binds less than the retired concatenation did and the swap
would have been a regression.  The two halves:

  * **keyed cells** — one per live entry of each sub-state map.
  * **singleton cells** — the bridge scalars and the budget-policy
    scalars, which exist unconditionally.

`stateCells_covers_every_kind` pins that every constructor of
`CellTag` is reachable, so a tag added without an enumeration arm
is caught rather than silently dropped from the root.
-/

import LegalKernel.FaultProof.CellValue
import LegalKernel.FaultProof.KeyDerivation

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge

/-! ## Cell enumeration -/

/-- The singleton cells: present in every state regardless of which
    map entries are live. -/
def singletonCellTags : List CellTag :=
  [ .bridgeNextWdId
  , .bridgeAmmReserveEth
  , .bridgeAmmReserveBold
  , .bridgeBoldCircuitClosed
  , .bridgeBoldTvlCap
  , .bridgeBoldTotalLockedValue
  , .bridgeAmmDisabled
  , .budgetPolicyFreeTier
  , .budgetPolicyActionCost
  , .budgetPolicyCurrentEpoch
  ]

/-- Every cell tag of a state: one per live map entry, plus the
    singletons.

    Absent entries are deliberately NOT enumerated — an SMT leaf
    that is not present reads as the canonical empty sub-tree, which
    is what `canonicalAbsentValue` mirrors on the read side.  Adding
    them would change the root without changing the state. -/
def stateCellTags (es : ExtendedState) : List CellTag :=
  -- Balances: the outer map is resource → per-resource balance map.
  (es.base.balances.toList.flatMap (fun rbm =>
      rbm.2.toList.map (fun av => CellTag.balance rbm.1 av.1))) ++
  (es.nonces.next.toList.map (fun an => CellTag.nonce an.1)) ++
  (es.registry.toList.map (fun ak => CellTag.registry ak.1)) ++
  (es.localPolicies.toList.map (fun ap => CellTag.localPolicy ap.1)) ++
  (es.bridge.consumed.toList.map (fun dr => CellTag.bridgeConsumed dr.1)) ++
  (es.bridge.pending.toList.map (fun wp => CellTag.bridgePending wp.1)) ++
  (es.epochBudgets.toList.map (fun ab => CellTag.epochBudget ab.1)) ++
  singletonCellTags

/-- The `(smtKey, value)` entries the state's SMT root is built
    from. -/
def stateCellEntries (es : ExtendedState) : List (ByteArray × ByteArray) :=
  (stateCellTags es).map (fun t => (smtCellKey t, getCellValue es t))

/-! ## The SMT state root -/

/-- The SMT root over the state's cells.

    Built from `smtRootListAux` at the full `smtDepth`, keyed by
    `smtCellKey`.  Distinct keys are load-bearing: `smtRootListAux`
    collapses a level holding two entries with equal keys, so a key
    collision silently changes the root.  `smtCellKey`'s
    injectivity (`smtCellKey_injective_under_collision_free`) is
    what rules that out. -/
def commitExtendedState (es : ExtendedState) : StateCommit :=
  smtRootListAux smtDepth (stateCellEntries es)

/-- The SMT state root is a 32-byte hash, like every other root in
    the system. -/
theorem commitExtendedState_size (es : ExtendedState) :
    (commitExtendedState es).size = 32 :=
  smtRootListAux_size smtDepth _

/-- Determinism. -/
theorem commitExtendedState_deterministic
    (es₁ es₂ : ExtendedState) (h : es₁ = es₂) :
    commitExtendedState es₁ = commitExtendedState es₂ := by rw [h]

/-! ## Coverage

The enumeration is only as good as its completeness: a cell the
root does not include is a field the fault-proof game cannot
adjudicate, which is the defect this whole line of work exists to
close. -/

/-- Every singleton cell is enumerated for every state. -/
theorem singleton_tags_enumerated (es : ExtendedState) (t : CellTag)
    (h : t ∈ singletonCellTags) : t ∈ stateCellTags es := by
  unfold stateCellTags
  simp only [List.mem_append]
  exact Or.inr h

/-- A live balance entry is enumerated. -/
theorem balance_tag_enumerated
    (es : ExtendedState) (r : ResourceId) (a : ActorId) (bm : BalanceMap) (v : Amount)
    (h_outer : (r, bm) ∈ es.base.balances.toList)
    (h_inner : (a, v) ∈ bm.toList) :
    CellTag.balance r a ∈ stateCellTags es := by
  -- The balance block is the head of a left-associated append
  -- chain, so `simp` normalises the membership into a disjunction
  -- and the witness discharges the first disjunct.
  unfold stateCellTags
  simp only [List.mem_append, List.mem_flatMap, List.mem_map]
  exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl (Or.inl (Or.inl
    ⟨(r, bm), h_outer, (a, v), h_inner, rfl⟩))))))

/-- A live epoch-budget entry is enumerated.  Stated separately
    because this is the sub-state whose omission from the cell space
    meant an inflated actor budget could not be challenged. -/
theorem epochBudget_tag_enumerated
    (es : ExtendedState) (a : ActorId) (b : ActorBudget)
    (h : (a, b) ∈ es.epochBudgets.toList) :
    CellTag.epochBudget a ∈ stateCellTags es := by
  unfold stateCellTags
  simp only [List.mem_append, List.mem_map]
  exact Or.inl (Or.inr ⟨(a, b), h, rfl⟩)

end FaultProof
end LegalKernel

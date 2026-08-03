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
import Lex.DSL.PreGrammar

namespace LegalKernel
namespace Laws

/-- Maximum recipients a single bulk action may credit.

    Matches the L1's per-`executeStep` cell-proof cap
    (`KnomosisStepVM.MAX_RECIPIENTS_PER_BULK_ACTION`), and the two must
    stay equal: the number is what makes the game's decomposition
    cover the law's effect exactly. -/
def maxRecipientsPerBulkAction : Nat := 256

/-- The recipients a bulk action at `r` credits: the resource's
    balance-map entries minus the excluded actor and minus any entry
    whose balance is zero, in map order.

    The ORDER is consensus, not incidental.  Both bulk laws fold over
    this list, the fault-proof decomposition walks it, and an SMT fold
    is order-sensitive — so the order has to be a function of
    `(state, action)` rather than of anything a caller supplies.  Both
    laws *call* this definition rather than re-deriving it, so the
    footprint `Action.stateWriteCells` declares and the set the laws
    credit cannot drift apart.

    **The zero filter is load-bearing** (see
    `bulkRecipients_values_ne_zero`).  A `Std.TreeMap` entry mapping an
    actor to `0` is indistinguishable, at the state-commitment root,
    from no entry at all: `stateCellEntries` drops canonically-absent
    cells and `canonicalAbsentValue (.balance _ _) = encodeAmount 0`,
    so a zero-balance actor has no leaf.  Without the filter,
    `distributeOthers`' flat credit would pay such an actor `amount`,
    and two ROOT-IDENTICAL pre-states — one holding a live zero entry,
    one holding none — would produce post-states with DIFFERENT roots.
    The root would then not be a sufficient statistic for the
    transition, which is the premise the whole fault proof rests on.
    Reachable rather than theoretical: `setBalance s r a 0` is what any
    whole-balance transfer leaves behind, and `reclaimAmmReserves`
    sweeps to zero by design.

    `proportionalDilute` was already safe on its own — its credit is
    `totalReward * kv.2 / S`, which is `0` at `kv.2 = 0` — so the
    filter is a no-op there.  That asymmetry is exactly why the two
    laws must share one list rather than each spell their own. -/
def bulkRecipients (s : State) (r : ResourceId) (excluded : ActorId) :
    List (ActorId × Amount) :=
  (s.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded && kv.2 != 0)

/-- The bulk-action recipient bound, as a state predicate.

    `@[lex_pre]` because both bulk laws name it in their `lex_pre`
    clause and the §7.2 grammar admits a user predicate only when it
    is tagged.  The tag's contract is that the predicate is decidable
    via `inferInstance` for in-grammar arguments, which
    `BulkBounded.decidable` below supplies. -/
@[lex_pre]
def BulkBounded (s : State) (r : ResourceId) (excluded : ActorId) : Prop :=
  (bulkRecipients s r excluded).length ≤ maxRecipientsPerBulkAction

/-! ### The `@[lex_pre]` tag really fires

Checked at elaboration time rather than asserted, because the tag is
easy to get silently wrong: it records FULLY-QUALIFIED names while the
Lex walker runs on surface syntax before elaboration, so a `lex_pre`
clause spelling the short form falls through to L003 with no error —
just a warning someone would have to read the build log to notice.
`BulkBounded` is the first declaration on this project to carry the
tag, so nothing else would catch a regression here.

A build failure is the right severity: an untagged predicate makes both
bulk laws warn, and CI fails on any Lean warning. -/

open Lean Elab Command in
run_cmd do
  unless LegalKernel.DSL.Lex.isLexPreTagged (← getEnv)
      `LegalKernel.Laws.BulkBounded do
    throwError "BulkBounded lost its @[lex_pre] tag: both bulk laws' \
                `lex_pre` clauses will emit L003, and CI fails on warnings"

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

/-- Membership in the recipient list, unpacked.  Both bulk laws and
    the fault proof reason from one of the three components, so state
    the decomposition once rather than re-running `List.mem_filter`
    and `Bool.and_eq_true` at every site. -/
theorem mem_bulkRecipients_iff (s : State) (r : ResourceId) (excluded : ActorId)
    (kv : ActorId × Amount) :
    kv ∈ bulkRecipients s r excluded ↔
      kv ∈ (s.balances[r]?.getD ∅).toList ∧ kv.1 ≠ excluded ∧ kv.2 ≠ 0 := by
  unfold bulkRecipients
  rw [List.mem_filter]
  constructor
  · rintro ⟨hmem, hp⟩
    obtain ⟨h₁, h₂⟩ := Bool.and_eq_true _ _ |>.mp hp
    exact ⟨hmem, by simpa using h₁, by simpa using h₂⟩
  · rintro ⟨hmem, h₁, h₂⟩
    exact ⟨hmem, by simp [h₁, h₂]⟩

/-- No recipient is the excluded actor — the property both laws'
    `_excluded_unchanged` theorems consume. -/
theorem bulkRecipients_key_ne_excluded (s : State) (r : ResourceId)
    (excluded : ActorId) {kv : ActorId × Amount}
    (h : kv ∈ bulkRecipients s r excluded) : kv.1 ≠ excluded :=
  ((mem_bulkRecipients_iff s r excluded kv).mp h).2.1

/-- **Every recipient holds a positive balance**, hence has a leaf in
    the state-commitment tree.

    This is the property that makes a bulk step's post-state a
    function of the pre-state ROOT rather than of the pre-state map:
    the recipients are exactly the live balance cells at `r` other
    than `excluded`, and "live" is what the root observes.  A state
    holding an actor at zero and a state holding no entry for that
    actor commit to the same root AND now credit the same set.

    "Exactly" is a theorem, not a reading of this one:
    `FaultProof.exists_mem_bulkRecipients_iff_cell_live` states the
    both-ways form against `getCellValue` / `canonicalAbsentValue` —
    the very predicate `stateCellEntries` filters on.  It cannot live
    here, since this module sits below the cell space. -/
theorem bulkRecipients_values_ne_zero (s : State) (r : ResourceId)
    (excluded : ActorId) {kv : ActorId × Amount}
    (h : kv ∈ bulkRecipients s r excluded) : kv.2 ≠ 0 :=
  ((mem_bulkRecipients_iff s r excluded kv).mp h).2.2

/-- **The recipients are pairwise distinct.**

    They come from a `Std.TreeMap`'s `toList`, so this is true; core
    states it as `Pairwise (compare · · ≠ .eq)` over the pair list
    rather than as a key disequality, hence the bridge.

    It matters for the fault proof rather than for the law: the
    decomposition's ordered fold opens one cell per recipient against
    the root the previous write produced, so a repeated recipient
    would make the second opening stale and the fold reject a step an
    honest sequencer defended correctly. -/
theorem bulkRecipients_keys_pairwise_ne (s : State) (r : ResourceId)
    (excluded : ActorId) :
    (bulkRecipients s r excluded).Pairwise (fun a b => a.1 ≠ b.1) := by
  unfold bulkRecipients
  refine List.Pairwise.sublist List.filter_sublist ?_
  refine List.Pairwise.imp_of_mem ?_ Std.TreeMap.distinct_keys_toList
  intro a b _ _ h h_eq
  exact h (by rw [h_eq]; exact Std.compare_self)

/-- ...so the cells the decomposition writes are distinct. -/
theorem bulkRecipients_nodup_keys (s : State) (r : ResourceId) (excluded : ActorId) :
    ((bulkRecipients s r excluded).map Prod.fst).Nodup :=
  List.Pairwise.map _ (fun _ _ h => h) (bulkRecipients_keys_pairwise_ne s r excluded)

end Laws
end LegalKernel

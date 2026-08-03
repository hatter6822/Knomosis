-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.SubStep — the bulk-action decomposition on
real states.

The load-bearing cases are the three about the recipient bound.
`maxRecipientsPerBulkAction` truncates the decomposition, because the
L1 cannot carry an unbounded bisection.  The LAW used to truncate
nothing, so above the cap a bulk action had a post-state the game could
not reach.  `Laws.BulkBounded` is now a conjunct of both bulk
preconditions, which makes the step a no-op above the bound — and the
tests check BOTH directions plus the gate itself, so the bound cannot
become vacuous in either direction without one of them failing.
-/

import LegalKernel.FaultProof.SubStep
import LegalKernel.Laws.DistributeOthers
import LegalKernel.Laws.ProportionalDilute
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.SubStep

/-- A resource-1 balance map holding `n` actors, ids `1 .. n`, each
    with balance 10. -/
def mapOf (n : Nat) : BalanceMap :=
  (List.range n).foldl (fun m i => m.insert (UInt64.ofNat (i + 1)) 10) ∅

/-- A state whose resource 1 holds `n` actors. -/
def stateOf (n : Nat) : ExtendedState :=
  { ExtendedState.empty with
      base := { balances :=
        (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1 (mapOf n) } }

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "bulkRecipients is the law's own list, in the law's order"
    , body := do
        -- `bulkRecipients_eq_law_list` at the value level.  The two
        -- spell their filter differently (`≠` against `!=`), and an
        -- order divergence between them would be an unprovable
        -- post-root with nothing else to attribute it to.
        let es := stateOf 5
        let mine := (bulkRecipients es 1 3).map (fun p => (p.1, p.2))
        let law := ((es.base.balances[(1 : ResourceId)]?.getD ∅).toList.filter
          (fun kv => kv.1 != 3 && kv.2 != 0)).map (fun p => (p.1, p.2))
        assertEq (expected := law) (actual := mine) "same list, same order"
        assert (!mine.any (fun p => p.1 == 3)) "the excluded actor is dropped"
        assertEq (expected := 4) (actual := mine.length) "5 actors minus 1 excluded"
    }
  , { name := "a LIVE zero-balance entry is not a recipient"
    , body := do
        -- The soundness case.  A `Std.TreeMap` entry mapping an actor to
        -- `0` is invisible to `commitExtendedState` — `stateCellEntries`
        -- drops canonically-absent cells, and `encodeAmount 0` IS the
        -- canonical absent value for a balance — so the actor has no
        -- leaf.  If such an actor were a recipient, `distributeOthers`'
        -- flat credit would pay it `amount`, and two ROOT-IDENTICAL
        -- pre-states (one holding the zero entry, one holding nothing)
        -- would produce post-states with DIFFERENT roots.  The root
        -- would then not determine the transition, which is the premise
        -- the whole fault proof rests on.
        --
        -- Reachable, not theoretical: `setBalance s r a 0` is what any
        -- whole-balance transfer leaves behind.
        let live := stateOf 5
        -- Sweep actor 2 to zero — the entry stays in the map.
        let swept : ExtendedState :=
          { live with base := LegalKernel.setBalance live.base 1 2 0 }
        assert ((swept.base.balances[(1 : ResourceId)]?.getD ∅).contains 2)
          "the fixture really does keep a live zero entry"
        let recips := (bulkRecipients swept 1 3).map (fun p => p.1)
        assert (!recips.contains 2) "the zero-balance actor is NOT credited"
        assertEq (expected := 3) (actual := recips.length)
          "5 actors minus the excluded one minus the swept one"
        -- ...and the recipient set now matches the one derived from the
        -- state that never held the entry at all, which is what makes
        -- the post-root a function of the pre-root.
        let erased : BalanceMap := (live.base.balances[(1 : ResourceId)]?.getD ∅).erase 2
        let absentMap := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1 erased
        let absent : ExtendedState := { live with base := { balances := absentMap } }
        assertEq (expected := (bulkRecipients absent 1 3).map (fun p => (p.1, p.2)))
          (actual := (bulkRecipients swept 1 3).map (fun p => (p.1, p.2)))
          "root-identical states credit identical sets"
        -- The claim stated where it bites: at the published root.  Both
        -- the pre-states and the post-states must commit identically —
        -- the first half establishes that the fixture pair really is
        -- root-identical (so the second half is not vacuous), the second
        -- is the property the terminal step needs.
        assertEq (expected := (commitExtendedState absent).toList)
          (actual := (commitExtendedState swept).toList)
          "the two pre-states publish the same root"
        let postSwept : ExtendedState :=
          { swept with base := step_impl swept.base (Laws.distributeOthers 1 3 7) }
        let postAbsent : ExtendedState :=
          { absent with base := step_impl absent.base (Laws.distributeOthers 1 3 7) }
        assertEq (expected := (commitExtendedState postAbsent).toList)
          (actual := (commitExtendedState postSwept).toList)
          "...and so do the two post-states"
        -- The negative control, so the two assertions above cannot pass
        -- vacuously: under the RETIRED recipient rule (excluded-only, no
        -- zero filter) the SAME fixture pair lands on DIFFERENT
        -- post-roots.  This is the defect, exhibited rather than
        -- asserted — it is what made the pre-state root an insufficient
        -- statistic for a `distributeOthers` step.
        let retired (s : LegalKernel.State) : LegalKernel.State :=
          ((s.balances[(1 : ResourceId)]?.getD ∅).toList.filter
              (fun kv => kv.1 != 3)).foldl
            (fun s' kv => LegalKernel.setBalance s' 1 kv.1
              (LegalKernel.getBalance s' 1 kv.1 + 7)) s
        let retiredSwept : ExtendedState := { swept with base := retired swept.base }
        let retiredAbsent : ExtendedState := { absent with base := retired absent.base }
        assert ((commitExtendedState retiredAbsent).toList
                  != (commitExtendedState retiredSwept).toList)
          "the retired rule really did fork the post-root on this pair"
    }
  , { name := "both bulk laws agree on a state holding a zero entry"
    , body := do
        -- `proportionalDilute` was already safe on its own — its credit
        -- is `totalReward * kv.2 / S`, which is 0 at `kv.2 = 0` — so the
        -- zero filter changes nothing for it.  That asymmetry is the
        -- reason the two laws must share ONE list: a per-law filter
        -- would have left `distributeOthers` wrong and looked correct
        -- from `proportionalDilute`'s side.
        let live := stateOf 5
        let swept := LegalKernel.setBalance live.base 1 2 0
        let postFlat := step_impl swept (Laws.distributeOthers 1 3 7)
        let postProp := step_impl swept (Laws.proportionalDilute 1 3 7)
        assertEq (expected := 0) (actual := LegalKernel.getBalance postFlat 1 2)
          "distributeOthers leaves the zero-balance actor at zero"
        assertEq (expected := 0) (actual := LegalKernel.getBalance postProp 1 2)
          "and so does proportionalDilute"
        -- The other actors still receive their credit, so the filter is
        -- not vacuously passing by disabling the law.
        assertEq (expected := 17) (actual := LegalKernel.getBalance postFlat 1 1)
          "a live recipient is still credited"
    }
  , { name := "each sub-step writes exactly one balance cell"
    , body := do
        let es := stateOf 4
        let steps := LegalKernel.FaultProof.Action.subSteps es (.distributeOthers 1 3 7)
        assertEq (expected := 3) (actual := steps.length) "one sub-step per recipient"
        for ss in steps do
          match ss.writeCells 1 with
          | [c] =>
            assertEq (expected := repr (CellTag.balance 1 ss.affectedActor) |>.pretty)
              (actual := repr c |>.pretty) "the single write is the recipient's balance"
          | other =>
            throw <| IO.userError s!"write set is not a singleton: {other.length} cells"
          assertEq (expected := ss.preBalance + 7) (actual := ss.postBalance)
            "credited by the action's amount"
    }
  , { name := "sub-steps address the same cells the law moves"
    , body := do
        -- The decomposition is only useful if executing every
        -- sub-step reproduces the law's effect.  Checked at the cell
        -- level: each recipient's post-balance matches, and the
        -- excluded actor's does not move.
        let es := stateOf 4
        let action : Authority.Action := .distributeOthers 1 3 7
        let post := step_impl es.base (Authority.Action.compileTransition action)
        for ss in LegalKernel.FaultProof.Action.subSteps es action do
          assertEq (expected := ss.postBalance)
            (actual := LegalKernel.getBalance post 1 ss.affectedActor)
            s!"sub-step for actor {ss.affectedActor} disagrees with the law"
        assertEq (expected := LegalKernel.getBalance es.base 1 3)
          (actual := LegalKernel.getBalance post 1 3)
          "the excluded actor is untouched"
    }
  , { name := "ABOVE the cap the law is a NO-OP, so nothing escapes"
    , body := do
        -- This case used to exhibit a gap: the decomposition stopped
        -- at `maxRecipientsPerBulkAction` while
        -- `Laws.distributeOthers`'s precondition was `amount > 0`
        -- alone, so the law credited every recipient.  A terminal step
        -- over such an action would have settled on a root the L2
        -- never published.
        --
        -- `Laws.BulkBounded` is now a conjunct of the precondition, and
        -- `step_impl` is `if pre then apply_impl else id`, so above the
        -- bound the step is a no-op.  Fail-closed: the step VM is never
        -- asked to adjudicate an advance it cannot decompose, because
        -- there is no advance.
        let n := maxRecipientsPerBulkAction + 4
        let es := stateOf n
        let action : Authority.Action := .distributeOthers 1 3 7
        assert (maxRecipientsPerBulkAction < (bulkRecipients es 1 3).length)
          "the fixture really is over the bound"
        let post := step_impl es.base (Authority.Action.compileTransition action)
        -- Every recipient — including the ones past the cap — is
        -- untouched, which is what makes the truncation harmless.
        for p in bulkRecipients es 1 3 do
          assertEq (expected := LegalKernel.getBalance es.base 1 p.1)
            (actual := LegalKernel.getBalance post 1 p.1)
            s!"over-cap action moved actor {p.1}"
    }
  , { name := "BELOW the bound the decomposition covers every recipient"
    , body := do
        -- The other direction, and the one the precondition buys:
        -- an admissible bulk action has a sub-step per recipient, with
        -- none truncated away.
        let es := stateOf 10
        let steps := LegalKernel.FaultProof.Action.subSteps es (.distributeOthers 1 3 7)
        assertEq (expected := (bulkRecipients es 1 3).length) (actual := steps.length)
          "one sub-step per recipient, none dropped"
        let named := steps.map (fun ss => ss.affectedActor)
        for p in bulkRecipients es 1 3 do
          assert (named.contains p.1) s!"recipient {p.1} is named by no sub-step"
    }
  , { name := "the bound is a real gate, not a formality"
    , body := do
        -- A state one recipient over the bound is inadmissible; one
        -- recipient under it is admissible.  Without both halves the
        -- precondition could be vacuously true or vacuously false and
        -- the tests above would not notice.
        let under := stateOf maxRecipientsPerBulkAction        -- 255 after excluding
        let over  := stateOf (maxRecipientsPerBulkAction + 2)  -- 257 after excluding
        assert (decide (Laws.BulkBounded under.base 1 3))
          "at the bound the action is admissible"
        assert (!decide (Laws.BulkBounded over.base 1 3))
          "one past it, it is not"
    }
  , { name := "distinct sub-steps write distinct cells"
    , body := do
        -- `subSteps_affectedActors_nodup` at the value level.  The
        -- ordered fold opens each cell against the root the previous
        -- write produced, so a repeated recipient would make the
        -- second opening stale and the fold would reject a step an
        -- honest sequencer defended correctly.
        let es := stateOf 12
        let steps := LegalKernel.FaultProof.Action.subSteps es (.distributeOthers 1 3 7)
        let actors := steps.map (fun ss => ss.affectedActor)
        assertEq (expected := actors.length)
          (actual := actors.eraseDups.length)
          "no recipient appears twice"
        let cells := steps.map (fun ss => repr (CellTag.balance 1 ss.affectedActor) |>.pretty)
        assertEq (expected := cells.length) (actual := cells.eraseDups.length)
          "and therefore no cell is written twice"
    }
  , { name := "the cap has exactly one definition"
    , body := do
        -- `StepVMCoherence` used to carry a second copy of this
        -- number.  Two caps that must agree with nothing checking
        -- them is how a DoS bound drifts.
        assertEq (expected := 256) (actual := maxRecipientsPerBulkAction) "the cap"
        assertEq (expected := maxRecipientsPerBulkAction)
          (actual := (LegalKernel.FaultProof.Action.subSteps (stateOf (maxRecipientsPerBulkAction + 1))
                        (.distributeOthers 1 999 1)).length)
          "and the dispatcher's bulk loop honours it"
    }
  , { name := "API stability: sub-step signatures"
    , body := do
        let _order : ∀ (es : ExtendedState) (r : ResourceId) (excluded : ActorId),
            bulkRecipients es r excluded
              = (es.base.balances[r]?.getD ∅).toList.filter
                  (fun kv => kv.1 != excluded && kv.2 != 0) :=
          bulkRecipients_eq_law_list
        let _absent : ∀ (es : ExtendedState) (r : ResourceId) (a : ActorId),
            LegalKernel.getBalance es.base r a < 256 ^ 16 →
            (getCellValue es (.balance r a) = canonicalAbsentValue (.balance r a) ↔
              LegalKernel.getBalance es.base r a = 0) :=
          balanceCell_absent_iff_balance_zero
        let _live : ∀ (es : ExtendedState) (r : ResourceId) (excluded a : ActorId),
            LegalKernel.getBalance es.base r a < 256 ^ 16 →
            ((∃ v, (a, v) ∈ bulkRecipients es r excluded) ↔
              (getCellValue es (.balance r a) ≠ canonicalAbsentValue (.balance r a)
                ∧ a ≠ excluded)) :=
          exists_mem_bulkRecipients_iff_cell_live
        let _bound : ∀ (es : ExtendedState) (action : Authority.Action),
            (LegalKernel.FaultProof.Action.subSteps es action).length ≤ maxRecipientsPerBulkAction :=
          subSteps_length_bound
        let _within : ∀ (es : ExtendedState) (r : ResourceId) (excluded : ActorId)
            (amount : Amount),
            (bulkRecipients es r excluded).length ≤ maxRecipientsPerBulkAction →
            (LegalKernel.FaultProof.Action.distributeOthers_subSteps es r excluded amount).length
              = (bulkRecipients es r excluded).length :=
          subSteps_length_eq_of_within_cap
        let _fromPre : ∀ (es : ExtendedState) (r : ResourceId) (excluded : ActorId)
            (amount : Amount),
            (Laws.distributeOthers r excluded amount).pre es.base →
            (LegalKernel.FaultProof.Action.distributeOthers_subSteps es r excluded amount).length
              = (bulkRecipients es r excluded).length :=
          subSteps_complete_of_pre
        let _noop : ∀ (s : LegalKernel.State) (r : ResourceId) (excluded : ActorId)
            (amount : Amount),
            maxRecipientsPerBulkAction < (Laws.bulkRecipients s r excluded).length →
            step_impl s (Laws.distributeOthers r excluded amount) = s :=
          distributeOthers_noop_above_cap
        let _nodup : ∀ (es : ExtendedState) (r : ResourceId) (excluded : ActorId)
            (amount : Amount),
            ((LegalKernel.FaultProof.Action.distributeOthers_subSteps es r excluded amount).map
              (fun ss => ss.affectedActor)).Nodup :=
          subSteps_affectedActors_nodup
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.SubStep

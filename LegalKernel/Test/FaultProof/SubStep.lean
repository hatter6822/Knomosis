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

The load-bearing case is the last one.  `maxRecipientsPerBulkAction`
truncates the decomposition; `Laws.distributeOthers`'s precondition is
`amount > 0` alone, so the LAW truncates nothing.  Above the cap the
two disagree, and a bulk action the game cannot decompose is one it
cannot adjudicate.  That divergence is exhibited here rather than
described, so it cannot quietly stop being true — in either direction.
-/

import LegalKernel.FaultProof.SubStep
import LegalKernel.Laws.DistributeOthers
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
          (fun kv => kv.1 != 3)).map (fun p => (p.1, p.2))
        assertEq (expected := law) (actual := mine) "same list, same order"
        assert (!mine.any (fun p => p.1 == 3)) "the excluded actor is dropped"
        assertEq (expected := 4) (actual := mine.length) "5 actors minus 1 excluded"
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
  , { name := "ABOVE the cap the decomposition is a PROPER PREFIX of the law"
    , body := do
        -- The gap, exhibited.  `maxRecipientsPerBulkAction` truncates
        -- the sub-steps; `Laws.distributeOthers`'s precondition is
        -- `amount > 0` alone, so the law credits everyone.  A bulk
        -- action with more recipients than the cap therefore has a
        -- post-state the game cannot reach — it would settle on a root
        -- the L2 never published.
        --
        -- The fix belongs in the ACTION layer (a recipient bound in
        -- admission, or in the law's precondition), not here: an
        -- action the L1 cannot adjudicate should not be admissible on
        -- L2.  Recorded in docs/audits/19-findings-and-followups.md.
        let n := maxRecipientsPerBulkAction + 4
        let es := stateOf n
        let action : Authority.Action := .distributeOthers 1 3 7
        let steps := LegalKernel.FaultProof.Action.subSteps es action
        assertEq (expected := maxRecipientsPerBulkAction) (actual := steps.length)
          "the decomposition stops at the cap"
        assertEq (expected := n - 1) (actual := (bulkRecipients es 1 3).length)
          "while the law's own list does not"
        -- And the law really does credit an actor past the cap that no
        -- sub-step names.
        let post := step_impl es.base (Authority.Action.compileTransition action)
        let named := steps.map (fun ss => ss.affectedActor)
        let missed := (bulkRecipients es 1 3).filter (fun p => !named.contains p.1)
        assert (!missed.isEmpty) "some recipient is named by no sub-step"
        match missed.head? with
        | some p =>
          assert (LegalKernel.getBalance post 1 p.1 != LegalKernel.getBalance es.base 1 p.1)
            "and the law moved that recipient's balance anyway"
        | none => throw <| IO.userError "unreachable: missed is non-empty"
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
              = (es.base.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded) :=
          bulkRecipients_eq_law_list
        let _bound : ∀ (es : ExtendedState) (action : Authority.Action),
            (LegalKernel.FaultProof.Action.subSteps es action).length ≤ maxRecipientsPerBulkAction :=
          subSteps_length_bound
        let _within : ∀ (es : ExtendedState) (r : ResourceId) (excluded : ActorId)
            (amount : Amount),
            (bulkRecipients es r excluded).length ≤ maxRecipientsPerBulkAction →
            (LegalKernel.FaultProof.Action.distributeOthers_subSteps es r excluded amount).length
              = (bulkRecipients es r excluded).length :=
          subSteps_length_eq_of_within_cap
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.SubStep

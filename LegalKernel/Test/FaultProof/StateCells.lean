-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.StateCells — value-level tests for the
cell view of an `ExtendedState` and its SMT root.

The load-bearing property is COVERAGE: a cell the enumeration
misses is a field the SMT root does not bind, and therefore a field
the fault-proof game could not adjudicate after the root is
swapped.  `stateCells_covers_every_kind` is the mechanisation of
that obligation.
-/

import LegalKernel.FaultProof.StateCells
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.StateCells

/-- A state with at least one live entry in every keyed sub-state,
    so the enumeration has something to find for each kind. -/
def populated : ExtendedState :=
  let base : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    ((∅ : BalanceMap).insert 7 100) }
  { base          := base
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , localPolicies := (∅ : LocalPolicies).insert 7 Authority.LocalPolicy.empty
  , bridge        :=
      { LegalKernel.Bridge.BridgeState.empty with
          nextWdId    := 5
        , ammDisabled := true
          -- `consumed` and `pending` must be LIVE, or the coverage
          -- test below cannot see kinds 4 and 5.  It caught exactly
          -- that when this fixture left them empty.
        , consumed    :=
            (∅ : Std.TreeMap LegalKernel.Bridge.DepositId
                   LegalKernel.Bridge.DepositRecord compare).insert 11
              { resource := 1, userAmount := 40, poolAmount := 10
              , budgetGrant := 2 }
        , pending     :=
            (∅ : Std.TreeMap LegalKernel.Bridge.WithdrawalId
                   LegalKernel.Bridge.PendingWithdrawal compare).insert 4
              { resource := 1
              , recipient := LegalKernel.Bridge.EthAddress.zero
              , amount := 25, l2LogIndex := 9 } }
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 10 3 4 }

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "stateCells_covers_every_kind"
    , body := do
        -- Every `CellTag` constructor must be reachable.  A tag
        -- added to `CellTag` without an arm in `stateCellTags` is a
        -- field inside the state that the SMT root would not bind —
        -- exactly the hole the cell-space completion closed one
        -- layer up, reappearing at the enumeration.
        let tags := stateCellTags populated
        let kinds := tags.map (fun t => t.kindIndex)
        for k in List.range 17 do
          if !(kinds.contains k) then
            throw <| IO.userError
              s!"cell kind {k} is NOT enumerated by stateCellTags — the SMT \
                 root would not bind it, so a dispute turning on it could \
                 not be adjudicated"
    }
  , { name := "stateCellTags enumerates the live keyed entries"
    , body := do
        let tags := stateCellTags populated
        assert (tags.contains (.balance 1 7)) "live balance enumerated"
        assert (tags.contains (.nonce 7)) "live nonce enumerated"
        assert (tags.contains (.registry 7)) "live registry entry enumerated"
        assert (tags.contains (.localPolicy 7)) "live policy enumerated"
        assert (tags.contains (.epochBudget 7)) "live epoch budget enumerated"
        assert (tags.contains (.bridgeConsumed 11)) "live deposit enumerated"
        assert (tags.contains (.bridgePending 4)) "live withdrawal enumerated"
    }
  , { name := "absent entries are not enumerated"
    , body := do
        -- An SMT leaf that is not present reads as the canonical
        -- empty sub-tree, which is what `canonicalAbsentValue`
        -- mirrors.  Enumerating absent cells would change the root
        -- without changing the state.
        let tags := stateCellTags populated
        assert (!(tags.contains (.balance 1 999))) "absent balance not enumerated"
        assert (!(tags.contains (.nonce 999))) "absent nonce not enumerated"
    }
  , { name := "every enumerated cell has a distinct SMT key"
    , body := do
        -- `smtRootListAux` collapses a level holding two entries with
        -- equal keys, so a collision silently changes the root.
        let entries := stateCellEntries populated
        let keys := entries.map (fun e => e.1.toList)
        let rec check : List (List UInt8) → IO Unit
          | [] => pure ()
          | k :: rest => do
            for k' in rest do
              if k == k' then
                throw <| IO.userError
                  "two enumerated cells share an SMT key — the root would \
                   silently drop one of them"
            check rest
        check keys
    }
  , { name := "the SMT root is 32 bytes and deterministic"
    , body := do
        assertEq (expected := 32) (actual := (commitExtendedState populated).size)
          "root width"
        assertEq (expected := (commitExtendedState populated).toList)
          (actual := (commitExtendedState populated).toList)
          "root is stable across calls"
    }
  , { name := "the SMT root binds the AMM kill switch"
    , body := do
        -- The property the seven-component hash already had and the
        -- cell space did not: flipping `ammDisabled` must move the
        -- root.  If it does not, the fault-proof game cannot
        -- adjudicate a dispute about it.
        let flipped : ExtendedState :=
          { populated with
              bridge := { populated.bridge with ammDisabled := false } }
        assert ((commitExtendedState populated).toList
                  != (commitExtendedState flipped).toList)
          "flipping ammDisabled must change the SMT root"
    }
  , { name := "the SMT root binds an actor's epoch budget"
    , body := do
        let inflated : ExtendedState :=
          { populated with
              epochBudgets := populated.epochBudgets.insert 7
                                { lastSeenEpoch := 2, budgetBalance := 999_999 } }
        assert ((commitExtendedState populated).toList
                  != (commitExtendedState inflated).toList)
          "inflating a budget must change the SMT root"
    }
  , { name := "the SMT root binds a balance"
    , body := do
        let moved : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 1 7 101 }
        assert ((commitExtendedState populated).toList
                  != (commitExtendedState moved).toList)
          "changing a balance must change the SMT root"
    }
  ]

end LegalKernel.Test.FaultProof.StateCells

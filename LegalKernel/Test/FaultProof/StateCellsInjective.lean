-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.StateCellsInjective — tests for the
cell-determination chain.

The theorems are conditional on two side conditions and a
collision-freeness hypothesis, so the tests check the side
conditions actually hold on a realistic state (a vacuously
unsatisfiable hypothesis set would make the whole chain
worthless), and that the pieces the proof leans on — enumeration
duplicate-freedom, key distinctness, canonical absence — hold at
the value level too.
-/

import LegalKernel.FaultProof.StateCellsInjective
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.StateCellsInjective

/-- A state with at least one live entry in every keyed sub-state. -/
def populated : ExtendedState :=
  let base : LegalKernel.State :=
    { balances := ((∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    ((∅ : BalanceMap).insert 7 100)).insert 2
                    ((∅ : BalanceMap).insert 7 5) }
  { base          := base
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , localPolicies := (∅ : LocalPolicies).insert 7 Authority.LocalPolicy.empty
  , bridge        :=
      { LegalKernel.Bridge.BridgeState.empty with
          nextWdId    := 5
        , ammDisabled := true
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

/-- Tags that are absent from `populated` in every keyed sub-state. -/
def absentTags : List CellTag :=
  [ .balance 1 999, .balance 99 7, .nonce 999, .registry 999
  , .localPolicy 999, .bridgeConsumed 999, .bridgePending 999
  , .epochBudget 999 ]

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "the tag enumeration is duplicate-free"
    , body := do
        -- `stateCellTags_nodup`'s value-level counterpart.  A repeat
        -- would collapse a level of the SMT and drop a cell from the
        -- root without changing the state.
        let tags := stateCellTags populated
        let rec check : List CellTag → IO Unit
          | [] => pure ()
          | t :: rest => do
            if rest.contains t then
              throw <| IO.userError s!"duplicate cell tag: {repr t}"
            check rest
        check tags
    }
  , { name := "every enumerated tag has a distinct SMT key"
    , body := do
        let tags := stateCellTags populated
        let keys := tags.map (fun t => (smtCellKey t).toList)
        let rec checkKeys : List (List UInt8) → IO Unit
          | [] => pure ()
          | k :: rest => do
            if rest.contains k then
              throw <| IO.userError "two enumerated cells share an SMT key"
            checkKeys rest
        checkKeys keys
    }
  , { name := "the well-formedness side conditions hold on a real state"
    , body := do
        -- The determination theorem is conditional on
        -- `StateCellsWellFormed`.  If no realistic state satisfied
        -- it, the theorem would be worthless — so check it rather
        -- than assume it.
        let bound : Nat := 256 ^ 8
        for t in stateCellTags populated do
          let (_, keyA, keyB) := t.flatKey
          if keyA ≥ 256 ^ 32 || keyB ≥ 256 ^ 32 then
            throw <| IO.userError s!"cell key out of the 2^256 word: {repr t}"
          if (getCellValue populated t).size ≥ bound then
            throw <| IO.userError s!"cell value exceeds the CBE head: {repr t}"
    }
  , { name := "an unenumerated cell reads the canonical absent value"
    , body := do
        -- `getCellValue_of_not_mem`.  This is what lets the
        -- determination theorem conclude for tags live in neither
        -- state, and it is the contract the SMT's canonical empty
        -- sub-tree relies on.
        let tags := stateCellTags populated
        for t in absentTags do
          if tags.contains t then
            throw <| IO.userError s!"fixture error: {repr t} is enumerated"
          assertEq (expected := (canonicalAbsentValue t).toList)
            (actual := (getCellValue populated t).toList)
            s!"absent cell {repr t}"
    }
  , { name := "live entries in every keyed sub-state are enumerated"
    , body := do
        let tags := stateCellTags populated
        assert (tags.contains (.nonce 7)) "nonce"
        assert (tags.contains (.registry 7)) "registry"
        assert (tags.contains (.localPolicy 7)) "localPolicy"
        assert (tags.contains (.bridgeConsumed 11)) "bridgeConsumed"
        assert (tags.contains (.bridgePending 4)) "bridgePending"
        assert (tags.contains (.epochBudget 7)) "epochBudget"
        assert (tags.contains (.balance 1 7)) "balance, resource 1"
        assert (tags.contains (.balance 2 7)) "balance, resource 2"
    }
  , { name := "a present-empty registry key is not an absent one"
    , body := do
        -- The distinction the CBE byte-string head buys, and the
        -- reason the determination theorem can speak about registry
        -- cells at all: registration is an admissibility gate, so
        -- "registered with the empty key" and "not registered" are
        -- different states and must be different cells.
        let withEmpty : ExtendedState :=
          { populated with registry := populated.registry.insert 8 ByteArray.empty }
        assert ((getCellValue withEmpty (.registry 8)).toList
                  != (getCellValue populated (.registry 8)).toList)
          "present-empty must differ from absent"
        assert ((commitExtendedStateSmt withEmpty).toList
                  != (commitExtendedStateSmt populated).toList)
          "and must move the root"
    }
  , { name := "the cell-key pre-image enumeration covers every tag"
    , body := do
        -- `stateCellKeyPreimages` is the finite set the key
        -- injectivity step applies `CollisionFreeOn` to; a tag whose
        -- pre-image it omitted would leave that step unusable.
        let n₁ := (stateCellTags populated).length
        assertEq (expected := 2 * n₁)
          (actual := (stateCellKeyPreimages populated populated).length)
          "one pre-image per tag on each side"
    }
  , { name := "API stability: cell-determination theorem signatures"
    , body := do
        let _nodup : ∀ (es : ExtendedState),
            (stateCellTags es).Pairwise (· ≠ ·) := stateCellTags_nodup
        let _absent : ∀ (es : ExtendedState) (t : CellTag),
            t ∉ stateCellTags es → getCellValue es t = canonicalAbsentValue t :=
          getCellValue_of_not_mem
        let _perm : ∀ (es₁ es₂ : ExtendedState),
            StateCellsWellFormed es₁ → StateCellsWellFormed es₂ →
            LegalKernel.Bridge.CollisionFreeOn
              (stateCommitSmtPreimages es₁ es₂) LegalKernel.Runtime.hashBytes →
            commitExtendedStateSmt es₁ = commitExtendedStateSmt es₂ →
            (stateCellEntries es₁).Perm (stateCellEntries es₂) :=
          stateCellEntries_perm_of_commitSmt_eq
        let _det : ∀ (es₁ es₂ : ExtendedState),
            StateCellsWellFormed es₁ → StateCellsWellFormed es₂ →
            LegalKernel.Bridge.CollisionFreeOn
              (stateCommitSmtPreimages es₁ es₂) LegalKernel.Runtime.hashBytes →
            commitExtendedStateSmt es₁ = commitExtendedStateSmt es₂ →
            ∀ t : CellTag, getCellValue es₁ t = getCellValue es₂ t :=
          commitExtendedStateSmt_determines_cells
        let _keyinj : ∀ (t₁ t₂ : CellTag), t₁.KeyBounded → t₂.KeyBounded →
            cellKeyPreimage t₁ = cellKeyPreimage t₂ → t₁ = t₂ :=
          cellKeyPreimage_injective
        let _flat : ∀ (t₁ t₂ : CellTag), t₁.flatKey = t₂.flatKey → t₁ = t₂ :=
          CellTag.flatKey_injective
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.StateCellsInjective

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
        assert ((commitExtendedState withEmpty).toList
                  != (commitExtendedState populated).toList)
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
  , { name := "an absent cell opens against the published root"
    , body := do
        -- The case a step hits constantly: crediting a receiver who
        -- holds no balance yet.  An absent cell has an EMPTY
        -- sub-tree beneath its key, so its opening walks from the
        -- canonical empty leaf.
        let root := commitExtendedState populated
        for t in absentTags do
          let p := buildStateCellProof populated t
          assertEq (expected := true)
            (actual := verifyStateCellProof root t (getCellValue populated t) p)
            s!"absent cell opens: {repr t}"
    }
  , { name := "NEGATIVE CONTROL: the present-style leaf fails for an absent cell"
    , body := do
        -- Why `cellLeaf` has to branch.  Starting the walk from
        -- `leafHash key absentValue` reconstructs a root the tree
        -- does not have, so an opening built that way is rejected —
        -- which is the fail-closed direction, but it means a step VM
        -- that did not branch could never read an absent cell.
        let root := commitExtendedState populated
        for t in absentTags do
          let p := buildStateCellProof populated t
          let naive := smtWalkFrom (leafHash (smtCellKey t) (getCellValue populated t))
                         (smtCellKey t) p
          assert (naive.toList != root.toList)
            s!"present-style leaf must NOT reach the root for {repr t}"
    }
  , { name := "a live cell opens against the published root"
    , body := do
        let root := commitExtendedState populated
        for t in [CellTag.balance 1 7, .nonce 7, .registry 7, .epochBudget 7,
                  .bridgeConsumed 11, .bridgePending 4, .bridgeNextWdId] do
          let p := buildStateCellProof populated t
          assertEq (expected := true)
            (actual := verifyStateCellProof root t (getCellValue populated t) p)
            s!"live cell opens: {repr t}"
    }
  , { name := "a live-but-zero balance is canonicalised out of the root"
    , body := do
        -- The reason `stateCellEntries` filters canonically-absent
        -- values.  `setBalance s r a 0` leaves a LIVE map entry whose
        -- value is `encodeAmount 0` — reachable the moment a sender
        -- transfers their whole balance — and without the filter the
        -- verifier could not decide present-vs-absent from the value.
        let zeroed : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 3 9 0 }
        assert ((stateCellTags zeroed).contains (.balance 3 9))
          "the zero balance IS a live map entry"
        assertEq (expected := (canonicalAbsentValue (CellTag.balance 3 9)).toList)
          (actual := (getCellValue zeroed (.balance 3 9)).toList)
          "and its value is the canonical absent one"
        assertEq (expected := (commitExtendedState populated).toList)
          (actual := (commitExtendedState zeroed).toList)
          "so it must not move the root"
        -- And it opens as an absent cell.
        let p := buildStateCellProof zeroed (.balance 3 9)
        assertEq (expected := true)
          (actual := verifyStateCellProof (commitExtendedState zeroed)
                       (.balance 3 9) (getCellValue zeroed (.balance 3 9)) p)
          "and opens through the absent path"
    }
  , { name := "a write lands on the post-state's published root"
    , body := do
        -- The §4 primitive: the L1 holds a root and an opening, not a
        -- state, and re-walks the opening from the new leaf.  What it
        -- gets must be the root the sequencer publishes.
        let t : CellTag := .balance 1 7
        let post : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 1 7 60 }
        let p := buildStateCellProof populated t
        assertEq (expected := (commitExtendedState post).toList)
          (actual := (updateStateCellRoot t (getCellValue post t) p).toList)
          "the re-walked root is the post-state's root"
    }
  , { name := "a write that empties a cell lands on the post root too"
    , body := do
        -- The absent branch of `cellLeaf` at write time: sweeping a
        -- balance to zero removes the key from the canonicalised
        -- entry list, so the new leaf is the empty one.  A step VM
        -- that always wrote `leafHash` would compute a root no state
        -- has — and `reclaimAmmReserves` does exactly this sweep.
        let t : CellTag := .balance 2 7
        let post : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 2 7 0 }
        assertEq (expected := (canonicalAbsentValue t).toList)
          (actual := (getCellValue post t).toList)
          "the swept cell reads as canonically absent"
        let p := buildStateCellProof populated t
        assertEq (expected := (commitExtendedState post).toList)
          (actual := (updateStateCellRoot t (getCellValue post t) p).toList)
          "and the write still lands on the post-state's root"
    }
  , { name := "a two-write fold lands on the two-write post root"
    , body := do
        let t₁ : CellTag := .balance 1 7
        let t₂ : CellTag := .balance 2 7
        let es₁ : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 1 7 60 }
        let es₂ : ExtendedState :=
          { es₁ with base := LegalKernel.setBalance es₁.base 2 7 0 }
        -- The second opening is built against the state the FIRST
        -- write produced, not against the pre-state.
        let writes : List StateCellWrite :=
          [ (t₁, getCellValue populated t₁, getCellValue es₁ t₁,
             buildStateCellProof populated t₁)
          , (t₂, getCellValue es₁ t₂, getCellValue es₂ t₂,
             buildStateCellProof es₁ t₂) ]
        assertEq (expected := some (commitExtendedState es₂).toList)
          (actual := (foldStateCellWrites (commitExtendedState populated)
                        writes).map ByteArray.toList)
          "the fold lands on the post-state's root"
    }
  , { name := "NEGATIVE CONTROL: a stale opening fails the fold"
    , body := do
        -- Openings go stale the moment a write lands under a shared
        -- ancestor.  This is why the bundle is folded strictly in
        -- order and each opening re-checked: a responder replaying a
        -- pre-root opening after an earlier write must be rejected,
        -- not silently folded into a wrong root.
        let t₁ : CellTag := .balance 1 7
        let t₂ : CellTag := .balance 2 7
        let es₁ : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 1 7 60 }
        let es₂ : ExtendedState :=
          { es₁ with base := LegalKernel.setBalance es₁.base 2 7 0 }
        let stale : List StateCellWrite :=
          [ (t₁, getCellValue populated t₁, getCellValue es₁ t₁,
             buildStateCellProof populated t₁)
          , (t₂, getCellValue es₁ t₂, getCellValue es₂ t₂,
             buildStateCellProof populated t₂) ]
        assertEq (expected := (none : Option (List UInt8)))
          (actual := (foldStateCellWrites (commitExtendedState populated)
                        stale).map ByteArray.toList)
          "the stale second opening is rejected"
    }
  , { name := "NON-VACUITY: the absent-cell hypothesis holds on a zeroed cell"
    , body := do
        -- `canonicalSiblings_verifies_absent` scopes its key-injectivity
        -- hypothesis to the tags that CONTRIBUTE an entry.  Quantifying
        -- over every enumerated tag would be unsatisfiable here, because
        -- `setBalance s r a 0` leaves the tag enumerated while its value
        -- reads canonically absent — so the theorem would be vacuous on
        -- a state a single whole-balance transfer produces.
        let t : CellTag := .balance 1 7
        let zeroed : ExtendedState :=
          { populated with base := LegalKernel.setBalance populated.base 1 7 0 }
        assert ((stateCellTags zeroed).contains t)
          "the zeroed cell is still enumerated"
        assertEq (expected := (canonicalAbsentValue t).toList)
          (actual := (getCellValue zeroed t).toList)
          "and reads as canonically absent"
        -- The scoped hypothesis: every CONTRIBUTING tag has a different
        -- key.  Checked exhaustively over the enumeration.
        for t' in stateCellTags zeroed do
          if getCellValue zeroed t' != canonicalAbsentValue t' then
            assert (smtCellKey t' != smtCellKey t)
              s!"contributing tag shares the zeroed cell's key: {repr t'}"
        -- And the opening still verifies, through the absent branch.
        assertEq (expected := true)
          (actual := verifyStateCellProof (commitExtendedState zeroed) t
                       (getCellValue zeroed t) (buildStateCellProof zeroed t))
          "the zeroed cell opens as absent"
    }
  , { name := "API stability: cell-update theorem signatures"
    , body := do
        let _upd : ∀ (es es' : ExtendedState) (t : CellTag) (canon : SmtCellProof),
            expandSiblings canon
              = canonicalSiblings smtDepth (stateCellEntries es) (smtCellKey t) →
            dropKey (stateCellEntries es) (smtCellKey t)
              = dropKey (stateCellEntries es') (smtCellKey t) →
            BitsDistinctBelow smtDepth (stateCellEntries es') →
            (∀ t' ∈ stateCellTags es', getCellValue es' t' ≠ canonicalAbsentValue t' →
               smtCellKey t' ≠ smtCellKey t) →
            updateStateCellRoot t (getCellValue es' t) canon = commitExtendedState es' :=
          updateStateCellRoot_eq_commit_of_canonical
        let _indep : ∀ (es : ExtendedState) (t : CellTag) (newValue : ByteArray)
            (proof₁ proof₂ : SmtCellProof),
            LegalKernel.Bridge.CollisionFreeOn
              (smtWalkPairPreimages (cellLeaf t (getCellValue es t)) (smtCellKey t)
                proof₁ proof₂) LegalKernel.Runtime.hashBytes →
            verifyStateCellProof (commitExtendedState es) t (getCellValue es t) proof₁ = true →
            verifyStateCellProof (commitExtendedState es) t (getCellValue es t) proof₂ = true →
            updateStateCellRoot t newValue proof₁ = updateStateCellRoot t newValue proof₂ :=
          updateStateCellRoot_proof_independent
        let _fold : ∀ (chain : CellWriteChain) (es : ExtendedState),
            ChainCoherent es chain →
            foldStateCellWrites (commitExtendedState es) (chainWrites es chain)
              = some (commitExtendedState (chainLast es chain)) :=
          foldStateCellWrites_eq_commit_of_coherent
        let _single : ∀ (e e' : SmtEntries) (key : ByteArray),
            dropKey e key = dropKey e' key →
            ((canonicalSiblings smtDepth e key).zip
                (keyBitsUpTo smtDepth key)).foldl stepPair
              (smtRootListAux 0 (bucketAt smtDepth e' key))
              = smtRootListAux smtDepth e' :=
          smtRootListAux_update_single
        pure ()
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
            commitExtendedState es₁ = commitExtendedState es₂ →
            (stateCellEntries es₁).Perm (stateCellEntries es₂) :=
          stateCellEntries_perm_of_commitSmt_eq
        let _det : ∀ (es₁ es₂ : ExtendedState),
            StateCellsWellFormed es₁ → StateCellsWellFormed es₂ →
            LegalKernel.Bridge.CollisionFreeOn
              (stateCommitSmtPreimages es₁ es₂) LegalKernel.Runtime.hashBytes →
            commitExtendedState es₁ = commitExtendedState es₂ →
            ∀ t : CellTag, getCellValue es₁ t = getCellValue es₂ t :=
          commitExtendedState_determines_cells
        let _keyinj : ∀ (t₁ t₂ : CellTag), t₁.KeyBounded → t₂.KeyBounded →
            cellKeyPreimage t₁ = cellKeyPreimage t₂ → t₁ = t₂ :=
          cellKeyPreimage_injective
        let _flat : ∀ (t₁ t₂ : CellTag), t₁.flatKey = t₂.flatKey → t₁ = t₂ :=
          CellTag.flatKey_injective
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.StateCellsInjective

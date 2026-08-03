-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.MultiProof — the multiproof wire,
pinned across the stacks.

`SmtMultiVerifier` already agrees with Lean at ONE opened cell, because
that case degenerates to a single-cell opening and
`SmtCellVerifier.recomputeRootFromLeaf` is pinned by
`smt_cell_proof.json`.  That is a real check but it is the degenerate
one: it exercises no merge, so it says nothing about the two things the
multiproof exists for — the merge itself, and the post-order in which
the merged walk consumes its gaps.

This corpus is the non-degenerate pin.  Each probe is a real
`ExtendedState`, a real frontier of two or more cells, the wire Lean
builds from it, and BOTH roots the wire serves: the pre-state's, which
the L1 checks its input against, and the post-state's, which is the
answer.  The Solidity consumer folds the same bytes and must reach the
same two values.

The probes are chosen for what they discriminate:

  * `single` — the degenerate case, so a regression that broke only the
    merge is still visible against the m = 1 path;
  * `pair` / `triple` — merges at two different depths;
  * `absent` — a frontier including a cell the state does NOT hold,
    whose leaf is the canonical empty one, and whose step WRITES it.  A
    step reads and creates absent cells constantly (crediting a fresh
    actor), and a walk that mishandled them would still pass every
    present-only probe;
  * `wide` — seven cells across five kinds, with the write running the
    other way: a balance swept to zero, so a present leaf becomes the
    canonical empty one.  `cellLeaf` branches on absence, so the two
    directions are different code paths and neither implies the other;
  * `allOpened` — every live cell of a deliberately minimal state, so
    the gap mask is all zeros and the sibling list is empty.  It is the
    complement of the other five: they exercise "draw this sibling from
    the wire" at every gap that carries one, and this exercises "take
    the canonical empty sub-tree" at every gap there is.
-/

import LegalKernel.FaultProof.MultiProof
import LegalKernel.FaultProof.CellStore
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test
open LegalKernel.Test.Bridge.CrossCheck

namespace LegalKernel.Test.Bridge.CrossCheck.MultiProof

/-- The fixture this suite owns. -/
def fixtureName : String := "smt_multi_proof.json"

/-- The state the probes open against: at least one live entry in
    every keyed sub-state and every singleton off its canonical absent
    value, plus enough spare balances that a small frontier leaves a
    substantial sibling set behind.

    Both halves matter.  Every kind live is what makes the corpus
    exercise `cellLeaf` on each of the fifteen value shapes; the spare
    balances are what make the *mask* non-trivial.  A state whose only
    live cells are the ones a probe opens produces an all-zero gap mask
    and an empty sibling list, so the "draw this sibling from the wire"
    branch never runs — the first draft of this corpus was exactly that
    sparse and one of its five probes carried zero siblings. -/
def rich : ExtendedState :=
  let st : LegalKernel.State :=
    { balances :=
        ((∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
            (((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 12 7).insert 33 9
              |>.insert 250 1)).insert 2
            (((∅ : BalanceMap).insert 7 5).insert 91 2) }
  { base          := st
  , nonces        := { next := ((∅ : Std.TreeMap ActorId Nonce compare).insert 7 3).insert 8 1 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , localPolicies := (∅ : LocalPolicies).insert 7 Authority.LocalPolicy.empty
  , bridge        :=
      { LegalKernel.Bridge.BridgeState.empty with
          nextWdId              := 5
        , ammDisabled           := true
        , boldCircuitClosed     := true
        , ammReserveEth         := 7_000
        , ammReserveBold        := 3_000
        , boldTvlCap            := 9_000
        , boldTotalLockedValue  := 1_500
        , consumed              :=
            (∅ : Std.TreeMap LegalKernel.Bridge.DepositId
                   LegalKernel.Bridge.DepositRecord compare).insert 11
              { resource := 1, userAmount := 40, poolAmount := 10
              , budgetGrant := 2 }
        , pending               :=
            (∅ : Std.TreeMap LegalKernel.Bridge.WithdrawalId
                   LegalKernel.Bridge.PendingWithdrawal compare).insert 4
              { resource := 1
              , recipient := LegalKernel.Bridge.EthAddress.zero
              , amount := 25, l2LogIndex := 9 } }
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 10 3 4 }

/-- A deliberately minimal state: two live balances and nothing else,
    every singleton at its canonical absent value.  It exists for the
    one probe that opens EVERY live cell, whose gap mask is therefore
    all zeros and whose sibling list is empty — the complementary
    branch to `rich`'s. -/
def sparse : ExtendedState :=
  let st : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    (((∅ : BalanceMap).insert 7 100).insert 8 40) }
  { ExtendedState.empty with base := st }

/-- One probe: a name, the state it opens against, the cells its
    frontier opens, and the single write its step performs. -/
structure Probe where
  /-- The probe's name, for failure messages on both stacks. -/
  name  : String
  /-- The pre-state.  Per-probe rather than shared: the fixture
      publishes only roots, leaves and the wire, so the consumer never
      sees a state and probes are free to disagree about it. -/
  state : ExtendedState
  /-- The cells opened, before deduplication and sorting. -/
  cells : List CellTag
  /-- The cell the step writes.  **Must be one of `cells`.**  A write
      to a cell the wire does not open moves the post-root by an amount
      no sibling in the wire accounts for — `AgreeOffOpened` failing —
      so the fold cannot reach it and the probe would pin nothing.
      That is a real authoring hazard rather than a hypothetical: the
      first draft of this corpus wrote one fixed cell for every probe
      and two of the five did not open it.  Asserted below, not
      assumed. -/
  wrote : CellTag
  /-- The value written, in the reader's own byte form. -/
  value : ByteArray

/-- The probes. -/
def probes : List Probe :=
  [ -- The degenerate case, so a regression that broke only the merge
    -- is still visible against the m = 1 path.
    { name := "single",  state := rich, cells := [.nonce 7]
    , wrote := .nonce 7,        value := natCellValue 9 }
    -- Two balances of one resource: a merge deep in the tree.
  , { name := "pair",    state := rich, cells := [.balance 1 7, .balance 1 8]
    , wrote := .balance 1 7,    value := amountCellValue 55 }
    -- Three cells across two kinds: merges at two different depths.
  , { name := "triple",  state := rich, cells := [.balance 1 7, .balance 1 8, .nonce 7]
    , wrote := .nonce 7,        value := natCellValue 11 }
    -- A frontier including a cell the state does NOT hold, whose leaf
    -- is the canonical empty one -- and the step WRITES it, so the
    -- probe pins the absent -> present transition.
  , { name := "absent",  state := rich, cells := [.balance 1 7, .balance 1 99, .nonce 7]
    , wrote := .balance 1 99,   value := amountCellValue 21 }
    -- Six cells across five kinds, and the write goes the other way: a
    -- balance swept to zero, so a present leaf becomes the canonical
    -- empty one.  `cellLeaf` branches on absence, so the two
    -- directions are different code paths.
  , { name := "wide",    state := rich
    , cells := [.balance 1 7, .balance 1 8, .balance 1 12, .nonce 7,
                .budgetPolicy, .bridgePending 4, .epochBudget 7]
    , wrote := .balance 1 12,   value := amountCellValue 0 }
    -- Every live cell opened: the gap mask is all zeros and the
    -- sibling list is empty, so the walk takes the canonical
    -- empty-subtree branch at every single gap.
    -- `.budgetPolicy` is on the list because `ExtendedState.empty`
    -- carries `.bounded 0 1 0`, which is NOT the canonical absent
    -- `.bounded 0 0 0` -- so even the emptiest state has a live
    -- singleton, and omitting it leaves one sibling on the wire.
  , { name := "allOpened", state := sparse
    , cells := [.balance 1 7, .balance 1 8, .budgetPolicy]
    , wrote := .balance 1 8,    value := amountCellValue 41 }
  ]

/-- The post-state a probe's step reaches.  One write, at a cell the
    probe's own wire opens. -/
def postOf (p : Probe) : ExtendedState := setCell p.state p.wrote p.value

/-- A probe's frontier, the gap levels its wire is indexed by, and the
    wire itself.  Computed in one place so the JSON emitter and the
    tests that check the emitter cannot drift apart — a corpus whose
    self-check recomputes the wire differently from the column it
    publishes checks nothing. -/
def wireOf (p : Probe) : List CellTag × List Nat × SmtMultiProof :=
  let ts      := frontierOf p.cells
  let preOpen := openedOf p.state ts
  let gaps    := multiSiblings smtDepth (stateCellEntries p.state) preOpen
  let levels  := multiGapLevels smtDepth preOpen
  (ts, levels, buildMultiProof levels gaps)

/-- A probe's JSON. -/
def probeJson (p : Probe) : Json :=
  let (ts, levels, wire) := wireOf p
  let post := postOf p
  Json.obj
    [ ("name", Json.str p.name)
    , ("preStateRootHex",  Json.str (hexFromBytes (commitExtendedState p.state)))
    , ("postStateRootHex", Json.str (hexFromBytes (commitExtendedState post)))
    , ("gapCount", Json.num levels.length)
      -- Published rather than left to the consumer to count: forge's
      -- JSON cheatcodes read a path, not an array length, so a
      -- consumer without this column would have to hard-code each
      -- probe's cell count and would then not notice one changing.
    , ("cellCount", Json.num ts.length)
    , ("gapMaskHex", Json.str (hexFromBytes wire.gapMask))
    , ("siblingsHex",
        Json.str (hexFromBytes (wire.siblings.foldl (fun acc s => acc ++ s)
                    (ByteArray.mk #[]))))
    , ("cells", Json.arr (ts.map (fun t =>
        Json.obj
          [ ("smtKeyHex",    Json.str (hexFromBytes (smtCellKey t)))
          , ("preLeafHex",   Json.str (hexFromBytes (cellLeaf t (getCellValue p.state t))))
          , ("postLeafHex",  Json.str (hexFromBytes (cellLeaf t (getCellValue post t)))) ]
        )))
    ]

/-- The fixture. -/
def buildFixture : Json :=
  Json.obj
    [ ("identifier", Json.str "knomosis/smt-multi-proof/v1")
    , ("isKeccak256Linked", Json.bool LegalKernel.Bridge.isKeccak256Linked)
    , ("count", Json.num probes.length)
    , ("probes", Json.arr (probes.map probeJson))
    ]

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "every probe's wire folds to both of its roots"
    , body := do
        -- The Lean side of the pin.  If this fails, the corpus is wrong
        -- and the Solidity consumer would be pinned to a lie.
        for p in probes do
          let (ts, levels, wire) := wireOf p
          let post     := postOf p
          let expanded := expandMultiProof levels wire
          match multiWalk smtDepth (openedOf p.state ts) expanded with
          | none => throw <| IO.userError s!"{p.name}: pre-side walk refused"
          | some (r, rest) =>
              assertEq (expected := (commitExtendedState p.state).toList) (actual := r.toList)
                s!"{p.name}: pre-root"
              assertEq (expected := 0) (actual := rest.length) s!"{p.name}: pre remainder"
          match multiWalk smtDepth (openedOf post ts) expanded with
          | none => throw <| IO.userError s!"{p.name}: post-side walk refused"
          | some (r, rest) =>
              assertEq (expected := (commitExtendedState post).toList) (actual := r.toList)
                s!"{p.name}: post-root"
              assertEq (expected := 0) (actual := rest.length) s!"{p.name}: post remainder"
    }
  , { name := "the probes actually exercise merges"
    , body := do
        -- A corpus of single-cell probes would pin nothing the m = 1
        -- transitive check does not already cover.  Every multi-cell
        -- probe must carry FEWER gaps than one full path per cell —
        -- which is exactly the merge showing up in the arithmetic.
        for p in probes do
          let (ts, levels, _) := wireOf p
          if ts.length > 1 then
            assertEq (expected := true) (actual := levels.length < smtDepth * ts.length)
              s!"{p.name}: merging shows up as fewer gaps"
          else
            assertEq (expected := smtDepth) (actual := levels.length)
              s!"{p.name}: a single cell has one gap per level"
    }
  , { name := "the corpus exercises both gap-mask branches"
    , body := do
        -- A gap either draws its sibling from the wire or takes the
        -- canonical empty sub-tree, and those are different branches on
        -- both stacks.  A corpus that only ever hit one of them would
        -- leave the other unpinned, which is what a sparse state does
        -- by accident.  So: at least one probe must carry siblings, and
        -- at least one must carry none.
        let counts := probes.map (fun p => (wireOf p).2.2.siblings.size)
        assertEq (expected := true) (actual := counts.any (fun n => n > 0))
          "some probe draws siblings from the wire"
        assertEq (expected := true) (actual := counts.any (fun n => n == 0))
          "some probe takes the empty sub-tree at every gap"
        -- And specifically: `allOpened` is the empty-sibling one by
        -- construction (it opens every live cell of `sparse`), while
        -- every `rich` probe leaves live cells unopened.  Pinning which
        -- probe plays which role stops a future edit to `rich` from
        -- silently collapsing the two branches back into one.
        for p in probes do
          let n := (wireOf p).2.2.siblings.size
          if p.name == "allOpened" then
            assertEq (expected := 0) (actual := n) s!"{p.name}: no siblings"
          else
            assertEq (expected := true) (actual := n > 0) s!"{p.name}: some siblings"
    }
  , { name := "every probe writes a cell its own wire opens"
    , body := do
        -- The guard on the authoring hazard `Probe.wrote` documents.  A
        -- probe whose write lands outside its frontier violates
        -- `AgreeOffOpened`, and the fold then CORRECTLY fails to reach
        -- the post-root -- so without this check the symptom is a
        -- root mismatch that reads like a multiproof bug.
        for p in probes do
          assertEq (expected := true)
            (actual := (frontierOf p.cells).contains p.wrote)
            s!"{p.name}: the written cell is on the frontier"
    }
  , { name := "every probe's write actually moves the root"
    , body := do
        -- Otherwise a probe degenerates to pre = post and its
        -- post-root column pins nothing the pre-root column does not.
        -- `wide` is the one at risk: it sweeps a balance to ZERO, and
        -- a zero balance reads back as the canonical absent value --
        -- so if actor 12 held nothing the write would be inert.
        for p in probes do
          assertEq (expected := false)
            (actual := (commitExtendedState p.state).toList
                         == (commitExtendedState (postOf p)).toList)
            s!"{p.name}: the write moves the published root"
    }
  , { name := "the two absence directions are both exercised"
    , body := do
        -- `absent` runs empty -> present and `wide` runs present ->
        -- empty.  `cellLeaf` branches on absence, so these are
        -- different code paths and a corpus carrying only one of them
        -- leaves the other unpinned.
        for p in probes do
          if p.name == "absent" then
            assertEq (expected := (canonicalAbsentValue p.wrote).toList)
              (actual := (getCellValue p.state p.wrote).toList)
              "absent: the written cell starts absent"
            assertEq (expected := false)
              (actual := (getCellValue (postOf p) p.wrote).toList
                          == (canonicalAbsentValue p.wrote).toList)
              "absent: the written cell ends present"
          if p.name == "wide" then
            assertEq (expected := false)
              (actual := (getCellValue p.state p.wrote).toList
                          == (canonicalAbsentValue p.wrote).toList)
              "wide: the written cell starts present"
            assertEq (expected := (canonicalAbsentValue p.wrote).toList)
              (actual := (getCellValue (postOf p) p.wrote).toList)
              "wide: the written cell ends absent"
    }
  , { name := "fixture file write / verify cycle succeeds"
    , body := do
        writeHashDependentFixture fixtureName buildFixture.encodeIndented
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.MultiProof

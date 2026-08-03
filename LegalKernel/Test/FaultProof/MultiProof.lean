-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.MultiProof — the merged walk on a real
state.

`multiWalk_eq_smtRootListAux` says the honest bundle reaches the tree's
root and consumes exactly the siblings it carries.  These tests run it
on a populated `ExtendedState`, which catches definitional drift the
elaborator cannot, and exercise the three things a value-level check
can see and a theorem statement cannot:

  * the walk reaches `commitExtendedState` from cells that include an
    ABSENT one, which is the common case (crediting a fresh actor) and
    the case a present-only formulation would have silently excluded;
  * the wire is SHORTER than the chained encoding for the same cells,
    which is the entire economic claim;
  * a wire one sibling short is REFUSED rather than padded — the
    chained verifier substitutes `PADDING_HASH` and walks on, and the
    length being derivable from the key set is what lets this one say
    no.
-/

import LegalKernel.FaultProof.CellStore
import LegalKernel.FaultProof.MultiProof
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.MultiProof

/-- A state with live entries, so the walk has something to reconstruct. -/
def base : ExtendedState :=
  let st : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    (((∅ : BalanceMap).insert 7 100).insert 8 40) }
  { ExtendedState.empty with base := st }

/-- The cells a `transfer` step opens, plus one the state does NOT hold
    — `balance 1 9` is a fresh actor, whose opening starts from the
    canonical empty leaf rather than a hash of an absent marker. -/
def cells : List CellTag :=
  frontierOf [.balance 1 7, .balance 1 8, .balance 1 9, .nonce 7]

/-- Those cells as opened leaves, with the leaf each one actually has. -/
def opened : List OpenedLeaf :=
  cells.map (fun t => (smtCellKey t, cellLeaf t (getCellValue base t)))

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "the merged walk reaches the published root"
    , body := do
        let entries := stateCellEntries base
        match multiWalk smtDepth opened (multiSiblings smtDepth entries opened) with
        | none => assertEq (expected := "some") (actual := "none") "the walk completes"
        | some (root, rest) =>
            assertEq (expected := (commitExtendedState base).toList)
              (actual := root.toList) "the walk reaches commitExtendedState"
            assertEq (expected := 0) (actual := rest.length)
              "and consumes every sibling it carries"
    }
  , { name := "an absent cell opens like any other"
    , body := do
        -- `balance 1 9` is not in the state, so its entry is dropped
        -- from `stateCellEntries` and its leaf is the canonical empty
        -- one.  A formulation that only handled present cells would
        -- have excluded the commonest step there is.
        assertEq (expected := (canonicalAbsentValue (.balance 1 9)).toList)
          (actual := (getCellValue base (.balance 1 9)).toList) "the cell is absent"
        assertEq (expected := (emptyRootAt 0).toList)
          (actual := (cellLeaf (.balance 1 9) (getCellValue base (.balance 1 9))).toList)
          "and its leaf is the canonical empty one"
    }
  , { name := "the merged wire is shorter than the chained one"
    , body := do
        let entries := stateCellEntries base
        let merged := (multiSiblings smtDepth entries opened).length
        -- The chained encoding carries one full path per opening.
        let chained := opened.foldl
          (fun acc o => acc + (canonicalSiblings smtDepth entries o.1).length) 0
        assertEq (expected := true) (actual := merged < chained)
          "the merged wire is strictly shorter"
        assertEq (expected := smtDepth * opened.length) (actual := chained)
          "the chained wire is one full path per opening"
    }
  , { name := "a wire one sibling short is refused, not padded"
    , body := do
        let entries := stateCellEntries base
        let sibs := multiSiblings smtDepth entries opened
        -- Drop the last sibling.  The chained verifier substitutes
        -- `PADDING_HASH` here and keeps walking; this one runs out and
        -- says so, because the length it expects is a function of the
        -- key set rather than of the wire.
        let short_ := sibs.take (sibs.length - 1)
        assertEq (expected := true)
          (actual := (multiWalk smtDepth opened short_).isNone)
          "a short wire is refused"
        -- ...and a wire with a trailing EXTRA is not silently accepted
        -- either: the walk returns the remainder, and completeness
        -- demands it be empty.
        match multiWalk smtDepth opened (sibs ++ [ByteArray.mk #[0]]) with
        | none => assertEq (expected := "some") (actual := "none") "extra parses"
        | some (_, rest) =>
            assertEq (expected := 1) (actual := rest.length)
              "the extra sibling is left over rather than consumed"
    }
  , { name := "one opened cell is the single-cell opening"
    , body := do
        -- The compatibility pin: at m = 1 the multiproof's sibling list
        -- IS `canonicalSiblings`, so the wire is a widening of
        -- `proofData` rather than a break.
        let _pin : ∀ (d : Nat) (entries : SmtEntries) (k leaf : ByteArray),
            multiSiblings d entries [(k, leaf)] = canonicalSiblings d entries k :=
          multiSiblings_single
        let entries := stateCellEntries base
        let t : CellTag := .nonce 7
        let one : OpenedLeaf := (smtCellKey t, cellLeaf t (getCellValue base t))
        assertEq (expected := (canonicalSiblings smtDepth entries one.1).map ByteArray.toList)
          (actual := (multiSiblings smtDepth entries [one]).map ByteArray.toList)
          "the single-cell wire is the canonical path"
        assertEq (expected := smtDepth)
          (actual := (multiSiblings smtDepth entries [one]).length)
          "and it is one sibling per level"
    }
  , { name := "one wire serves both roots"
    , body := do
        -- M3's claim, run rather than asserted.  A step writes the
        -- signer's nonce; build the wire from the PRE-state and fold
        -- the POST-state's leaves through it.  If the sibling reuse
        -- were unsound this would land somewhere that is not a root.
        let post := setCell base (.nonce 7) (natCellValue 4)
        let ts : List CellTag := frontierOf [.nonce 7]
        let sibs := multiSiblings smtDepth (stateCellEntries base) (openedOf base ts)
        match multiWalk smtDepth (openedOf base ts) sibs with
        | none => assertEq (expected := "some") (actual := "none") "pre side folds"
        | some (r, _) =>
            assertEq (expected := (commitExtendedState base).toList) (actual := r.toList)
              "the pre-values reach the pre-state's root"
        match multiWalk smtDepth (openedOf post ts) sibs with
        | none => assertEq (expected := "some") (actual := "none") "post side folds"
        | some (r, rest) =>
            assertEq (expected := (commitExtendedState post).toList) (actual := r.toList)
              "the post-values reach the POST-state's root, from the same wire"
            assertEq (expected := 0) (actual := rest.length) "and consume it all"
        -- The negative control: the two roots differ, so the test above
        -- is not passing because nothing moved.
        assertEq (expected := true)
          (actual := (commitExtendedState base).toList != (commitExtendedState post).toList)
          "the write moved the root"
    }
  , { name := "the wire ignores the leaves it opens"
    , body := do
        -- `multiSiblings_key_congr` at the value level: same cells,
        -- different state, identical wire.  This is what makes "one
        -- wire, two roots" a sentence about the SAME bytes.
        let post := setCell base (.nonce 7) (natCellValue 4)
        let ts : List CellTag := frontierOf [.nonce 7]
        assertEq
          (expected := (multiSiblings smtDepth (stateCellEntries base)
                          (openedOf base ts)).map ByteArray.toList)
          (actual := (multiSiblings smtDepth (stateCellEntries base)
                          (openedOf post ts)).map ByteArray.toList)
          "the wire is a function of the cells, not their values"
    }
  , { name := "the compressed wire round-trips"
    , body := do
        let entries := stateCellEntries base
        let gaps := multiSiblings smtDepth entries opened
        let levels := multiGapLevels smtDepth opened
        assertEq (expected := gaps.length) (actual := levels.length)
          "one level per gap"
        let wire := buildMultiProof levels gaps
        assertEq (expected := gaps.map ByteArray.toList)
          (actual := (expandMultiProof levels wire).map ByteArray.toList)
          "expand ∘ build is the identity on the gap list"
        -- ...and the walk accepts the expansion, so the compression is
        -- transparent to the verifier.
        match multiWalk smtDepth opened (expandMultiProof levels wire) with
        | none => assertEq (expected := "some") (actual := "none") "the walk completes"
        | some (r, rest) =>
            assertEq (expected := (commitExtendedState base).toList) (actual := r.toList)
              "and reaches the published root"
            assertEq (expected := 0) (actual := rest.length) "consuming it all"
    }
  , { name := "the wire drops the canonical-empty siblings"
    , body := do
        let entries := stateCellEntries base
        let gaps := multiSiblings smtDepth entries opened
        let levels := multiGapLevels smtDepth opened
        let wire := buildMultiProof levels gaps
        -- This is the compression's whole point: a gap whose sibling is
        -- the canonical empty sub-tree costs a cleared bit, not 32
        -- bytes.  On a sparse state that is nearly all of them.
        assertEq (expected := true) (actual := wire.siblings.size < gaps.length)
          "the wire carries fewer siblings than there are gaps"
        assertEq (expected := (levels.length + 7) / 8)
          (actual := wire.gapMask.size) "the mask is one bit per gap"
    }
  , { name := "at one opened cell the gap index is the level"
    , body := do
        -- The compatibility pin, on the WIRE rather than the sibling
        -- list.  A single-cell multiproof has one gap per level in
        -- level order, so its mask is indexed exactly as
        -- `SmtCellProof.bitmask` is — which is what makes the encoding
        -- a widening of `proofData` rather than a break.
        let _pin : ∀ (d : Nat) (k leaf : ByteArray),
            multiGapLevels d [(k, leaf)] = (List.range d).reverse.reverse :=
          multiGapLevels_single
        let t : CellTag := .nonce 7
        let one : OpenedLeaf := (smtCellKey t, cellLeaf t (getCellValue base t))
        assertEq (expected := List.range smtDepth)
          (actual := multiGapLevels smtDepth [one])
          "the gap levels are 0, 1, …, 255 in order"
        let wire := buildMultiProof (multiGapLevels smtDepth [one])
          (multiSiblings smtDepth (stateCellEntries base) [one])
        assertEq (expected := 32) (actual := wire.gapMask.size)
          "so the mask is 32 bytes, exactly as a single-cell proof's is"
    }
  , { name := "the wire's shape is derived, so truncation is refused"
    , body := do
        let entries := stateCellEntries base
        let gaps := multiSiblings smtDepth entries opened
        let levels := multiGapLevels smtDepth opened
        let wire := buildMultiProof levels gaps
        -- The honest wire fits the shape the KEY SET implies.  Nothing
        -- about the wire was consulted to compute that shape.
        assertEq (expected := true) (actual := wire.isWellFormedFor levels)
          "the honest wire is well-formed for its derived levels"
        -- Drop a sibling: the count no longer matches the mask's
        -- popcount.  A single-cell verifier pads here and keeps
        -- walking; this one has a count to check against.
        let shortWire : SmtMultiProof :=
          { gapMask := wire.gapMask, siblings := wire.siblings.pop }
        assertEq (expected := false) (actual := shortWire.isWellFormedFor levels)
          "a wire one sibling short is refused"
        -- Set a padding bit past the last gap: the mask's tail cannot
        -- smuggle a sibling in.
        let padded : SmtMultiProof :=
          { gapMask := setBitmaskBit wire.gapMask (levels.length + 1)
          , siblings := wire.siblings }
        assertEq (expected := false) (actual := padded.isWellFormedFor levels)
          "a bit past the last gap is refused"
        -- The encoding's length is the mask plus 32 per sibling, which
        -- is the shape an L1 validates before walking.
        assertEq (expected := wire.gapMask.size + 32 * wire.siblings.size)
          (actual := wire.toWireBytes.size) "the wire encodes to its declared length"
    }
  , { name := "completeness is pinned at the term level"
    , body := do
        let _pin : ∀ (entries : SmtEntries) (opened : List OpenedLeaf),
            opened ≠ [] → LeavesCoherent smtDepth entries opened →
            BitsDistinctBelow smtDepth opened →
            multiWalk smtDepth opened (multiSiblings smtDepth entries opened)
              = some (smtRootListAux smtDepth entries, []) :=
          multiWalk_eq_smtRootListAux
        let _pinPost : ∀ (es es' : ExtendedState) (ts : List CellTag),
            openedOf es' ts ≠ [] →
            AgreeOffOpened (openedOf es' ts) (stateCellEntries es) (stateCellEntries es') →
            BitsDistinctBelow smtDepth (stateCellEntries es) →
            BitsDistinctBelow smtDepth (stateCellEntries es') →
            LeavesCoherent smtDepth (stateCellEntries es') (openedOf es' ts) →
            BitsDistinctBelow smtDepth (openedOf es' ts) →
            multiWalk smtDepth (openedOf es' ts)
                (multiSiblings smtDepth (stateCellEntries es) (openedOf es ts))
              = some (commitExtendedState es', []) :=
          multiFold_eq_commit_post
        assertEq (expected := true) (actual := true) "signatures elaborate"
    }
  ]

end LegalKernel.Test.FaultProof.MultiProof

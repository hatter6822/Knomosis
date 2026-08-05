-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Frontier — the multiproof frontier, and
the same-cell case it exists to get right.

`docs/planning/state_root_merkleisation_plan.md` §6.4 records why this
module's FIRST test is the duplicate-cell one rather than its last.
The corpus cannot see the question: `deriveTransferBalances` at an
alias returns BOTH entries equal, and every sibling in the
`derive*Balances` family is alias-aware the same way, so the three
duplicate probes (`selfTransfer`, `depositWithFeeSelf`,
`topUpActionBudgetForSelf`) pass under a first-occurrence rule and a
last-occurrence one alike.  A dedup bug is invisible to them.

So the tests here are ordered by what they discriminate, not by what
is convenient to write:

  1. a cell named twice collapses to ONE frontier entry, and a bundle
     that carries it twice fails the shape check;
  2. the frontier is strictly ascending in path order, which is what
     makes distinctness a consequence of sortedness rather than a
     second check;
  3. the derivation agrees at an aliased cell — the property a
     first-vs-last rule would have to violate to matter;
  4. a plan whose aliases DISAGREE is refused, exercising a branch no
     action can reach (see `plannedBalances_alias_consistent`) and
     which therefore has no other way to be tested;
  5. the gap count's closed form agrees with the count itself.
-/

import LegalKernel.FaultProof.Frontier
import LegalKernel.FaultProof.Terminate
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Frontier

/-- The self-transfer's write set: `transfer r a a`, whose sender and
    recipient balance cells are the SAME cell.  Reachable by anyone,
    for free, which is why it is the shape the design has to survive
    rather than an edge case it may decline. -/
def selfTransferCells : List CellTag :=
  [ .balance 1 7, .balance 1 7, .nonce 7, .epochBudget 7 ]

/-- The same step's DISTINCT-cell sibling, for contrast. -/
def transferCells : List CellTag :=
  [ .balance 1 7, .balance 1 8, .nonce 7, .epochBudget 7 ]

/-- Tests. -/
def tests : List TestCase :=
  [ -- 1. THE SAME-CELL CASE.  Written first because it is the only
    --    part of the design the existing corpus is blind to.
    { name := "a cell named twice collapses to one frontier entry"
    , body := do
        assertEq (expected := 3)
          (actual := (frontierOf selfTransferCells).length)
          "the self-transfer's four writes open three distinct cells"
        assertEq (expected := 4)
          (actual := (frontierOf transferCells).length)
          "the plain transfer's four writes open four"
        -- The collapse is by KEY, not by constructor equality: two
        -- `.balance 1 7` tags are the same cell because they derive
        -- the same SMT key, and that is what the tree sees.
        assertEq (expected := 1)
          (actual := ((frontierOf selfTransferCells).filter
                        (fun t => smtCellKey t == smtCellKey (.balance 1 7))).length)
          "the duplicated cell appears exactly once"
    }
  , { name := "a bundle carrying the duplicate fails the shape check"
    , body := do
        -- The verifier derives the write set, dedups it, and requires
        -- the submitted cell list to BE that.  A bundle matching the
        -- underived list — the shape an honest chained fold sent — is
        -- refused, so a duplicate has no wire representation at all.
        assertEq (expected := false)
          (actual := frontierShapeOk selfTransferCells selfTransferCells)
          "the underived (duplicate-carrying) list is refused"
        assertEq (expected := true)
          (actual := frontierShapeOk selfTransferCells
                       (frontierOf selfTransferCells))
          "the deduped list is accepted"
        assertEq (expected := true)
          (actual := frontierShapeOk transferCells (frontierOf transferCells))
          "the distinct-cell list is accepted"
    }
  , { name := "a bundle in any order is accepted"
    , body := do
        -- Order carries no information: every opening is against the
        -- same root.  So the verifier NORMALISES the submission rather
        -- than dictating its order, and a permutation is accepted.
        --
        -- The duplicate is still refused, and by the SAME comparison —
        -- `pathSort` keeps duplicates while `frontierOf` drops them, so
        -- a duplicate-carrying bundle sorts to a longer list and fails
        -- on length.  Order free, duplicates not.
        let sorted := frontierOf transferCells
        assertEq (expected := true)
          (actual := frontierShapeOk transferCells sorted) "sorted is accepted"
        assertEq (expected := true)
          (actual := frontierShapeOk transferCells sorted.reverse)
          "and so is the reverse"
        assertEq (expected := true)
          (actual := frontierShapeOk transferCells (sorted.rotateLeft 2))
          "and any other permutation"
        -- The negative control for THIS test: order being free must not
        -- have made the check vacuous.
        assertEq (expected := false)
          (actual := frontierShapeOk transferCells (sorted.drop 1))
          "a missing cell is still refused"
    }
  , -- 2. Sortedness IS distinctness.
    { name := "the frontier is strictly ascending in path order"
    , body := do
        assertEq (expected := true)
          (actual := pathSorted (frontierOf selfTransferCells))
          "self-transfer frontier is strictly sorted"
        assertEq (expected := true)
          (actual := pathSorted (frontierOf transferCells))
          "transfer frontier is strictly sorted"
        -- The negative control: the UNSORTED list is not, so the
        -- predicate is not vacuously true on everything.
        assertEq (expected := false)
          (actual := pathSorted selfTransferCells)
          "the raw duplicate-carrying list is not strictly sorted"
    }
  , -- 3. The derivation agrees at the alias.
    { name := "the plan's aliased entries carry the same value"
    , body := do
        -- `transfer r a a` with a live balance.  Both plan entries name
        -- the same cell, and `deriveTransferBalances` gives them the
        -- same value — which is exactly why a first-vs-last dedup bug
        -- is invisible to the corpus, and why test 4 exists.
        let read : BalanceReader := fun r a => if r == 1 && a == 7 then some 100 else none
        match plannedBalances read (.transfer 1 7 7 30) 7 with
        | none      => assertEq (expected := "some") (actual := "none") "plan exists"
        | some plan =>
            assertEq (expected := 2) (actual := plan.length) "two entries"
            assertEq (expected := true) (actual := aliasConsistent plan)
              "the aliased entries agree"
            assertEq (expected := some 100)
              (actual := plannedBalanceAt? plan 1 7)
              "a self-transfer leaves the balance where it was"
    }
  , -- 4. The branch no action can reach.
    { name := "a plan whose aliases disagree is refused"
    , body := do
        -- Unreachable from any action: `plannedBalances_alias_consistent`
        -- proves every variant's plan agrees at an alias.  The guard is
        -- therefore only testable here, by construction, and it exists
        -- so a future derivation bug fails closed rather than silently
        -- picking whichever entry the lookup happens to find first.
        let bad : List ((ResourceId × ActorId) × Nat) := [((1, 7), 70), ((1, 7), 130)]
        assertEq (expected := false) (actual := aliasConsistent bad)
          "the synthetic plan is inconsistent"
        assertEq (expected := (none : Option Nat))
          (actual := plannedBalanceAt? bad 1 7)
          "the lookup refuses rather than taking the first"
        -- And it is a REFUSAL, not a blanket failure: an unrelated key
        -- in the same plan still reads.
        let mixed : List ((ResourceId × ActorId) × Nat) :=
          [((1, 7), 70), ((1, 8), 40), ((1, 7), 130)]
        assertEq (expected := some 40) (actual := plannedBalanceAt? mixed 1 8)
          "an unaliased key still reads"
        assertEq (expected := (none : Option Nat))
          (actual := plannedBalanceAt? mixed 1 7) "the aliased key does not"
    }
  , -- 5. The closed form.
    { name := "the gap count agrees with its closed form"
    , body := do
        for cells in [selfTransferCells, transferCells] do
          let keys := (frontierOf cells).map smtCellKey
          assertEq (expected := gapCount keys) (actual := gapCountClosed keys)
            "closed form agrees with the count"
        -- A one-key frontier has exactly one gap per level, which is
        -- what makes its wire encoding byte-identical to a single
        -- opening's `proofData`.
        assertEq (expected := smtDepth)
          (actual := gapCount [smtCellKey (.nonce 7)]) "m = 1 gives 256 gaps"
    }
  , { name := "every reachable alias produces an agreeing plan"
    , body := do
        -- The term-level pin: the signature is what downstream relies
        -- on, so a change to it fails at elaboration rather than at
        -- some later call site.
        let _pin : ∀ (read : BalanceReader) (a : Action) (signer : ActorId)
            (plan : List ((ResourceId × ActorId) × Nat)),
            plannedBalances read a signer = some plan →
            aliasConsistent plan = true :=
          plannedBalances_alias_consistent
        -- ...and the value-level sweep, over the aliasing shape each
        -- variant reaches.  `plannedBalanceAt?` returning `some` at the
        -- aliased cell is the observable consequence: it refuses only
        -- on disagreement, and there is none to find.
        let read : BalanceReader := fun _ _ => some 100
        let aliased : List Action :=
          [ .transfer 1 7 7 30                 -- sender = receiver
          , .depositWithFee 1 7 7 30 5 0 0     -- recipient = pool
          , .topUpActionBudget 1 30 0 7        -- payer = pool
          , .topUpActionBudgetFor 7 1 30 0 7   -- recipient = payer = pool
          , .claimBudgetRefund 1 3 10 7        -- pool = claimant
          , .reclaimAmmReserves 1 100 7 7 ]    -- reserve = pool
        for a in aliased do
          match plannedBalances read a 7 with
          | none      => assertEq (expected := "some") (actual := "none")
                           "the aliased variant plans"
          | some plan =>
              assertEq (expected := true) (actual := aliasConsistent plan)
                "the aliased plan agrees"
              assertEq (expected := true)
                (actual := (plannedBalanceAt? plan 1 7).isSome)
                "the lookup resolves rather than refusing"
    }
  , -- The order primitives the frontier is built on.
    { name := "path order is a strict order on distinct keys"
    , body := do
        let a := smtCellKey (.balance 1 7)
        let b := smtCellKey (.balance 1 8)
        assertEq (expected := false) (actual := pathLess a a) "irreflexive"
        assertEq (expected := true) (actual := pathLess a b != pathLess b a)
          "asymmetric on distinct keys"
        assertEq (expected := true) (actual := divLevel a b < smtDepth)
          "distinct keys diverge inside the tree"
        assertEq (expected := divLevel a b) (actual := divLevel b a)
          "divergence is symmetric"
    }
  , -- ...and the order laws, at the term level.  `pathSorted
    -- (frontierOf …)` used to be checked on two examples while
    -- `frontierShapeOk`'s whole argument rested on it; these are that
    -- argument, proved.
    { name := "API stability: path order is transitive and total"
    , body := do
        let _trans : ∀ (a b c : ByteArray),
            pathLess a b = true → pathLess b c = true → pathLess a c = true :=
          pathLess_trans
        let _total : ∀ (a b : ByteArray),
            divBelow smtDepth a b ≠ none → pathLess a b = false →
            pathLess b a = true :=
          pathLess_total
        pure ()
    }
  , { name := "API stability: the frontier is sorted, hence key-distinct"
    , body := do
        -- The two theorems that replace the value-level checks above:
        -- EVERY write set sorts, and sortedness IS distinctness.  Both
        -- are unconditional — the separation they used to take as a
        -- hypothesis is `keysSeparated_cellTags`.
        let _sorted : ∀ (ts : List CellTag), pathSorted (frontierOf ts) = true :=
          pathSorted_frontierOf
        let _nodup : ∀ (ts : List CellTag),
            ((frontierOf ts).map smtCellKey).Nodup :=
          frontierOf_keys_nodup
        pure ()
    }
  , { name := "API stability: separation is a theorem, not a hypothesis"
    , body := do
        -- A 32-byte key fills exactly the 256 bits the walk reads, so
        -- two distinct ones cannot agree on all of them.  That is what
        -- makes the sortedness theorems above unconditional, and it is
        -- the half of "the tree can tell cells apart" that is NOT
        -- collision-freeness.
        let _sep : ∀ (ts : List CellTag), KeysSeparated ts :=
          keysSeparated_cellTags
        let _bits : ∀ (a b : ByteArray), a.size = 32 → b.size = 32 → a ≠ b →
            divBelow smtDepth a b ≠ none :=
          divBelow_ne_none_of_ne
        pure ()
    }
  , { name := "API stability: the shape check decides TAGS"
    , body := do
        -- The model and `KnomosisStepVMRoot._requireFrontier` now
        -- decide the same question the same way: the contract looks
        -- each derived cell up by `(cellKind, keyA, keyB)`, and this
        -- compares tag lists.  A key-level comparison agreed with it
        -- only where `smtCellKey` is injective, and exactly where it
        -- is not, the tag comparison is the one that fails closed.
        let _faithful : ∀ (derived submitted : List CellTag),
            frontierShapeOk derived submitted = true →
            pathSort submitted = frontierOf derived :=
          fun _ _ h => by simpa [frontierShapeOk] using h
        pure ()
    }
  , { name := "the separation theorem agrees with computation on real keys"
    , body := do
        -- `keysSeparated_cellTags` says every distinct pair diverges.
        -- Computing it on a real write set is the value-level check
        -- that the theorem is about the function the code runs.
        let cells : List CellTag :=
          [.budgetPolicy, .balance 1 7, .balance 1 8, .nonce 7, .epochBudget 7]
        for t in cells do
          for u in cells do
            if (smtCellKey t == smtCellKey u) == false then
              assertEq (expected := true)
                (actual := (divBelow smtDepth (smtCellKey t) (smtCellKey u)).isSome)
                "distinct cell keys diverge at a bit the walk reads"
        assertEq (expected := true) (actual := pathSorted (frontierOf cells))
          "and the frontier they build is strictly ascending"
    }
  ]

end LegalKernel.Test.FaultProof.Frontier

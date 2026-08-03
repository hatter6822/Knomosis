-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
# The multiproof frontier

`docs/planning/state_root_merkleisation_plan.md` §6.  A step opens
several cells, and the chained fold opens each against the root the
previous write produced — so it walks the tree once per opening and
carries a per-opening "which occurrence is this" rule.  A pre-root
multiproof opens every cell against the SAME root, which makes the
bundle a SET of cells rather than a sequence, and lets one merged walk
serve all of them.

This module is the set: the order the tree induces on cells, the
deduplication that order gives for free, and the wire's shape, which
is a function of the key set alone.

## The order

`smtRootListAux (d+1)` splits on `BitsKey.keyBit · d` and the root is
`smtRootListAux smtDepth`, so bit 255 is the ROOT split and bit 0 the
deepest.  A path read from the root down therefore reads Lean bit
indices 255, 254, …, 0, and two keys' paths diverge at the HIGHEST
index at which their bits differ.  That index is `divLevel`, and the
key whose bit is `false` there is the left child, hence first —
`pathLess`.

Everything downstream rests on one structural fact
(`adjacent_div_ne`): three consecutive keys cannot share a divergence
level, because the middle one would have to sit in both children of
that split.  So at most TWO adjacent frontier entries merge at any
level, and a single left-to-right scan advancing by two on a merge is
correct.

## Why the shape check is one comparison

The frontier is strictly ascending, so distinctness is a CONSEQUENCE
of sortedness rather than a second check — and a bundle carrying a
cell twice fails on the same comparison that catches a bundle in the
wrong order.  That is the whole of the same-cell defence: a duplicate
has no wire representation.
-/

import LegalKernel.FaultProof.KeyDerivation


open LegalKernel.Authority

namespace LegalKernel.FaultProof

/-! ## Divergence -/

/-- The highest bit index below `d` at which two keys differ, or
    `none` when they agree on every bit below `d`.

    Recurses from `d - 1` DOWNWARD, which is the order a path is read
    from the root, so the first difference it finds is the one the
    tree splits on. -/
def divBelow : Nat → ByteArray → ByteArray → Option Nat
  | 0,     _, _ => none
  | d + 1, a, b =>
    if BitsKey.keyBit a d != BitsKey.keyBit b d then some d
    else divBelow d a b

/-- The level at which two keys' paths diverge.

    `smtDepth` when they agree on every bit the tree reads — which
    cannot happen for two distinct cells under the key-injectivity
    hypothesis the state root already carries, and which the callers
    therefore never rely on. -/
def divLevel (a b : ByteArray) : Nat := (divBelow smtDepth a b).getD smtDepth

/-- Path order: `a` comes first iff its bit at the divergence level is
    `false`, since `smtRootListAux` puts the `false` half left. -/
def pathLess (a b : ByteArray) : Bool :=
  match divBelow smtDepth a b with
  | none   => false
  | some d => ! BitsKey.keyBit a d

/-- `divBelow` reports a level the two keys really differ at. -/
theorem divBelow_bit_ne :
    ∀ (d : Nat) (a b : ByteArray) (i : Nat),
      divBelow d a b = some i → BitsKey.keyBit a i ≠ BitsKey.keyBit b i := by
  intro d
  induction d with
  | zero => intro a b i h; exact absurd h (by simp [divBelow])
  | succ k ih =>
    intro a b i h
    unfold divBelow at h
    by_cases hne : BitsKey.keyBit a k != BitsKey.keyBit b k
    · rw [if_pos hne] at h
      have : i = k := by simpa using h.symm
      subst this
      exact fun heq => by simp [heq] at hne
    · rw [if_neg hne] at h
      exact ih a b i h

/-- `divBelow` reports a level below its bound. -/
theorem divBelow_lt :
    ∀ (d : Nat) (a b : ByteArray) (i : Nat), divBelow d a b = some i → i < d := by
  intro d
  induction d with
  | zero => intro a b i h; exact absurd h (by simp [divBelow])
  | succ k ih =>
    intro a b i h
    unfold divBelow at h
    by_cases hne : BitsKey.keyBit a k != BitsKey.keyBit b k
    · rw [if_pos hne] at h
      have : i = k := by simpa using h.symm
      omega
    · rw [if_neg hne] at h
      exact Nat.lt_succ_of_lt (ih a b i h)

/-- Divergence is symmetric — it is a property of the pair, not of an
    orientation, which is what lets the scan compare neighbours in
    either direction. -/
theorem divBelow_comm :
    ∀ (d : Nat) (a b : ByteArray), divBelow d a b = divBelow d b a := by
  intro d
  induction d with
  | zero => intro _ _; rfl
  | succ k ih =>
    intro a b
    have hsym : (BitsKey.keyBit a k != BitsKey.keyBit b k)
              = (BitsKey.keyBit b k != BitsKey.keyBit a k) := by
      cases BitsKey.keyBit a k <;> cases BitsKey.keyBit b k <;> rfl
    unfold divBelow
    rw [hsym, ih]

/-- `divLevel` is symmetric. -/
theorem divLevel_comm (a b : ByteArray) : divLevel a b = divLevel b a := by
  unfold divLevel; rw [divBelow_comm]

/-- A key never precedes itself. -/
theorem pathLess_irrefl (a : ByteArray) : pathLess a a = false := by
  unfold pathLess
  have h : ∀ d, divBelow d a a = none := by
    intro d
    induction d with
    | zero => rfl
    | succ k ih => unfold divBelow; rw [if_neg (by simp), ih]
  rw [h]

/-- **At most two adjacent entries merge at a level.**

    Three consecutive keys in path order cannot share a divergence
    level: the first pair's split puts `b` on the right of it and the
    second pair's puts `b` on the left, and `b` cannot be both.  This
    is what licenses the frontier's single left-to-right scan — with
    it, a merge consumes exactly two neighbours and the scan advances
    by two. -/
theorem adjacent_div_ne (a b c : ByteArray) (d : Nat)
    (hab : pathLess a b = true) (hbc : pathLess b c = true)
    (ha : divBelow smtDepth a b = some d)
    (hb : divBelow smtDepth b c = some d) : False := by
  -- `a` before `b` at level `d` means `a`'s bit is false, so `b`'s is true.
  have h_a : BitsKey.keyBit a d = false := by
    unfold pathLess at hab; rw [ha] at hab; simpa using hab
  have h_b_true : BitsKey.keyBit b d = true := by
    have := divBelow_bit_ne smtDepth a b d ha
    rw [h_a] at this
    cases hbit : BitsKey.keyBit b d with
    | false => exact absurd hbit.symm this
    | true  => rfl
  -- `b` before `c` at the SAME level means `b`'s bit is false.
  have h_b_false : BitsKey.keyBit b d = false := by
    unfold pathLess at hbc; rw [hb] at hbc; simpa using hbc
  rw [h_b_true] at h_b_false
  exact Bool.noConfusion h_b_false

/-! ## The frontier -/

/-- Insert a cell into a path-sorted, key-distinct list, collapsing a
    cell already present.

    Collapsing is by KEY rather than by tag equality because the key is
    what the tree sees: two tags deriving the same key are one cell, and
    a frontier that kept both would open the same leaf twice. -/
def frontierInsert (t : CellTag) : List CellTag → List CellTag
  | []        => [t]
  | u :: rest =>
    if smtCellKey t == smtCellKey u then u :: rest
    else if pathLess (smtCellKey t) (smtCellKey u) then t :: u :: rest
    else u :: frontierInsert t rest

/-- The frontier of a write set: its distinct cells, in path order. -/
def frontierOf (ts : List CellTag) : List CellTag := ts.foldr frontierInsert []

/-- Strictly ascending in path order.

    Strict, so this is distinctness as well as ordering — which is why
    the shape check below is one comparison rather than two. -/
def pathSorted : List CellTag → Bool
  | []            => true
  | [_]           => true
  | t :: u :: rest => pathLess (smtCellKey t) (smtCellKey u) && pathSorted (u :: rest)

/-- Insert into a path-sorted list WITHOUT collapsing an equal key.

    The difference from `frontierInsert` is the whole of the shape
    check's power: sorting the submission normalises its ORDER while
    preserving its LENGTH, so a duplicate survives the sort and is then
    caught by the comparison. -/
def pathInsert (t : CellTag) : List CellTag → List CellTag
  | []        => [t]
  | u :: rest =>
    if pathLess (smtCellKey t) (smtCellKey u) then t :: u :: rest
    else u :: pathInsert t rest

/-- Sort a submitted cell list into path order, keeping duplicates. -/
def pathSort (ts : List CellTag) : List CellTag := ts.foldr pathInsert []

/-- **The bundle's shape check.**  Sort what was submitted, and require
    it to BE the derived write set's frontier.

    Order carries no information here — every opening is against the
    same root — so the verifier NORMALISES the submission rather than
    dictating its order.  Any permutation is accepted.

    What is not accepted is a duplicate, and the reason the same
    comparison catches it is that `pathSort` keeps duplicates while
    `frontierOf` drops them: a bundle naming a cell twice sorts to a
    LONGER list than the frontier and fails on length.  So one
    comparison still catches everything — a duplicate, a missing cell,
    an extra cell — while leaving order free.

    That is the whole of the same-cell defence: under a pre-root
    multiproof a duplicate has no wire representation, so there is no
    occurrence rule left to get wrong. -/
def frontierShapeOk (derived submitted : List CellTag) : Bool :=
  (pathSort submitted).map smtCellKey == (frontierOf derived).map smtCellKey

/-- `frontierInsert` never empties a list: it either returns its
    argument, prepends, or rebuilds with the head intact. -/
theorem frontierInsert_ne_nil (t : CellTag) (l : List CellTag) :
    frontierInsert t l ≠ [] := by
  cases l with
  | nil => simp [frontierInsert]
  | cons u rest =>
    unfold frontierInsert
    split
    · simp
    · split <;> simp

/-- A non-empty cell list has a non-empty frontier. -/
theorem frontierOf_cons_ne_nil (t : CellTag) (ts : List CellTag) :
    frontierOf (t :: ts) ≠ [] := by
  show List.foldr frontierInsert [] (t :: ts) ≠ []
  rw [List.foldr_cons]
  exact frontierInsert_ne_nil _ _

/-- **An empty submission fails the shape check** whenever the step
    opens anything at all.

    Load-bearing rather than incidental: the multiproof frontier always
    leads with the read-only budget-policy cell, so this instantiates
    unconditionally and an empty bundle is refused before a byte of the
    wire is read.  The chained verifier needed the same fact per
    variant, from `writeCells` naming the nonce and the epoch budget;
    here it is one lemma about the list's shape. -/
theorem frontierShapeOk_nil_of_cons (t : CellTag) (ts : List CellTag) :
    frontierShapeOk (t :: ts) [] = false := by
  unfold frontierShapeOk
  have h := frontierOf_cons_ne_nil t ts
  cases hc : frontierOf (t :: ts) with
  | nil          => exact absurd hc h
  | cons _ _     => simp [pathSort]

/-! ## The wire's shape

The gap count is a function of the KEY SET, so the verifier computes it
before parsing and can then demand an exact length.  That is stronger
than the chained verifier, which pads a short proof with
`PADDING_HASH` and walks on — a truncated proof is currently a silent
reinterpretation rather than a refusal. -/

/-- The divergence levels of consecutive frontier entries. -/
def adjacentDivs : List ByteArray → List Nat
  | []             => []
  | [_]            => []
  | a :: b :: rest => divLevel a b :: adjacentDivs (b :: rest)

/-- How many nodes are active at level `d`: one per key, less one for
    every pair that has already merged below `d`. -/
def activeAt (keys : List ByteArray) (d : Nat) : Nat :=
  keys.length - ((adjacentDivs keys).filter (fun j => decide (j < d))).length

/-- How many merges happen AT level `d`. -/
def mergesAt (keys : List ByteArray) (d : Nat) : Nat :=
  ((adjacentDivs keys).filter (fun j => decide (j = d))).length

/-- Gaps at level `d`: active nodes, less the two neighbours each merge
    consumes.  A merge reads no sibling from the wire — the two active
    nodes are each other's. -/
def gapsAt (keys : List ByteArray) (d : Nat) : Nat :=
  activeAt keys d - 2 * mergesAt keys d

/-- The wire's gap count, by simulation. -/
def gapCount (keys : List ByteArray) : Nat :=
  (List.range smtDepth).foldl (fun acc d => acc + gapsAt keys d) 0

/-- The same count in closed form: `(smtDepth + 1) − m + Σ divs`.

    The verifier uses this — it is O(m) rather than O(256 · m), and it
    is what makes an exact-length check affordable on L1. -/
def gapCountClosed (keys : List ByteArray) : Nat :=
  if keys.isEmpty then 0
  else (smtDepth + 1) + (adjacentDivs keys).foldl (· + ·) 0 - keys.length

/-! ## Plans

A plan is an association list from balance cell to post-value, and two
entries can name the SAME cell — every aliasable variant reaches that
case cheaply (a self-transfer, a self-delegated top-up).  The lookup
must therefore say what it does when they disagree.

It refuses.  `plannedBalances_alias_consistent` proves that branch
unreachable from any action, so the refusal costs nothing; what it buys
is that a future derivation bug fails closed instead of silently
picking whichever entry the search happens to find first.  That is the
rule the chained fold never had to state, because it read a running
value per occurrence rather than a plan per cell. -/

/-- An association list assigns at most one value per key. -/
def aliasConsistent {α β : Type} [BEq α] [BEq β] (l : List (α × β)) : Bool :=
  l.all (fun p => l.all (fun q => !(p.1 == q.1) || (p.2 == q.2)))

/-- Look one balance cell up in a plan, refusing a disagreeing
    duplicate rather than resolving it. -/
def plannedBalanceAt? (plan : List ((ResourceId × ActorId) × Nat))
    (r : ResourceId) (a : ActorId) : Option Nat :=
  match plan.filter (fun p => p.1 == (r, a)) with
  | []      => none
  | v :: vs => if vs.all (fun q => q.2 == v.2) then some v.2 else none

/-- A consistent plan's lookup agrees with the first matching entry —
    so refusing costs nothing on any plan an action can produce. -/
theorem plannedBalanceAt?_of_aliasConsistent
    (plan : List ((ResourceId × ActorId) × Nat)) (r : ResourceId) (a : ActorId)
    (v : (ResourceId × ActorId) × Nat) (vs : List ((ResourceId × ActorId) × Nat))
    (h_filter : plan.filter (fun p => p.1 == (r, a)) = v :: vs)
    (h_all : vs.all (fun q => q.2 == v.2) = true) :
    plannedBalanceAt? plan r a = some v.2 := by
  unfold plannedBalanceAt?
  rw [h_filter]
  simp only [h_all, if_true]

end LegalKernel.FaultProof

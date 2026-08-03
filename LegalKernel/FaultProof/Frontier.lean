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

/-- Where `divBelow` reports nothing the two keys agree, at every bit
    below the bound.  The converse of `divBelow_bit_ne`, and the half
    that turns "no divergence" into a statement about the keys
    themselves rather than about the search. -/
theorem divBelow_none_agree :
    ∀ (d : Nat) (a b : ByteArray), divBelow d a b = none →
      ∀ i, i < d → BitsKey.keyBit a i = BitsKey.keyBit b i := by
  intro d
  induction d with
  | zero => intro a b _ i hi; exact absurd hi (Nat.not_lt_zero i)
  | succ k ih =>
    intro a b h i hi
    unfold divBelow at h
    by_cases hne : BitsKey.keyBit a k != BitsKey.keyBit b k
    · rw [if_pos hne] at h; exact absurd h (by simp)
    · rw [if_neg hne] at h
      rcases Nat.lt_succ_iff_lt_or_eq.mp hi with hi' | hi'
      · exact ih a b h i hi'
      · subst hi'; simpa using hne

/-- A byte is determined by its eight bits. -/
theorem uint8_eq_of_bits (x y : UInt8)
    (h : ∀ k, k < 8 → (x.toNat >>> k) % 2 = (y.toNat >>> k) % 2) : x = y := by
  refine UInt8.toNat_inj.mp (Nat.eq_of_testBit_eq (fun k => ?_))
  by_cases hk : k < 8
  · have hb := h k hk
    rw [Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow] at hb
    rw [Nat.testBit_eq_decide_div_mod_eq, Nat.testBit_eq_decide_div_mod_eq, hb]
  · -- Past the byte's width both sides read zero.
    have hle : (256:Nat) ≤ 2 ^ k := by
      calc (256:Nat) = 2 ^ 8 := rfl
        _ ≤ 2 ^ k := Nat.pow_le_pow_right (by decide) (Nat.le_of_not_lt hk)
    rw [Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le x.toNat_lt_size hle),
        Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le y.toNat_lt_size hle)]

/-- **The bits the tree reads determine the key.**  Two same-sized
    byte arrays agreeing on every bit below `8 · size` are equal.

    `keyBit` is a total function returning `false` past the array, so
    the bound matters: agreement on the first `8 · n` bits says
    everything only because both arrays stop there. -/
theorem byteArray_eq_of_keyBits (a b : ByteArray) (n : Nat)
    (ha : a.size = n) (hb : b.size = n)
    (h : ∀ i, i < 8 * n → BitsKey.keyBit a i = BitsKey.keyBit b i) : a = b := by
  refine ByteArray.ext (Array.ext (ha.trans hb.symm) (fun j hj _ => ?_))
  show a[j] = b[j]
  refine uint8_eq_of_bits _ _ (fun k hk => ?_)
  have hj8 : j < n := by rw [← ha]; exact hj
  -- Bit `k` of byte `j` is key bit `8·j + (7 − k)`, MSB-first.
  have hbit := h (8 * j + (7 - k)) (by omega)
  have hbit' : (if hh : (8 * j + (7 - k)) / 8 < a.size then
        decide (((a[(8 * j + (7 - k)) / 8]'hh).toNat >>> (7 - (8 * j + (7 - k)) % 8)) % 2 = 1)
      else false)
      = (if hh : (8 * j + (7 - k)) / 8 < b.size then
        decide (((b[(8 * j + (7 - k)) / 8]'hh).toNat >>> (7 - (8 * j + (7 - k)) % 8)) % 2 = 1)
      else false) := hbit
  have hdiv : (8 * j + (7 - k)) / 8 = j := by omega
  have hmod : 7 - (8 * j + (7 - k)) % 8 = k := by omega
  rw [hdiv, hmod, dif_pos (show j < a.size by omega),
    dif_pos (show j < b.size by omega)] at hbit'
  have := (decide_eq_decide).mp hbit'
  omega

/-- **Distinct keys of the tree's own width always diverge.**

    A 32-byte key occupies exactly the 256 bits the walk reads, so two
    distinct ones cannot agree on all of them.  This is what makes the
    separation side condition below a theorem rather than a
    hypothesis. -/
theorem divBelow_ne_none_of_ne (a b : ByteArray)
    (ha : a.size = 32) (hb : b.size = 32) (h : a ≠ b) :
    divBelow smtDepth a b ≠ none := by
  intro h_none
  exact h (byteArray_eq_of_keyBits a b 32 ha hb
    (fun i hi => divBelow_none_agree smtDepth a b h_none i
      (by simpa [smtDepth] using hi)))

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

/-- Above the divergence the two keys agree — that is what makes the
    divergence "the" level rather than "a" level. -/
theorem divBelow_agree_above :
    ∀ (d : Nat) (a b : ByteArray) (i j : Nat),
      divBelow d a b = some i → i < j → j < d →
      BitsKey.keyBit a j = BitsKey.keyBit b j := by
  intro d
  induction d with
  | zero => intro a b i j h _ hj; omega
  | succ k ih =>
    intro a b i j h hij hj
    unfold divBelow at h
    by_cases hne : BitsKey.keyBit a k != BitsKey.keyBit b k
    · rw [if_pos hne] at h
      have : i = k := by simpa using h.symm
      omega
    · rw [if_neg hne] at h
      rcases Nat.lt_or_ge j k with hjk | hjk
      · exact ih a b i j h hij hjk
      · have : j = k := by omega
        subst this
        simpa using (by simpa using hne : ¬ (BitsKey.keyBit a j != BitsKey.keyBit b j))
  
/-- Agreeing above a level where they differ IS the divergence. -/
theorem divBelow_eq_of :
    ∀ (d : Nat) (a b : ByteArray) (k : Nat),
      k < d → BitsKey.keyBit a k ≠ BitsKey.keyBit b k →
      (∀ j, k < j → j < d → BitsKey.keyBit a j = BitsKey.keyBit b j) →
      divBelow d a b = some k := by
  intro d
  induction d with
  | zero => intro _ _ _ h; omega
  | succ m ih =>
    intro a b k hk hne hab
    unfold divBelow
    by_cases hm : BitsKey.keyBit a m != BitsKey.keyBit b m
    · rw [if_pos hm]
      -- `m` is a difference, and everything strictly above `k` agrees,
      -- so `m` cannot be above `k`; with `k < m + 1` it must BE `k`.
      have : k = m := by
        rcases Nat.lt_or_ge k m with h | h
        · exact absurd (hab m h (Nat.lt_succ_self m)) (by simpa using hm)
        · omega
      rw [this]
    · rw [if_neg hm]
      have hkm : k < m := by
        rcases Nat.lt_or_ge k m with h | h
        · exact h
        · have : k = m := by omega
          subst this
          exact absurd (by simpa using hm) hne
      exact ih a b k hkm hne (fun j hj hjm => hab j hj (Nat.lt_succ_of_lt hjm))

/-- **Path order is total on keys the tree can tell apart.**

    "Can tell apart" is `divBelow smtDepth ≠ none` — the keys differ at
    some bit the walk actually reads.  It is a side condition rather
    than a fact because `pathLess` is defined on `ByteArray`, and two
    arrays agreeing on all 256 read bits are equal only once their SIZE
    is fixed; the collision-freedom the state root already assumes is
    what supplies it for real cell keys. -/
theorem pathLess_total (a b : ByteArray)
    (h_sep : divBelow smtDepth a b ≠ none) (h_ab : pathLess a b = false) :
    pathLess b a = true := by
  unfold pathLess at h_ab ⊢
  rw [divBelow_comm smtDepth b a]
  cases hd : divBelow smtDepth a b with
  | none => exact absurd hd h_sep
  | some d =>
    rw [hd] at h_ab
    have h_a : BitsKey.keyBit a d = true := by simpa using h_ab
    have h_ne := divBelow_bit_ne smtDepth a b d hd
    simp only []
    cases hb : BitsKey.keyBit b d with
    | false => simp
    | true  => exact absurd (h_a.trans hb.symm) h_ne

/-- **Path order is transitive.**

    The three-way case split is where `adjacent_div_ne` earns its
    keep: equal divergence levels are impossible for a sorted triple,
    so only the two strict orderings remain and each determines
    `div a c` outright. -/
theorem pathLess_trans (a b c : ByteArray)
    (hab : pathLess a b = true) (hbc : pathLess b c = true) :
    pathLess a c = true := by
  -- Both divergences exist, or the premises are false.
  have hdab_ex : ∃ dab, divBelow smtDepth a b = some dab := by
    cases hd : divBelow smtDepth a b with
    | none   => rw [pathLess, hd] at hab; exact absurd hab (by simp)
    | some d => exact ⟨d, rfl⟩
  have hdbc_ex : ∃ dbc, divBelow smtDepth b c = some dbc := by
    cases hd : divBelow smtDepth b c with
    | none   => rw [pathLess, hd] at hbc; exact absurd hbc (by simp)
    | some d => exact ⟨d, rfl⟩
  obtain ⟨dab, hdab⟩ := hdab_ex
  obtain ⟨dbc, hdbc⟩ := hdbc_ex
  have h_a : BitsKey.keyBit a dab = false := by
    rw [pathLess, hdab] at hab; simpa using hab
  have h_b : BitsKey.keyBit b dbc = false := by
    rw [pathLess, hdbc] at hbc; simpa using hbc
  rcases Nat.lt_trichotomy dab dbc with h | h | h
  · -- The higher split is `dbc`; `a` and `b` agree there.
    have h_ab_at : BitsKey.keyBit a dbc = BitsKey.keyBit b dbc :=
      divBelow_agree_above smtDepth a b dab dbc hdab h
        (divBelow_lt smtDepth b c dbc hdbc)
    have h_ac : BitsKey.keyBit a dbc ≠ BitsKey.keyBit c dbc := by
      rw [h_ab_at]; exact divBelow_bit_ne smtDepth b c dbc hdbc
    have h_above : ∀ j, dbc < j → j < smtDepth →
        BitsKey.keyBit a j = BitsKey.keyBit c j := by
      intro j hj hjd
      rw [divBelow_agree_above smtDepth a b dab j hdab (by omega) hjd,
          divBelow_agree_above smtDepth b c dbc j hdbc hj hjd]
    have hac := divBelow_eq_of smtDepth a c dbc
      (divBelow_lt smtDepth b c dbc hdbc) h_ac h_above
    rw [pathLess, hac]
    simpa [h_ab_at] using h_b
  · exact absurd (adjacent_div_ne a b c dab hab hbc hdab (h ▸ hdbc)) (by simp)
  · -- The higher split is `dab`; `b` and `c` agree there.
    have h_bc_at : BitsKey.keyBit b dab = BitsKey.keyBit c dab :=
      divBelow_agree_above smtDepth b c dbc dab hdbc h
        (divBelow_lt smtDepth a b dab hdab)
    have h_ac : BitsKey.keyBit a dab ≠ BitsKey.keyBit c dab := by
      rw [← h_bc_at]; exact divBelow_bit_ne smtDepth a b dab hdab
    have h_above : ∀ j, dab < j → j < smtDepth →
        BitsKey.keyBit a j = BitsKey.keyBit c j := by
      intro j hj hjd
      rw [divBelow_agree_above smtDepth a b dab j hdab hj hjd,
          divBelow_agree_above smtDepth b c dbc j hdbc (by omega) hjd]
    have hac := divBelow_eq_of smtDepth a c dab
      (divBelow_lt smtDepth a b dab hdab) h_ac h_above
    rw [pathLess, hac]
    simpa using h_a

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
    occurrence rule left to get wrong.

    Compared at the TAG level, not the key level.  The two differ only
    under a hash collision, and exactly there the tag comparison is the
    one that fails closed: two colliding tags are one cell to the tree,
    so a key-level check would accept a submission naming the cell the
    step does NOT write and then derive that cell's post-value.  It is
    also what `KnomosisStepVMRoot._requireFrontier` does — it looks
    each derived cell up by `(cellKind, keyA, keyB)` — so the model and
    the contract now decide the same question the same way rather than
    agreeing only where keys are injective.

    Sorting is still by KEY, because path order is what the walk
    consumes.  That is not a reintroduction of the slack: the sort
    determines the ORDER, the comparison determines the CONTENT, and a
    submission whose keys tie is rejected by the walk's strict-ascent
    requirement before either matters. -/
def frontierShapeOk (derived submitted : List CellTag) : Bool :=
  pathSort submitted == frontierOf derived

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

/-! ## The frontier is sorted, and therefore key-distinct

`pathSorted (frontierOf ts)` was a value-level fact — checked on two
example write sets — while `frontierShapeOk`'s whole argument rests on
it: "strict ascent gives distinctness for free, which is why the shape
check is one comparison rather than two."  These are that argument,
proved.

The side condition is `KeysSeparated`: the cells' keys differ at some
bit the walk actually READS.  It is not free, because `pathLess` is
defined on `ByteArray` and two arrays agreeing on all 256 read bits are
equal only once their size is pinned; the collision-freedom the state
root already assumes is what supplies it for real cell keys. -/

/-- Every pair of cells in `ts` that the frontier does NOT collapse
    differs at some bit the walk reads.

    Stated on `≠` and used against `frontierInsert`'s `==` test, which
    is the same relation because `LawfulBEq ByteArray`
    (`Encoding/CBOR.lean`) says so.  Before that instance existed the
    two were formally unrelated and this had to be phrased on `==` to
    be applicable at all — which made it inapplicable to
    `BitsDistinctBelow`, whose conclusion is a `≠` on bits.  It is the
    property both need.

    Named rather than inlined because it is the *sentence* the
    frontier's order rests on, and because `keysSeparated_cellTags`
    then has something to conclude.  It is not a hypothesis: it holds
    of every cell list. -/
def KeysSeparated (ts : List CellTag) : Prop :=
  ∀ t ∈ ts, ∀ u ∈ ts, smtCellKey t ≠ smtCellKey u →
    divBelow smtDepth (smtCellKey t) (smtCellKey u) ≠ none

/-- **Cell keys are always separated.**

    Not a side condition — a theorem, and the reason is that
    `smtCellKey` hashes to exactly the tree's width: a 32-byte key
    fills all 256 bits the walk reads, so two distinct keys must
    differ at one of them.

    Worth stating as its own thing because the *other* separation
    obligation — that distinct CELLS get distinct KEYS — is genuinely
    conditional (`smtCellKey_injective_under_collision_free`).  The
    two look alike and are not: one is arithmetic on a fixed width,
    the other is collision-freeness of a hash. -/
theorem keysSeparated_cellTags (ts : List CellTag) : KeysSeparated ts := by
  intro t _ u _ hne
  exact divBelow_ne_none_of_ne _ _ (smtCellKey_size t) (smtCellKey_size u) hne

/-- Membership is preserved by insertion, up to the collapse: every
    cell of the result was already there or is the inserted one. -/
theorem mem_frontierInsert (t u : CellTag) (l : List CellTag)
    (h : u ∈ frontierInsert t l) : u = t ∨ u ∈ l := by
  induction l with
  | nil => simp [frontierInsert] at h; exact Or.inl h
  | cons v rest ih =>
    unfold frontierInsert at h
    split at h
    · exact Or.inr h
    · split at h
      · rcases List.mem_cons.mp h with h' | h'
        · exact Or.inl h'
        · exact Or.inr h'
      · rcases List.mem_cons.mp h with h' | h'
        · exact Or.inr (h' ▸ List.mem_cons_self)
        · rcases ih h' with h'' | h''
          · exact Or.inl h''
          · exact Or.inr (List.mem_cons_of_mem _ h'')

/-- Every cell of a frontier came from the list it was built from. -/
theorem mem_frontierOf (ts : List CellTag) :
    ∀ u ∈ frontierOf ts, u ∈ ts := by
  induction ts with
  | nil => intro u h; simp [frontierOf] at h
  | cons t rest ih =>
    intro u h
    show u ∈ t :: rest
    have : u ∈ frontierInsert t (frontierOf rest) := h
    rcases mem_frontierInsert t u (frontierOf rest) this with h' | h'
    · exact h' ▸ List.mem_cons_self
    · exact List.mem_cons_of_mem _ (ih u h')

/-- Insertion loses no KEY: the result carries the inserted cell's key
    and every key the list already had.

    At the key level rather than the tag level because that is exactly
    what `frontierInsert` preserves — the collapse branch discards the
    inserted TAG and keeps a key-equal one, so a tag-level statement
    would be false without a hash hypothesis. -/
theorem mem_keys_frontierInsert (t : CellTag) (l : List CellTag) (k : ByteArray)
    (h : k = smtCellKey t ∨ k ∈ l.map smtCellKey) :
    k ∈ (frontierInsert t l).map smtCellKey := by
  induction l with
  | nil =>
    rcases h with h | h
    · simp [frontierInsert, h]
    · simp at h
  | cons v rest ih =>
    unfold frontierInsert
    split
    · rename_i h_eq
      -- The collapse: `v`'s key IS `t`'s, so nothing is lost.
      rcases h with h | h
      · exact List.mem_map.mpr ⟨v, List.mem_cons_self, by
          rw [h]; exact (by simpa using h_eq : smtCellKey t = smtCellKey v) ▸ rfl⟩
      · exact h
    · split
      · rcases h with h | h
        · simp [h]
        · exact List.mem_cons_of_mem _ h
      · rw [List.map_cons]
        rcases h with h | h
        · exact List.mem_cons_of_mem _ (ih (Or.inl h))
        · rw [List.map_cons] at h
          rcases List.mem_cons.mp h with h' | h'
          · exact h' ▸ List.mem_cons_self
          · exact List.mem_cons_of_mem _ (ih (Or.inr h'))

/-- **The frontier keeps every key the write set names.**  The
    converse of `mem_frontierOf`, and the half the correctness proofs
    need: a cell a step writes is a cell the bundle opens. -/
theorem mem_keys_frontierOf (ts : List CellTag) (t : CellTag) (h : t ∈ ts) :
    smtCellKey t ∈ (frontierOf ts).map smtCellKey := by
  induction ts with
  | nil => simp at h
  | cons u rest ih =>
    show smtCellKey t ∈ (frontierInsert u (frontierOf rest)).map smtCellKey
    rcases List.mem_cons.mp h with h' | h'
    · exact mem_keys_frontierInsert u _ _ (Or.inl (by rw [h']))
    · exact mem_keys_frontierInsert u _ _ (Or.inr (ih h'))

/-- The tree tells this write set's cells apart: no two of them hash
    to one key.

    The *other* separation obligation, and the conditional one —
    `keysSeparated_cellTags` is arithmetic on a fixed width, this is
    collision-freeness of `hashBytes`.  Stated as a predicate on the
    list so a caller discharges it once for a step's whole write set
    rather than pair by pair. -/
def KeyInjectiveOn (ts : List CellTag) : Prop :=
  ∀ t ∈ ts, ∀ u ∈ ts, smtCellKey t = smtCellKey u → t = u

/-- Key injectivity restricts to any sub-list — so a caller
    discharges it once, over every cell a step's adjudication can
    touch, and every consumer takes the part it needs. -/
theorem KeyInjectiveOn.mono {ts us : List CellTag} (h : KeyInjectiveOn us)
    (h_sub : ∀ t ∈ ts, t ∈ us) : KeyInjectiveOn ts :=
  fun t ht u hu h_key => h t (h_sub t ht) u (h_sub u hu) h_key

/-- **A written cell is an opened cell**, given that the tree can tell
    the write set's cells apart.

    The hypothesis is doing real work rather than tidying: without it
    the frontier could collapse two genuinely different cells into
    one, and the step's write to the collapsed one would be invisible
    to the bundle.  That is precisely the failure
    `smtCellKey_injective_under_collision_free` rules out. -/
theorem mem_frontierOf_of_mem (ts : List CellTag) (h_inj : KeyInjectiveOn ts)
    (t : CellTag) (h : t ∈ ts) : t ∈ frontierOf ts := by
  obtain ⟨u, hu, h_key⟩ := List.mem_map.mp (mem_keys_frontierOf ts t h)
  exact (h_inj u (mem_frontierOf ts u hu) t h h_key) ▸ hu

/-- `KeyInjectiveOn` from collision-freeness on the write set's own
    pre-images, plus the layout bounds.

    Both hypotheses are the ones already in play elsewhere:
    `CollisionFreeOn` over a FINITE pre-image set is the project's
    standing hash assumption (a global injectivity predicate is
    refutable inside Lean), and `KeyBounded` is the `2^256` truncation
    boundary of the packed key layout. -/
theorem keyInjectiveOn_of_collisionFree (ts : List CellTag)
    (h_cf : Bridge.CollisionFreeOn (ts.map cellKeyPreimage)
      LegalKernel.Runtime.hashBytes)
    (h_bound : ∀ t ∈ ts, t.KeyBounded) : KeyInjectiveOn ts := by
  intro t ht u hu h_key
  exact cellKeyPreimage_injective t u (h_bound t ht) (h_bound u hu)
    (h_cf _ (List.mem_map_of_mem ht) _ (List.mem_map_of_mem hu) h_key)

/-- A sorted list stays sorted when a key that precedes its head is
    prepended. -/
theorem pathSorted_cons (t : CellTag) (l : List CellTag)
    (h_sorted : pathSorted l = true)
    (h_head : ∀ u, l.head? = some u → pathLess (smtCellKey t) (smtCellKey u) = true) :
    pathSorted (t :: l) = true := by
  cases l with
  | nil => rfl
  | cons u rest =>
    show (pathLess (smtCellKey t) (smtCellKey u) && pathSorted (u :: rest)) = true
    rw [h_head u rfl, h_sorted]
    rfl

/-- The tail of a strictly ascending list is strictly ascending. -/
theorem pathSorted_tail (t : CellTag) (l : List CellTag)
    (h : pathSorted (t :: l) = true) : pathSorted l = true := by
  cases l with
  | nil => rfl
  | cons v tl =>
    have h' : (pathLess (smtCellKey t) (smtCellKey v) && pathSorted (v :: tl)) = true := h
    exact (Bool.and_eq_true _ _).mp h' |>.2

/-- In a strictly ascending list the head precedes every later entry —
    transitivity, applied down the list. -/
theorem pathSorted_head_lt :
    ∀ (t : CellTag) (l : List CellTag) (u : CellTag),
      pathSorted (t :: l) = true → u ∈ l →
      pathLess (smtCellKey t) (smtCellKey u) = true := by
  intro t l
  induction l generalizing t with
  | nil => intro u _ hu; simp at hu
  | cons v tl ih =>
    intro u h hu
    have h' : (pathLess (smtCellKey t) (smtCellKey v) && pathSorted (v :: tl)) = true := h
    obtain ⟨h_tv, h_rest⟩ := (Bool.and_eq_true _ _).mp h'
    rcases List.mem_cons.mp hu with h'' | h''
    · exact h'' ▸ h_tv
    · exact pathLess_trans _ _ _ h_tv (ih v u h_rest h'')

/-- **Insertion preserves sortedness.**

    Three branches and each is a different fact: the collapse returns
    the list untouched; the prepend is licensed by the guard itself;
    and the fall-through needs TOTALITY — the inserted key did not
    precede the head and is not equal to it, so the head precedes it,
    which is what keeps the head in front of whatever the recursion
    produces. -/
theorem pathSorted_frontierInsert (t : CellTag) (l : List CellTag)
    (h_sorted : pathSorted l = true)
    (h_sep : ∀ u ∈ l, smtCellKey t ≠ smtCellKey u →
      divBelow smtDepth (smtCellKey t) (smtCellKey u) ≠ none) :
    pathSorted (frontierInsert t l) = true := by
  induction l with
  | nil => rfl
  | cons u rest ih =>
    unfold frontierInsert
    split
    · exact h_sorted
    · rename_i h_ne_key
      split
      · rename_i h_lt
        exact pathSorted_cons t (u :: rest) h_sorted
          (fun v hv => by cases hv; exact h_lt)
      · rename_i h_not_lt
        -- The head precedes the inserted key, by totality.
        have h_ul : pathLess (smtCellKey u) (smtCellKey t) = true :=
          pathLess_total (smtCellKey t) (smtCellKey u)
            (h_sep u List.mem_cons_self (by simpa using h_ne_key))
            (by simpa using h_not_lt)
        have h_rest : pathSorted rest = true := pathSorted_tail u rest h_sorted
        have h_ih := ih h_rest
          (fun v hv hne => h_sep v (List.mem_cons_of_mem _ hv) hne)
        refine pathSorted_cons u (frontierInsert t rest) h_ih (fun v hv => ?_)
        -- The head of the recursion is either `t` or `rest`'s head,
        -- and `u` precedes both.
        have h_mem : v ∈ frontierInsert t rest := List.mem_of_mem_head? hv
        rcases mem_frontierInsert t v rest h_mem with h' | h'
        · exact h' ▸ h_ul
        · cases rest with
          | nil => simp at h'
          | cons w tl =>
            have h_uw : pathLess (smtCellKey u) (smtCellKey w) = true := by
              have h' : (pathLess (smtCellKey u) (smtCellKey w)
                          && pathSorted (w :: tl)) = true := h_sorted
              exact ((Bool.and_eq_true _ _).mp h').1
            rcases List.mem_cons.mp h' with h'' | h''
            · exact h'' ▸ h_uw
            · -- `w` precedes every later entry, and `u` precedes `w`.
              have h_wv : pathLess (smtCellKey w) (smtCellKey v) = true :=
                pathSorted_head_lt w tl v (pathSorted_tail u (w :: tl) h_sorted) h''
              exact pathLess_trans _ _ _ h_uw h_wv

/-- **Every frontier is strictly ascending** — and therefore
    key-distinct, which is the property `frontierShapeOk` turns on.

    Unconditional, because `keysSeparated_cellTags` is.  The write set
    it is built from needs no hypothesis at all: whatever cells a step
    touches, the tree can order them. -/
theorem pathSorted_frontierOf (ts : List CellTag) :
    pathSorted (frontierOf ts) = true := by
  induction ts with
  | nil => rfl
  | cons t rest ih =>
    show pathSorted (frontierInsert t (frontierOf rest)) = true
    refine pathSorted_frontierInsert t (frontierOf rest) ih (fun u _ hne => ?_)
    exact keysSeparated_cellTags [t, u] t (by simp) u (by simp) hne

/-- **Strict ascent IS distinctness.**  The claim `frontierShapeOk`'s
    docstring makes — "one comparison rather than two" — as a theorem:
    a strictly ascending list has no key twice, because `pathLess` is
    irreflexive and the head precedes every later entry. -/
theorem pathSorted_keys_nodup (l : List CellTag) (h : pathSorted l = true) :
    ∀ (t : CellTag) (rest : List CellTag), l = t :: rest →
      ∀ u ∈ rest, smtCellKey u ≠ smtCellKey t := by
  intro t rest h_eq u hu h_key
  subst h_eq
  have h_lt := pathSorted_head_lt t rest u h hu
  rw [h_key, pathLess_irrefl] at h_lt
  exact Bool.noConfusion h_lt

/-- The frontier's keys are pairwise distinct, all the way down. -/
theorem frontierOf_keys_nodup (ts : List CellTag) :
    (frontierOf ts).map smtCellKey |>.Nodup := by
  -- Induction on the SORTED list rather than on `ts`: distinctness is
  -- a property of the result's order, and the order is what
  -- `pathSorted_frontierOf` established.
  have h_sorted := pathSorted_frontierOf ts
  generalize frontierOf ts = l at h_sorted
  induction l with
  | nil => simp
  | cons t rest ih =>
    rw [List.map_cons]
    refine List.nodup_cons.mpr ⟨fun h_mem => ?_, ih (pathSorted_tail t rest h_sorted)⟩
    obtain ⟨u, hu, h_eq⟩ := List.mem_map.mp h_mem
    exact (pathSorted_keys_nodup (t :: rest) h_sorted t rest rfl u hu) h_eq

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

/-- `aliasConsistent` unpacked: two entries sharing a key share a
    value. -/
theorem aliasConsistent_elim {α β : Type} [BEq α] [LawfulBEq α]
    [BEq β] [LawfulBEq β] (l : List (α × β)) (h : aliasConsistent l = true)
    (p q : α × β) (hp : p ∈ l) (hq : q ∈ l) (hk : p.1 = q.1) : p.2 = q.2 := by
  unfold aliasConsistent at h
  have h1 := List.all_eq_true.mp h p hp
  have h2 := List.all_eq_true.mp h1 q hq
  simpa [hk] using h2

/-- **A named cell reads back its value.**  In an alias-consistent plan
    the lookup finds the entry rather than refusing.

    This is what makes `plannedBalanceAt?`'s fail-closed branch free:
    composed with `plannedBalances_alias_consistent` it says every plan
    an action can produce answers every cell it names. -/
theorem plannedBalanceAt?_of_mem (plan : List ((ResourceId × ActorId) × Nat))
    (r : ResourceId) (a : ActorId) (v : Nat)
    (h_mem : ((r, a), v) ∈ plan) (h_cons : aliasConsistent plan = true) :
    plannedBalanceAt? plan r a = some v := by
  unfold plannedBalanceAt?
  have h_memf : ((r, a), v) ∈ plan.filter (fun p => p.1 == (r, a)) :=
    List.mem_filter.mpr ⟨h_mem, by simp⟩
  -- Every surviving entry has key `(r, a)`, so consistency pins all
  -- their values to `v` — the head's included.
  have h_val : ∀ q ∈ plan.filter (fun p => p.1 == (r, a)), q.2 = v := by
    intro q hq
    obtain ⟨hq_plan, hq_key⟩ := List.mem_filter.mp hq
    exact aliasConsistent_elim plan h_cons q ((r, a), v) hq_plan h_mem
      (by simpa using hq_key)
  cases h_f : plan.filter (fun p => p.1 == (r, a)) with
  | nil => rw [h_f] at h_memf; simp at h_memf
  | cons w ws =>
    have hw : w.2 = v := h_val w (h_f ▸ List.mem_cons_self)
    have h_tail : (ws.all fun q => q.2 == w.2) = true :=
      List.all_eq_true.mpr (fun q hq => by
        have : q.2 = v := h_val q (h_f ▸ List.mem_cons_of_mem _ hq)
        simp [this, hw])
    show (match w :: ws with
          | [] => none
          | u :: us => if (us.all fun q => q.2 == u.2) = true then some u.2 else none)
        = some v
    simp only []
    rw [if_pos h_tail, hw]

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

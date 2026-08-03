-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.MultiProof — one walk for many cells.

`docs/planning/state_root_merkleisation_plan.md` §6.  A chained fold
walks the tree once per opening, and every opening carries a full
256-level sibling path even where those paths coincide.  Near the root
they always coincide: `m` keys share the top levels, and the deeper
they diverge the more the chained encoding repeats.

The multiproof walks once.  It descends the tree with the whole key set
at once, splitting it at each level exactly as `smtRootListAux` splits
the entries; where both halves still hold an opened key it recurses
into both and hashes their results, and where only one does it reads a
SIBLING from the wire.  Those reads are the "gaps", and their number is
a function of the key set alone — which is what lets the verifier
demand an exact proof length instead of padding a short one.

## Why the recursion mirrors `smtRootListAux`

Because then the completeness theorem is the same induction as
`canonicalSiblings_walks_from_bucket`, with the same base case
(`bucketAt`, which covers a present cell and an absent one uniformly)
and the same split.  A bottom-up formulation would need a
bottom-up/top-down bridge; a level-order wire would need a permutation
lemma.  Post-order falls out of the recursion's own concatenation, so
the wire's order is not a separate thing to prove.

## The remaining-siblings threading

`multiWalk` returns the unconsumed tail rather than requiring the
caller to know how many siblings a subtree eats.  That is what makes
`multiWalk_append` — walk a subtree, get its root and the untouched
remainder — provable by structural induction, and the headline is its
`tail = []` instance.
-/

import LegalKernel.FaultProof.Frontier
import LegalKernel.FaultProof.StateCellsInjective

open LegalKernel.Authority
open LegalKernel.Runtime

namespace LegalKernel.FaultProof

/-- An opened cell: its SMT key, and the leaf its value hashes to.

    The leaf rather than the value, because a cell the state does not
    hold opens from the canonical EMPTY leaf rather than from a hash of
    its absent marker — `cellLeaf` makes that branch, and a step reads
    absent cells constantly (crediting a fresh actor is the common
    case). -/
abbrev OpenedLeaf := ByteArray × ByteArray

/-! ## The split -/

/-- The entries whose key has bit `d` clear — `smtRootListAux`'s left
    half. -/
def lowHalf (d : Nat) (entries : SmtEntries) : SmtEntries :=
  entries.filter (fun e => ! BitsKey.keyBit e.1 d)

/-- The entries whose key has bit `d` set — the right half. -/
def highHalf (d : Nat) (entries : SmtEntries) : SmtEntries :=
  entries.filter (fun e => BitsKey.keyBit e.1 d)

/-- The opened cells in the left half. -/
def openedLow (d : Nat) (opened : List OpenedLeaf) : List OpenedLeaf :=
  opened.filter (fun o => ! BitsKey.keyBit o.1 d)

/-- The opened cells in the right half. -/
def openedHigh (d : Nat) (opened : List OpenedLeaf) : List OpenedLeaf :=
  opened.filter (fun o => BitsKey.keyBit o.1 d)

/-- **The root splits, at every depth and for every bucket.**

    Definitional for a non-empty bucket; for an empty one both sides
    reduce to the canonical empty root, which is what
    `emptyRootAt (d+1) = hashBytes (emptyRootAt d ++ emptyRootAt d)`
    says.  Stating it unconditionally is what lets the induction below
    ignore whether a sub-tree is populated — and a multiproof's
    sub-trees frequently are not, since every absent cell it opens
    lands in an empty one. -/
theorem smtRootListAux_succ_split (d : Nat) (h : d + 1 ≤ 256) (entries : SmtEntries) :
    smtRootListAux (d + 1) entries
      = hashBytes (smtRootListAux d (lowHalf d entries)
                ++ smtRootListAux d (highHalf d entries)) := by
  cases h_e : entries with
  | nil =>
    have h_lo : lowHalf d ([] : SmtEntries) = [] := rfl
    have h_hi : highHalf d ([] : SmtEntries) = [] := rfl
    rw [h_lo, h_hi, smtRootListAux_nil d (by omega), smtRootListAux_nil (d + 1) h]
    rfl
  | cons hd tl =>
    show (if (hd :: tl).isEmpty then _ else
            hashBytes (smtRootListAux d ((hd :: tl).filter _)
                    ++ smtRootListAux d ((hd :: tl).filter _))) = _
    rw [if_neg (by simp)]
    rfl

/-! ## The walk -/

/-- **The merged walk.**  Descend with the whole opened set, splitting
    at each level as the tree does, and return the sub-tree's root
    together with the siblings it did NOT consume.

    Returning the remainder is what makes the induction work: a caller
    need not know how many gaps a sub-tree eats, so the two recursive
    calls at a merge thread naturally.

    `none` on any malformed input — an empty opened set, a depth-0
    bucket holding more than one opened cell, or a wire that runs out
    of siblings.  Running out is a REFUSAL here, where the chained
    verifier substitutes `PADDING_HASH` and walks on. -/
def multiWalk : Nat → List OpenedLeaf → List ByteArray →
    Option (ByteArray × List ByteArray)
  | 0, opened, sibs =>
    match opened with
    | [(_, leaf)] => some (leaf, sibs)
    | _           => none
  | d + 1, opened, sibs =>
    match (openedLow d opened), (openedHigh d opened) with
    | [],         []         => none
    | (lo :: los), []        =>
      match multiWalk d (lo :: los) sibs with
      | some (r, s :: rest) => some (hashBytes (r ++ s), rest)
      | _                   => none
    | [],         (hi :: his) =>
      match multiWalk d (hi :: his) sibs with
      | some (r, s :: rest) => some (hashBytes (s ++ r), rest)
      | _                   => none
    | (lo :: los), (hi :: his) =>
      match multiWalk d (lo :: los) sibs with
      | some (rl, rest₁) =>
        match multiWalk d (hi :: his) rest₁ with
        | some (rh, rest₂) => some (hashBytes (rl ++ rh), rest₂)
        | none             => none
      | none => none

/-- **The honest prover's gaps**, in the order the walk consumes them:
    the left sub-tree's, then the right's, then this level's if only
    one side holds an opened cell.

    Post-order, and not by preference — it is the order the recursion's
    own `++` produces, so the wire needs no re-indexing lemma between
    what Lean builds and what the walk reads. -/
def multiSiblings : Nat → SmtEntries → List OpenedLeaf → List ByteArray
  | 0, _, _ => []
  | d + 1, entries, opened =>
    match (openedLow d opened), (openedHigh d opened) with
    | [],          []         => []
    | (lo :: los), []         =>
      multiSiblings d (lowHalf d entries) (lo :: los)
        ++ [smtRootListAux d (highHalf d entries)]
    | [],          (hi :: his) =>
      multiSiblings d (highHalf d entries) (hi :: his)
        ++ [smtRootListAux d (lowHalf d entries)]
    | (lo :: los), (hi :: his) =>
      multiSiblings d (lowHalf d entries) (lo :: los)
        ++ multiSiblings d (highHalf d entries) (hi :: his)

/-! ## Completeness -/

/-- Every opened cell's leaf is the root of the depth-0 bucket its key
    reaches — the hypothesis that covers a present cell and an absent
    one at once, exactly as `canonicalSiblings_walks_from_bucket`'s
    does for a single opening. -/
def LeavesCoherent (d : Nat) (entries : SmtEntries) (opened : List OpenedLeaf) : Prop :=
  ∀ o ∈ opened, smtRootListAux 0 (bucketAt d entries o.1) = o.2

/-- Coherence descends into the left half: an opened cell with bit `d`
    clear reaches the same bucket through the filtered entries. -/
theorem LeavesCoherent_low (d : Nat) (entries : SmtEntries) (opened : List OpenedLeaf)
    (h : LeavesCoherent (d + 1) entries opened) :
    LeavesCoherent d (lowHalf d entries) (openedLow d opened) := by
  intro o ho
  have hf := List.mem_filter.mp ho
  have h_bit : ¬ BitsKey.keyBit o.1 d := by simpa using hf.2
  have h_prev := h o hf.1
  have h_b : bucketAt (d + 1) entries o.1 = bucketAt d (lowHalf d entries) o.1 := by
    show bucketAt d (if BitsKey.keyBit o.1 d then _ else _) o.1 = _
    rw [if_neg h_bit]
    rfl
  rwa [h_b] at h_prev

/-- Coherence descends into the right half. -/
theorem LeavesCoherent_high (d : Nat) (entries : SmtEntries) (opened : List OpenedLeaf)
    (h : LeavesCoherent (d + 1) entries opened) :
    LeavesCoherent d (highHalf d entries) (openedHigh d opened) := by
  intro o ho
  have hf := List.mem_filter.mp ho
  have h_bit : BitsKey.keyBit o.1 d := by simpa using hf.2
  have h_prev := h o hf.1
  have h_b : bucketAt (d + 1) entries o.1 = bucketAt d (highHalf d entries) o.1 := by
    show bucketAt d (if BitsKey.keyBit o.1 d then _ else _) o.1 = _
    rw [if_pos h_bit]
    rfl
  rwa [h_b] at h_prev

/-- **The merged walk reproduces the root, consuming exactly its own
    gaps.**

    The `m`-key generalisation of `canonicalSiblings_walks_from_bucket`,
    and the honest prover's guarantee: the single bundle it can build
    is one the verifier accepts, and the root the verifier reaches from
    it is the root the tree has.

    `BitsDistinctBelow` is load-bearing rather than decorative — it is
    what forces at most ONE opened cell into each depth-0 bucket.
    Without it two opened cells could share a bucket, the walk would
    refuse, and the theorem would be false; with it the refusal branch
    is unreachable.  The frontier supplies it by construction, since a
    strictly-ascending list has distinct keys.

    Stated with an arbitrary `tail` because that is what the induction
    needs — a merge threads the left sub-tree's remainder into the
    right's — and the headline is its `tail = []` instance below. -/
theorem multiWalk_append :
    ∀ (d : Nat), d ≤ 256 → ∀ (entries : SmtEntries) (opened : List OpenedLeaf)
      (tail : List ByteArray),
      opened ≠ [] → LeavesCoherent d entries opened → BitsDistinctBelow d opened →
      multiWalk d opened (multiSiblings d entries opened ++ tail)
        = some (smtRootListAux d entries, tail) := by
  intro d
  induction d with
  | zero =>
    intro _ entries opened tail h_ne h_coh h_dist
    cases opened with
    | nil => exact absurd rfl h_ne
    | cons a rest =>
      cases rest with
      | cons b rest' =>
        -- Two opened cells in one depth-0 bucket: excluded by
        -- distinctness, which is why the walk may refuse it.
        have h_len := length_le_one_of_bitsDistinctBelow_zero h_dist
        simp at h_len
      | nil =>
        obtain ⟨k, leaf⟩ := a
        have h1 := h_coh (k, leaf) (by simp)
        show some (leaf, [] ++ tail) = some (smtRootListAux 0 entries, tail)
        rw [List.nil_append, show bucketAt 0 entries k = entries from rfl] at *
        rw [h1]
  | succ k ih =>
    intro h_le entries opened tail h_ne h_coh h_dist
    have h_k : k ≤ 256 := by omega
    have h_split := smtRootListAux_succ_split k h_le entries
    have h_lo := LeavesCoherent_low k entries opened h_coh
    have h_hi := LeavesCoherent_high k entries opened h_coh
    have h_dlo : BitsDistinctBelow k (openedLow k opened) :=
      BitsDistinctBelow.filter_low h_dist
    have h_dhi : BitsDistinctBelow k (openedHigh k opened) :=
      BitsDistinctBelow.filter_high h_dist
    cases h_l : openedLow k opened with
    | nil =>
      cases h_h : openedHigh k opened with
      | nil =>
        -- Neither half holds an opened cell, so `opened` is empty.
        refine absurd ?_ h_ne
        cases h_o : opened with
        | nil => rfl
        | cons o rest =>
          by_cases hb : BitsKey.keyBit o.1 k
          · have hm : o ∈ openedHigh k opened :=
              List.mem_filter.mpr ⟨by rw [h_o]; simp, by simpa using hb⟩
            rw [h_h] at hm; exact absurd hm (by simp)
          · have hm : o ∈ openedLow k opened :=
              List.mem_filter.mpr ⟨by rw [h_o]; simp, by simpa using hb⟩
            rw [h_l] at hm; exact absurd hm (by simp)
      | cons hi his =>
        have h_sibs : multiSiblings (k + 1) entries opened
                    = multiSiblings k (highHalf k entries) (hi :: his)
                        ++ [smtRootListAux k (lowHalf k entries)] := by
          show (match openedLow k opened, openedHigh k opened with
                | [], [] => _ | (_ :: _), [] => _
                | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
          rw [h_l, h_h]
        show (match openedLow k opened, openedHigh k opened with
              | [], [] => none | (_ :: _), [] => _
              | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
        rw [h_l, h_h, h_sibs, List.append_assoc, List.cons_append, List.nil_append]
        simp only []
        rw [ih h_k (highHalf k entries) (hi :: his)
            (smtRootListAux k (lowHalf k entries) :: tail) (by simp)
            (h_h ▸ h_hi) (h_h ▸ h_dhi)]
        rw [h_split]
    | cons lo los =>
      cases h_h : openedHigh k opened with
      | nil =>
        have h_sibs : multiSiblings (k + 1) entries opened
                    = multiSiblings k (lowHalf k entries) (lo :: los)
                        ++ [smtRootListAux k (highHalf k entries)] := by
          show (match openedLow k opened, openedHigh k opened with
                | [], [] => _ | (_ :: _), [] => _
                | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
          rw [h_l, h_h]
        show (match openedLow k opened, openedHigh k opened with
              | [], [] => none | (_ :: _), [] => _
              | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
        rw [h_l, h_h, h_sibs, List.append_assoc, List.cons_append, List.nil_append]
        simp only []
        rw [ih h_k (lowHalf k entries) (lo :: los)
            (smtRootListAux k (highHalf k entries) :: tail) (by simp)
            (h_l ▸ h_lo) (h_l ▸ h_dlo)]
        rw [h_split]
      | cons hi his =>
        have h_sibs : multiSiblings (k + 1) entries opened
                    = multiSiblings k (lowHalf k entries) (lo :: los)
                        ++ multiSiblings k (highHalf k entries) (hi :: his) := by
          show (match openedLow k opened, openedHigh k opened with
                | [], [] => _ | (_ :: _), [] => _
                | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
          rw [h_l, h_h]
        show (match openedLow k opened, openedHigh k opened with
              | [], [] => none | (_ :: _), [] => _
              | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
        rw [h_l, h_h, h_sibs, List.append_assoc]
        simp only []
        rw [ih h_k (lowHalf k entries) (lo :: los)
            (multiSiblings k (highHalf k entries) (hi :: his) ++ tail) (by simp)
            (h_l ▸ h_lo) (h_l ▸ h_dlo)]
        simp only []
        rw [ih h_k (highHalf k entries) (hi :: his) tail (by simp)
            (h_h ▸ h_hi) (h_h ▸ h_dhi)]
        rw [h_split]

/-- **Completeness.**  The honest bundle walks to the published root
    and consumes every sibling it carries — no remainder, so a wire
    with a trailing extra is not silently ignored. -/
theorem multiWalk_eq_smtRootListAux (entries : SmtEntries) (opened : List OpenedLeaf)
    (h_ne : opened ≠ []) (h_coh : LeavesCoherent smtDepth entries opened)
    (h_dist : BitsDistinctBelow smtDepth opened) :
    multiWalk smtDepth opened (multiSiblings smtDepth entries opened)
      = some (smtRootListAux smtDepth entries, []) := by
  have := multiWalk_append smtDepth (by decide) entries opened [] h_ne h_coh h_dist
  rwa [List.append_nil] at this

/-! ## Degeneracy at one key

A single-cell multiproof is the single-cell opening.  That is what
makes the wire a WIDENING rather than a break: at `m = 1` the gap count
is 256, the mask is 32 bytes, and the sibling order is depth-0-first —
byte-for-byte what `proofData` already carries. -/

/-- **One opened cell reproduces the canonical path.**

    Both recursions descend into the half holding the key and append
    that level's sibling afterwards, so the post-order convention and
    `canonicalSiblings`' depth-0-first order are the same order when
    there is only one path. -/
theorem multiSiblings_single :
    ∀ (d : Nat) (entries : SmtEntries) (k leaf : ByteArray),
      multiSiblings d entries [(k, leaf)] = canonicalSiblings d entries k := by
  intro d
  induction d with
  | zero => intro _ _ _; rfl
  | succ i ih =>
    intro entries k leaf
    by_cases hb : BitsKey.keyBit k i
    · have h_l : openedLow i [(k, leaf)] = [] := by
        show List.filter _ [(k, leaf)] = []
        simp [hb]
      have h_h : openedHigh i [(k, leaf)] = [(k, leaf)] := by
        show List.filter _ [(k, leaf)] = _
        simp [hb]
      show (match openedLow i [(k, leaf)], openedHigh i [(k, leaf)] with
            | [], [] => _ | (_ :: _), [] => _
            | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
      rw [h_l, h_h]
      simp only []
      show multiSiblings i (highHalf i entries) [(k, leaf)]
             ++ [smtRootListAux i (lowHalf i entries)] = _
      rw [ih (highHalf i entries) k leaf]
      show _ = (if BitsKey.keyBit k i then _ else _)
      rw [if_pos hb]
      rfl
    · have h_l : openedLow i [(k, leaf)] = [(k, leaf)] := by
        show List.filter _ [(k, leaf)] = _
        simp [hb]
      have h_h : openedHigh i [(k, leaf)] = [] := by
        show List.filter _ [(k, leaf)] = []
        simp [hb]
      show (match openedLow i [(k, leaf)], openedHigh i [(k, leaf)] with
            | [], [] => _ | (_ :: _), [] => _
            | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
      rw [h_l, h_h]
      simp only []
      show multiSiblings i (lowHalf i entries) [(k, leaf)]
             ++ [smtRootListAux i (highHalf i entries)] = _
      rw [ih (lowHalf i entries) k leaf]
      show _ = (if BitsKey.keyBit k i then _ else _)
      rw [if_neg hb]
      rfl

/-- The single-cell multiproof carries exactly 256 siblings — one per
    level, which is the uncompressed path `SmtCellProof` encodes. -/
theorem multiSiblings_single_length (d : Nat) (entries : SmtEntries)
    (k leaf : ByteArray) :
    (multiSiblings d entries [(k, leaf)]).length = d := by
  rw [multiSiblings_single, canonicalSiblings_length]

/-! ## The post-state's root, from the pre-state's siblings

The whole economy of a pre-root multiproof is that ONE sibling list
serves both roots: the one the bundle opens against, and the one the
step's writes produce.  That is sound because a sibling is the root of
a sub-tree containing NO opened cell, and the writes touch only opened
cells — so the sub-tree is byte-identical in both states.

Stating that needs a hypothesis relating the two entry lists.  The
obvious one — "drop the opened keys from both and the remainders are a
permutation" — forces a key-set filter through the whole induction and
an awkward re-derivation at every level, because the recursion shrinks
the opened list while the key set would have to stay fixed.

The hypothesis below is pointwise instead: an entry whose key is NOT
opened is in one list exactly when it is in the other.  It descends
into a half for free, because an entry in the low half can only be
matched by an opened cell in the low half. -/

/-- Two entry lists agree away from the opened cells: an entry whose
    key no opened cell names belongs to one exactly when it belongs to
    the other. -/
def AgreeOffOpened (opened : List OpenedLeaf) (e e' : SmtEntries) : Prop :=
  ∀ p : ByteArray × ByteArray, (¬ ∃ o ∈ opened, o.1 = p.1) → (p ∈ e ↔ p ∈ e')

/-- Agreement descends into the left half: an entry with bit `d` clear
    can only be named by an opened cell with bit `d` clear. -/
theorem AgreeOffOpened_low (d : Nat) (opened : List OpenedLeaf) (e e' : SmtEntries)
    (h : AgreeOffOpened opened e e') :
    AgreeOffOpened (openedLow d opened) (lowHalf d e) (lowHalf d e') := by
  intro p hp
  by_cases hbit : BitsKey.keyBit p.1 d
  · -- Not in either half; both sides are false.
    constructor
    · intro hm; exact absurd (by simpa using (List.mem_filter.mp hm).2) (by simp [hbit])
    · intro hm; exact absurd (by simpa using (List.mem_filter.mp hm).2) (by simp [hbit])
  · have h_full : ¬ ∃ o ∈ opened, o.1 = p.1 := by
      rintro ⟨o, ho, h_eq⟩
      exact hp ⟨o, List.mem_filter.mpr ⟨ho, by simpa [h_eq] using hbit⟩, h_eq⟩
    constructor
    · intro hm
      exact List.mem_filter.mpr ⟨(h p h_full).mp (List.mem_filter.mp hm).1,
        (List.mem_filter.mp hm).2⟩
    · intro hm
      exact List.mem_filter.mpr ⟨(h p h_full).mpr (List.mem_filter.mp hm).1,
        (List.mem_filter.mp hm).2⟩

/-- Agreement descends into the right half. -/
theorem AgreeOffOpened_high (d : Nat) (opened : List OpenedLeaf) (e e' : SmtEntries)
    (h : AgreeOffOpened opened e e') :
    AgreeOffOpened (openedHigh d opened) (highHalf d e) (highHalf d e') := by
  intro p hp
  by_cases hbit : BitsKey.keyBit p.1 d
  · have h_full : ¬ ∃ o ∈ opened, o.1 = p.1 := by
      rintro ⟨o, ho, h_eq⟩
      exact hp ⟨o, List.mem_filter.mpr ⟨ho, by simpa [h_eq] using hbit⟩, h_eq⟩
    constructor
    · intro hm
      exact List.mem_filter.mpr ⟨(h p h_full).mp (List.mem_filter.mp hm).1,
        (List.mem_filter.mp hm).2⟩
    · intro hm
      exact List.mem_filter.mpr ⟨(h p h_full).mpr (List.mem_filter.mp hm).1,
        (List.mem_filter.mp hm).2⟩
  · constructor
    · intro hm; exact absurd (List.mem_filter.mp hm).2 (by simpa using hbit)
    · intro hm; exact absurd (List.mem_filter.mp hm).2 (by simpa using hbit)

/-- **A gap sub-tree is the same in both states.**

    Where no opened cell lands, the two entry lists coincide as sets —
    and being duplicate-free, as permutations — so their roots are
    equal.  This is the sibling-reuse argument in its smallest form. -/
theorem gapRoot_congr (d : Nat) (opened : List OpenedLeaf) (e e' : SmtEntries)
    (h : AgreeOffOpened opened e e') (h_none : opened = [])
    (h_wf : BitsDistinctBelow d e) (h_wf' : BitsDistinctBelow d e') :
    smtRootListAux d e = smtRootListAux d e' := by
  refine smtRootListAux_perm d e e' ?_ h_wf
  refine perm_of_nodup_of_mem_iff _ _ (nodup_of_bitsDistinct h_wf)
    (nodup_of_bitsDistinct h_wf') (fun p => ?_)
  exact h p (by rw [h_none]; rintro ⟨_, hm, _⟩; exact absurd hm (by simp))

/-! ### Unfolding `multiSiblings` at a level

Three shapes, each stated once and used for both entry lists, so a
congruence proof rewrites rather than re-derives. -/

/-- Only the right half holds an opened cell: recurse there, and this
    level's sibling is the left half's root. -/
theorem multiSiblings_succ_gapLow (k : Nat) (entries : SmtEntries)
    (opened : List OpenedLeaf) (hi : OpenedLeaf) (his : List OpenedLeaf)
    (h_l : openedLow k opened = []) (h_h : openedHigh k opened = hi :: his) :
    multiSiblings (k + 1) entries opened
      = multiSiblings k (highHalf k entries) (hi :: his)
          ++ [smtRootListAux k (lowHalf k entries)] := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- Only the left half holds an opened cell. -/
theorem multiSiblings_succ_gapHigh (k : Nat) (entries : SmtEntries)
    (opened : List OpenedLeaf) (lo : OpenedLeaf) (los : List OpenedLeaf)
    (h_l : openedLow k opened = lo :: los) (h_h : openedHigh k opened = []) :
    multiSiblings (k + 1) entries opened
      = multiSiblings k (lowHalf k entries) (lo :: los)
          ++ [smtRootListAux k (highHalf k entries)] := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- Both halves hold an opened cell: a MERGE, which reads no sibling
    from the wire — the two sub-trees are each other's. -/
theorem multiSiblings_succ_merge (k : Nat) (entries : SmtEntries)
    (opened : List OpenedLeaf) (lo hi : OpenedLeaf) (los his : List OpenedLeaf)
    (h_l : openedLow k opened = lo :: los) (h_h : openedHigh k opened = hi :: his) :
    multiSiblings (k + 1) entries opened
      = multiSiblings k (lowHalf k entries) (lo :: los)
          ++ multiSiblings k (highHalf k entries) (hi :: his) := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- Neither half holds an opened cell: no gaps at all. -/
theorem multiSiblings_succ_empty (k : Nat) (entries : SmtEntries)
    (opened : List OpenedLeaf)
    (h_l : openedLow k opened = []) (h_h : openedHigh k opened = []) :
    multiSiblings (k + 1) entries opened = [] := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- **The pre-state's sibling list serves the post-state too.**

    The theorem the whole multiproof rests on: an honest bundle carries
    ONE set of siblings, and it is valid against both roots.  Every
    sibling it carries is a gap — a sub-tree holding no opened cell —
    and `gapRoot_congr` says such a sub-tree is unchanged. -/
theorem multiSiblings_congr :
    ∀ (d : Nat) (e e' : SmtEntries) (opened : List OpenedLeaf),
      AgreeOffOpened opened e e' →
      BitsDistinctBelow d e → BitsDistinctBelow d e' →
      multiSiblings d e opened = multiSiblings d e' opened := by
  intro d
  induction d with
  | zero => intro _ _ _ _ _ _; rfl
  | succ k ih =>
    intro e e' opened h_ag h_wf h_wf'
    have h_lo := AgreeOffOpened_low k opened e e' h_ag
    have h_hi := AgreeOffOpened_high k opened e e' h_ag
    have h_wlo : BitsDistinctBelow k (lowHalf k e) := BitsDistinctBelow.filter_low h_wf
    have h_whi : BitsDistinctBelow k (highHalf k e) := BitsDistinctBelow.filter_high h_wf
    have h_wlo' : BitsDistinctBelow k (lowHalf k e') := BitsDistinctBelow.filter_low h_wf'
    have h_whi' : BitsDistinctBelow k (highHalf k e') := BitsDistinctBelow.filter_high h_wf'
    cases h_l : openedLow k opened with
    | nil =>
      cases h_h : openedHigh k opened with
      | nil =>
        rw [multiSiblings_succ_empty k e opened h_l h_h,
          multiSiblings_succ_empty k e' opened h_l h_h]
      | cons hi his =>
        rw [multiSiblings_succ_gapLow k e opened hi his h_l h_h,
          multiSiblings_succ_gapLow k e' opened hi his h_l h_h,
          ih (highHalf k e) (highHalf k e') (hi :: his) (h_h ▸ h_hi) h_whi h_whi',
          gapRoot_congr k (openedLow k opened) (lowHalf k e) (lowHalf k e')
            h_lo h_l h_wlo h_wlo']
    | cons lo los =>
      cases h_h : openedHigh k opened with
      | nil =>
        rw [multiSiblings_succ_gapHigh k e opened lo los h_l h_h,
          multiSiblings_succ_gapHigh k e' opened lo los h_l h_h,
          ih (lowHalf k e) (lowHalf k e') (lo :: los) (h_l ▸ h_lo) h_wlo h_wlo',
          gapRoot_congr k (openedHigh k opened) (highHalf k e) (highHalf k e')
            h_hi h_h h_whi h_whi']
      | cons hi his =>
        rw [multiSiblings_succ_merge k e opened lo hi los his h_l h_h,
          multiSiblings_succ_merge k e' opened lo hi los his h_l h_h,
          ih (lowHalf k e) (lowHalf k e') (lo :: los) (h_l ▸ h_lo) h_wlo h_wlo',
          ih (highHalf k e) (highHalf k e') (hi :: his) (h_h ▸ h_hi) h_whi h_whi']

/-! ## The two roots

`multiSiblings` reads its opened list only through the KEYS — every
split filters on `o.1`, and only the depth-0 base case looks at a leaf.
So the same wire serves a bundle carrying pre-values and one carrying
post-values, which is what makes "one sibling list, two roots"
precise. -/

/-- Filtering on the key commutes with taking keys. -/
theorem map_fst_filter (p : ByteArray → Bool) :
    ∀ (l : List OpenedLeaf),
      (l.filter (fun o => p o.1)).map Prod.fst = (l.map Prod.fst).filter p := by
  intro l
  induction l with
  | nil => rfl
  | cons o rest ih =>
    by_cases hp : p o.1
    · simp [hp, ih]
    · simp [hp, ih]

/-- Two bundles with the same keys have the same halves. -/
theorem openedLow_key_congr (d : Nat) (o₁ o₂ : List OpenedLeaf)
    (h : o₁.map Prod.fst = o₂.map Prod.fst) :
    (openedLow d o₁).map Prod.fst = (openedLow d o₂).map Prod.fst := by
  unfold openedLow
  rw [map_fst_filter (fun k => ! BitsKey.keyBit k d) o₁,
    map_fst_filter (fun k => ! BitsKey.keyBit k d) o₂, h]

/-- ...and the same right halves. -/
theorem openedHigh_key_congr (d : Nat) (o₁ o₂ : List OpenedLeaf)
    (h : o₁.map Prod.fst = o₂.map Prod.fst) :
    (openedHigh d o₁).map Prod.fst = (openedHigh d o₂).map Prod.fst := by
  unfold openedHigh
  rw [map_fst_filter (fun k => BitsKey.keyBit k d) o₁,
    map_fst_filter (fun k => BitsKey.keyBit k d) o₂, h]

/-- A list is empty exactly when its key list is. -/
theorem nil_iff_map_fst_nil (l : List OpenedLeaf) : l = [] ↔ l.map Prod.fst = [] := by
  cases l <;> simp

/-- **The wire does not depend on the leaves.**  Two bundles opening
    the same cells produce the same sibling list, whatever values they
    carry — which is why one wire serves the pre-root and the post-root
    alike. -/
theorem multiSiblings_key_congr :
    ∀ (d : Nat) (e : SmtEntries) (o₁ o₂ : List OpenedLeaf),
      o₁.map Prod.fst = o₂.map Prod.fst →
      multiSiblings d e o₁ = multiSiblings d e o₂ := by
  intro d
  induction d with
  | zero => intro _ _ _ _; rfl
  | succ k ih =>
    intro e o₁ o₂ h
    have h_l := openedLow_key_congr k o₁ o₂ h
    have h_h := openedHigh_key_congr k o₁ o₂ h
    cases h_l₁ : openedLow k o₁ with
    | nil =>
      have h_l₂ : openedLow k o₂ = [] := by
        refine (nil_iff_map_fst_nil _).mpr ?_
        rw [← h_l, h_l₁]; rfl
      cases h_h₁ : openedHigh k o₁ with
      | nil =>
        have h_h₂ : openedHigh k o₂ = [] := by
          refine (nil_iff_map_fst_nil _).mpr ?_
          rw [← h_h, h_h₁]; rfl
        rw [multiSiblings_succ_empty k e o₁ h_l₁ h_h₁,
          multiSiblings_succ_empty k e o₂ h_l₂ h_h₂]
      | cons hi his =>
        cases h_h₂ : openedHigh k o₂ with
        | nil =>
          have hc : ((hi :: his) : List OpenedLeaf).map Prod.fst = [] := by
            rw [← h_h₁, h_h, h_h₂]; rfl
          simp at hc
        | cons hi' his' =>
          rw [multiSiblings_succ_gapLow k e o₁ hi his h_l₁ h_h₁,
            multiSiblings_succ_gapLow k e o₂ hi' his' h_l₂ h_h₂,
            ih (highHalf k e) (hi :: his) (hi' :: his') (by rw [← h_h₁, ← h_h₂, h_h])]
    | cons lo los =>
      have h_l₂ : ∃ lo' los', openedLow k o₂ = lo' :: los' := by
        cases h_c : openedLow k o₂ with
        | nil =>
          have hc : ((lo :: los) : List OpenedLeaf).map Prod.fst = [] := by
            rw [← h_l₁, h_l, h_c]; rfl
          simp at hc
        | cons a b => exact ⟨a, b, rfl⟩
      obtain ⟨lo', los', h_l₂⟩ := h_l₂
      cases h_h₁ : openedHigh k o₁ with
      | nil =>
        have h_h₂ : openedHigh k o₂ = [] := by
          refine (nil_iff_map_fst_nil _).mpr ?_
          rw [← h_h, h_h₁]; rfl
        rw [multiSiblings_succ_gapHigh k e o₁ lo los h_l₁ h_h₁,
          multiSiblings_succ_gapHigh k e o₂ lo' los' h_l₂ h_h₂,
          ih (lowHalf k e) (lo :: los) (lo' :: los') (by rw [← h_l₁, ← h_l₂, h_l])]
      | cons hi his =>
        cases h_h₂ : openedHigh k o₂ with
        | nil =>
          have hc : ((hi :: his) : List OpenedLeaf).map Prod.fst = [] := by
            rw [← h_h₁, h_h, h_h₂]; rfl
          simp at hc
        | cons hi' his' =>
          rw [multiSiblings_succ_merge k e o₁ lo hi los his h_l₁ h_h₁,
            multiSiblings_succ_merge k e o₂ lo' hi' los' his' h_l₂ h_h₂,
            ih (lowHalf k e) (lo :: los) (lo' :: los') (by rw [← h_l₁, ← h_l₂, h_l]),
            ih (highHalf k e) (hi :: his) (hi' :: his') (by rw [← h_h₁, ← h_h₂, h_h])]

/-! ## One wire, two state roots

The step-level statement.  An honest sequencer builds the bundle from
the PRE-state and publishes one sibling list; the L1 folds it twice —
once from the pre-values to check it against the submitted pre-root,
once from the derived post-values to obtain the root it will compare —
and both are the roots the two states actually have. -/

/-- The bundle a state induces for a cell list: each cell's key with
    the leaf that state gives it. -/
def openedOf (es : ExtendedState) (ts : List CellTag) : List OpenedLeaf :=
  ts.map (fun t => (smtCellKey t, cellLeaf t (getCellValue es t)))

/-- The keys a bundle opens are the cells' keys — nothing about the
    state survives into them, which is the fact both congruences use. -/
theorem openedOf_keys_eq (es : ExtendedState) (ts : List CellTag) :
    (openedOf es ts).map Prod.fst = ts.map smtCellKey := by
  simp [openedOf]

/-- Two states induce bundles with the same keys. -/
theorem openedOf_keys (es es' : ExtendedState) (ts : List CellTag) :
    (openedOf es ts).map Prod.fst = (openedOf es' ts).map Prod.fst := by
  rw [openedOf_keys_eq, openedOf_keys_eq]

/-- **The pre-state's wire is the post-state's wire.**

    Both congruences at once: the sibling list does not depend on the
    leaves (`multiSiblings_key_congr`) and does not depend on entries
    away from the opened cells (`multiSiblings_congr`).  Together they
    are the sentence "one bundle, two roots" made precise. -/
theorem multiSiblings_pre_eq_post (es es' : ExtendedState) (ts : List CellTag)
    (h_ag : AgreeOffOpened (openedOf es' ts) (stateCellEntries es) (stateCellEntries es'))
    (h_wf : BitsDistinctBelow smtDepth (stateCellEntries es))
    (h_wf' : BitsDistinctBelow smtDepth (stateCellEntries es')) :
    multiSiblings smtDepth (stateCellEntries es) (openedOf es ts)
      = multiSiblings smtDepth (stateCellEntries es') (openedOf es' ts) := by
  rw [multiSiblings_key_congr smtDepth (stateCellEntries es) (openedOf es ts)
        (openedOf es' ts) (openedOf_keys es es' ts)]
  exact multiSiblings_congr smtDepth (stateCellEntries es) (stateCellEntries es')
    (openedOf es' ts) h_ag h_wf h_wf'

/-! ### Discharging the fold's side conditions

`multiFold_eq_commit_post` takes four properties about the states and
the bundle.  These discharge them for the bundle a state induces,
which is the only bundle an honest sequencer builds — and between
them they say exactly what the multiproof's soundness rests on: the
tree can tell the cells apart, and the step moves nothing it did not
declare.
-/

/-- **A state's own bundle is coherent with its tree.**

    Every leaf `openedOf` claims is the leaf the entries actually put
    at that key, which is `multiWalk`'s completeness hypothesis.

    The absent branch is the substantive one and it is where the key
    hypothesis is spent: a cell whose value is canonically absent must
    have an EMPTY bucket, and that is only true if no LIVE cell hashes
    to the same key.  `stateCellEntries` drops absent cells, so the
    two notions of absence — "reads as the canonical absent value" and
    "has no entry in the tree" — coincide exactly under key
    injectivity.  Without it a colliding live cell would sit under the
    absent cell's key and the claimed empty leaf would be wrong. -/
theorem leavesCoherent_openedOf (es : ExtendedState) (ts : List CellTag)
    (h_bd : BitsDistinctBelow smtDepth (stateCellEntries es))
    (h_key : ∀ t ∈ ts, ∀ u ∈ stateCellTags es, smtCellKey u = smtCellKey t → u = t) :
    LeavesCoherent smtDepth (stateCellEntries es) (openedOf es ts) := by
  intro o ho
  obtain ⟨t, ht, rfl⟩ := List.mem_map.mp ho
  show smtRootListAux 0 (bucketAt smtDepth (stateCellEntries es) (smtCellKey t))
    = cellLeaf t (getCellValue es t)
  by_cases h_abs : getCellValue es t = canonicalAbsentValue t
  · -- Absent: no LIVE cell carries this key, so the bucket is empty
    -- and the walk starts from the canonical empty leaf.
    have h_nil : bucketAt smtDepth (stateCellEntries es) (smtCellKey t) = [] := by
      refine bucketAt_eq_nil_of_not_mem _ _ ?_ (smtCellKey_size t) ?_
      · intro p hp
        obtain ⟨u, _, rfl, _⟩ := stateCellEntries_spec es p hp
        exact smtCellKey_size u
      · intro p hp h_pkey
        obtain ⟨u, hu, rfl, hu_ne⟩ := stateCellEntries_spec es p hp
        exact hu_ne ((h_key t ht u hu h_pkey) ▸ h_abs)
    rw [h_nil]
    show emptyRootAt 0 = _
    unfold cellLeaf
    rw [if_pos h_abs]
  · have h_tag : t ∈ stateCellTags es :=
      Classical.byContradiction fun h_c => h_abs (getCellValue_of_not_mem es t h_c)
    rw [bucketAt_eq_singleton_of_mem smtDepth _ _ _ h_bd
      (mem_stateCellEntries_of_ne_absent es t h_tag h_abs)]
    show leafHash (smtCellKey t) (getCellValue es t) = _
    unfold cellLeaf
    rw [if_neg h_abs]

/-- **Agreement away from the opened cells**, from agreement away
    from the opened TAGS.

    The other side condition the one-wire-two-roots argument needs,
    and it costs no hash hypothesis at all: the argument runs
    tag-to-key, never key-to-tag, so a cell whose key is unopened is
    a cell whose tag is unopened and the step's completeness applies
    directly.

    This is where `WriteSetComplete` enters the multiproof: it is
    exactly `h_agree`, instantiated at the step's write set. -/
theorem agreeOffOpened_openedOf (pre post : ExtendedState) (ts : List CellTag)
    (h_agree : ∀ t : CellTag, t ∉ ts → getCellValue post t = getCellValue pre t) :
    AgreeOffOpened (openedOf post ts) (stateCellEntries pre) (stateCellEntries post) := by
  intro p hp
  have h_off : ∀ u : CellTag, smtCellKey u = p.1 → u ∉ ts := by
    intro u h_key hu
    exact hp ⟨(smtCellKey u, cellLeaf u (getCellValue post u)),
      List.mem_map_of_mem hu, h_key⟩
  constructor
  · intro h_pre
    obtain ⟨u, _, rfl, hu_ne⟩ := stateCellEntries_spec pre p h_pre
    have h_eq := h_agree u (h_off u rfl)
    have hu_ne' : getCellValue post u ≠ canonicalAbsentValue u := by rw [h_eq]; exact hu_ne
    have h_tag : u ∈ stateCellTags post :=
      Classical.byContradiction fun h_c => hu_ne' (getCellValue_of_not_mem post u h_c)
    have := mem_stateCellEntries_of_ne_absent post u h_tag hu_ne'
    rwa [h_eq] at this
  · intro h_post
    obtain ⟨u, _, rfl, hu_ne⟩ := stateCellEntries_spec post p h_post
    have h_eq := h_agree u (h_off u rfl)
    rw [h_eq] at hu_ne ⊢
    exact mem_stateCellEntries_of_ne_absent pre u
      (Classical.byContradiction fun h_c => hu_ne (getCellValue_of_not_mem pre u h_c)) hu_ne

/-- **The opened cells are distinguishable by the bits the walk
    reads.**

    Two facts, and both are already proved: a cell key is 32 bytes, so
    it fills the tree's depth exactly (`keysSeparated_cellTags`), and a
    frontier's keys are pairwise distinct (`frontierOf_keys_nodup`).
    The hypothesis is stated on the key list rather than derived from
    `frontierOf` so a caller can supply either. -/
theorem bitsDistinctBelow_openedOf (es : ExtendedState) (ts : List CellTag)
    (h_nodup : (ts.map smtCellKey).Nodup) :
    BitsDistinctBelow smtDepth (openedOf es ts) := by
  refine bitsDistinctBelow_of_keys_pairwise_ne (fun p hp => ?_) ?_
  · obtain ⟨t, _, rfl⟩ := List.mem_map.mp hp
    exact smtCellKey_size t
  · rw [show (openedOf es ts) = ts.map (fun t => (smtCellKey t, cellLeaf t (getCellValue es t)))
        from rfl, List.pairwise_map]
    exact (List.pairwise_map.mp h_nodup)

/-- **The post-state's root, from the pre-state's wire.**

    The M3 headline, and the statement the L1 needs: hand the verifier a
    pre-root, the cells a step writes, and ONE sibling list, and the
    fold of the DERIVED post-values lands on
    `commitExtendedState` of the state the step produces.

    It subsumes `foldStateCellWrites_eq_commit_of_coherent` — m cells at
    once, with no per-link coherence obligation and no ordering, because
    every opening is against the same root. -/
theorem multiFold_eq_commit_post (es es' : ExtendedState) (ts : List CellTag)
    (h_ne : openedOf es' ts ≠ [])
    (h_ag : AgreeOffOpened (openedOf es' ts) (stateCellEntries es) (stateCellEntries es'))
    (h_wf : BitsDistinctBelow smtDepth (stateCellEntries es))
    (h_wf' : BitsDistinctBelow smtDepth (stateCellEntries es'))
    (h_coh : LeavesCoherent smtDepth (stateCellEntries es') (openedOf es' ts))
    (h_dist : BitsDistinctBelow smtDepth (openedOf es' ts)) :
    multiWalk smtDepth (openedOf es' ts)
        (multiSiblings smtDepth (stateCellEntries es) (openedOf es ts))
      = some (commitExtendedState es', []) := by
  rw [multiSiblings_pre_eq_post es es' ts h_ag h_wf h_wf']
  exact multiWalk_eq_smtRootListAux (stateCellEntries es') (openedOf es' ts)
    h_ne h_coh h_dist

/-- **The pre-state's root, from the same wire.**  The other half of
    the pair: what the verifier checks the submitted pre-root against. -/
theorem multiFold_eq_commit_pre (es : ExtendedState) (ts : List CellTag)
    (h_ne : openedOf es ts ≠ [])
    (h_coh : LeavesCoherent smtDepth (stateCellEntries es) (openedOf es ts))
    (h_dist : BitsDistinctBelow smtDepth (openedOf es ts)) :
    multiWalk smtDepth (openedOf es ts)
        (multiSiblings smtDepth (stateCellEntries es) (openedOf es ts))
      = some (commitExtendedState es, []) :=
  multiWalk_eq_smtRootListAux (stateCellEntries es) (openedOf es ts) h_ne h_coh h_dist

/-! ## The wire

The compressed form.  A single-cell opening's mask is indexed by
LEVEL, because a single path has exactly one sibling per level.  A
multiproof's is indexed by GAP, and a gap's index is not its level:
merges consume levels without reading the wire, so the two run out of
step as soon as two cells share a sub-tree.

That is why the level list is a first-class thing here.  It is
derivable from the KEY SET alone — `multiGapLevels` never looks at an
entry — which is exactly what lets a verifier compute the wire's shape
before parsing it, and refuse a proof of the wrong length instead of
padding a short one. -/

/-- The level of each gap, in the order the walk consumes them.

    Mirrors `multiSiblings`' recursion exactly, minus the entries: the
    shape of the wire is a function of which cells are opened and
    nothing else. -/
def multiGapLevels : Nat → List OpenedLeaf → List Nat
  | 0, _ => []
  | d + 1, opened =>
    match (openedLow d opened), (openedHigh d opened) with
    | [],          []          => []
    | (lo :: los), []          => multiGapLevels d (lo :: los) ++ [d]
    | [],          (hi :: his) => multiGapLevels d (hi :: his) ++ [d]
    | (lo :: los), (hi :: his) =>
      multiGapLevels d (lo :: los) ++ multiGapLevels d (hi :: his)

/-! ### Unfolding `multiGapLevels`, mirroring `multiSiblings` -/

/-- Only the right half is opened. -/
theorem multiGapLevels_gapLow (k : Nat) (opened : List OpenedLeaf)
    (hi : OpenedLeaf) (his : List OpenedLeaf)
    (h_l : openedLow k opened = []) (h_h : openedHigh k opened = hi :: his) :
    multiGapLevels (k + 1) opened = multiGapLevels k (hi :: his) ++ [k] := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- Only the left half is opened. -/
theorem multiGapLevels_gapHigh (k : Nat) (opened : List OpenedLeaf)
    (lo : OpenedLeaf) (los : List OpenedLeaf)
    (h_l : openedLow k opened = lo :: los) (h_h : openedHigh k opened = []) :
    multiGapLevels (k + 1) opened = multiGapLevels k (lo :: los) ++ [k] := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- Both halves are opened: a merge, which reads no gap. -/
theorem multiGapLevels_merge (k : Nat) (opened : List OpenedLeaf)
    (lo hi : OpenedLeaf) (los his : List OpenedLeaf)
    (h_l : openedLow k opened = lo :: los) (h_h : openedHigh k opened = hi :: his) :
    multiGapLevels (k + 1) opened
      = multiGapLevels k (lo :: los) ++ multiGapLevels k (hi :: his) := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- Nothing is opened. -/
theorem multiGapLevels_empty (k : Nat) (opened : List OpenedLeaf)
    (h_l : openedLow k opened = []) (h_h : openedHigh k opened = []) :
    multiGapLevels (k + 1) opened = [] := by
  show (match openedLow k opened, openedHigh k opened with
        | [], [] => _ | (_ :: _), [] => _
        | [], (_ :: _) => _ | (_ :: _), (_ :: _) => _) = _
  rw [h_l, h_h]

/-- **The wire's shape matches its content.**  There is exactly one
    level per gap, so the mask a verifier derives from the KEY SET
    indexes the siblings the prover sent — which is what makes an
    exact-length check possible. -/
theorem multiGapLevels_length_eq :
    ∀ (d : Nat) (entries : SmtEntries) (opened : List OpenedLeaf),
      (multiGapLevels d opened).length = (multiSiblings d entries opened).length := by
  intro d
  induction d with
  | zero => intro _ _; rfl
  | succ k ih =>
    intro entries opened
    cases h_l : openedLow k opened with
    | nil =>
      cases h_h : openedHigh k opened with
      | nil =>
        rw [multiGapLevels_empty k opened h_l h_h,
          multiSiblings_succ_empty k entries opened h_l h_h]
        rfl
      | cons hi his =>
        rw [multiGapLevels_gapLow k opened hi his h_l h_h,
          multiSiblings_succ_gapLow k entries opened hi his h_l h_h,
          List.length_append, List.length_append,
          ih (highHalf k entries) (hi :: his)]
        rfl
    | cons lo los =>
      cases h_h : openedHigh k opened with
      | nil =>
        rw [multiGapLevels_gapHigh k opened lo los h_l h_h,
          multiSiblings_succ_gapHigh k entries opened lo los h_l h_h,
          List.length_append, List.length_append,
          ih (lowHalf k entries) (lo :: los)]
        rfl
      | cons hi his =>
        rw [multiGapLevels_merge k opened lo hi los his h_l h_h,
          multiSiblings_succ_merge k entries opened lo hi los his h_l h_h,
          List.length_append, List.length_append,
          ih (lowHalf k entries) (lo :: los), ih (highHalf k entries) (hi :: his)]

/-- **A single opened cell has one gap per level.**  With `m = 1` the
    gap index IS the level, which is what makes the compressed wire
    byte-identical to a single-cell `proofData`. -/
theorem multiGapLevels_single :
    ∀ (d : Nat) (k leaf : ByteArray),
      multiGapLevels d [(k, leaf)] = (List.range d).reverse.reverse := by
  intro d k leaf
  rw [List.reverse_reverse]
  induction d with
  | zero => rfl
  | succ i ih =>
    by_cases hb : BitsKey.keyBit k i
    · have h_l : openedLow i [(k, leaf)] = [] := by
        show List.filter _ [(k, leaf)] = []; simp [hb]
      have h_h : openedHigh i [(k, leaf)] = [(k, leaf)] := by
        show List.filter _ [(k, leaf)] = _; simp [hb]
      rw [multiGapLevels_gapLow i [(k, leaf)] (k, leaf) [] h_l h_h, ih,
        List.range_succ]
    · have h_l : openedLow i [(k, leaf)] = [(k, leaf)] := by
        show List.filter _ [(k, leaf)] = _; simp [hb]
      have h_h : openedHigh i [(k, leaf)] = [] := by
        show List.filter _ [(k, leaf)] = []; simp [hb]
      rw [multiGapLevels_gapHigh i [(k, leaf)] (k, leaf) [] h_l h_h, ih,
        List.range_succ]

/-- The compressed wire: a gap mask, then the siblings the mask marks
    as non-canonical-empty.

    Mirrors `SmtCellProof` — same mask bit order (LSB-first within each
    byte), same "clear bit means the canonical empty sub-tree" rule —
    so that at one opened cell the two encodings coincide. -/
structure SmtMultiProof where
  /-- One bit per gap, LSB-first within each byte; set iff the gap's
      sibling is drawn from `siblings`. -/
  gapMask : ByteArray
  /-- The non-canonical-empty siblings, in gap order. -/
  siblings : Array ByteArray
  deriving Repr

namespace SmtMultiProof

/-- Bit `g` of the gap mask.  Same convention as
    `SmtCellProof.bitmaskBit`. -/
def gapBit (p : SmtMultiProof) (g : Nat) : Bool :=
  if h : g / 8 < p.gapMask.size then
    decide (((p.gapMask[g / 8]'h).toNat >>> (g % 8)) % 2 = 1)
  else
    false

/-- The L1 wire encoding: the mask, then the siblings. -/
def toWireBytes (p : SmtMultiProof) : ByteArray :=
  p.siblings.foldl (fun acc s => acc ++ s) p.gapMask

end SmtMultiProof

/-- Build the compressed wire from the full gap list and its levels: a
    gap whose sibling is the canonical empty sub-tree at its level
    costs a cleared bit rather than 32 bytes. -/
def buildMultiProof (levels : List Nat) (gaps : List ByteArray) : SmtMultiProof :=
  let n := levels.length
  -- The gaps worth sending: the rest are the canonical empty sub-tree
  -- at their own level, which the verifier derives.
  let kept := (List.range n).filter (fun g => gaps[g]! != emptySubtreeHash (levels[g]!))
  { gapMask   := kept.foldl setBitmaskBit
                   (ByteArray.mk (Array.replicate ((n + 7) / 8) (0 : UInt8)))
  , siblings  := (kept.map (fun g => gaps[g]!)).toArray }

/-- Expand a compressed wire back to the full gap list, using the
    derived level of each gap for the cleared bits. -/
def expandMultiProof (levels : List Nat) (p : SmtMultiProof) : List ByteArray :=
  ((List.range levels.length).foldl
    (fun (acc : List ByteArray × Nat) g =>
      if p.gapBit g then
        (acc.1 ++ [p.siblings[acc.2]?.getD paddingHash], acc.2 + 1)
      else
        (acc.1 ++ [emptySubtreeHash (levels[g]!)], acc.2))
    ([], 0)).1

/-! ## The wire's exact shape

The property the whole design turns on.  A single-cell verifier that
runs out of siblings substitutes `PADDING_HASH` and keeps walking, so
a truncated proof is a silent reinterpretation rather than a refusal —
it reaches SOME root, just not the one the tree has.

A multiproof cannot be truncated silently, because its length is a
function of the KEY SET: derive the gap levels, and the mask's size,
the sibling count and every padding bit are all determined before a
single byte of the wire is read. -/

/-- How many gaps the mask marks as carrying a sibling. -/
def SmtMultiProof.gapPopcount (p : SmtMultiProof) (n : Nat) : Nat :=
  ((List.range n).filter (fun g => p.gapBit g)).length

/-- **The wire is exactly the shape the key set implies.**

    Four conditions, each derived rather than trusted:
      * the mask is exactly `ceil(G/8)` bytes;
      * every bit at or past `G` is clear, so the final byte's padding
        cannot smuggle a sibling;
      * the sibling count is exactly the mask's popcount — not "at
        least", which is what lets a short proof be padded;
      * every sibling is 32 bytes.

    `G` comes from `multiGapLevels`, which never looks at an entry. -/
def SmtMultiProof.isWellFormedFor (p : SmtMultiProof) (levels : List Nat) : Bool :=
  let n := levels.length
  p.gapMask.size == (n + 7) / 8
    && (List.range (p.gapMask.size * 8)).all (fun g => g < n || ! p.gapBit g)
    && p.siblings.size == p.gapPopcount n
    && p.siblings.all (fun s => s.size == 32)

/-- The wire encoding's length is the mask plus 32 bytes per sibling —
    the shape an L1 validates before walking. -/
theorem SmtMultiProof.toWireBytes_size (p : SmtMultiProof)
    (h_sibs : ∀ s ∈ p.siblings, s.size = 32) :
    p.toWireBytes.size = p.gapMask.size + 32 * p.siblings.size := by
  unfold toWireBytes
  have h : ∀ (l : List ByteArray) (acc : ByteArray),
      (∀ s ∈ l, s.size = 32) →
      (l.foldl (fun a s => a ++ s) acc).size = acc.size + 32 * l.length := by
    intro l
    induction l with
    | nil => intro acc _; simp
    | cons a t ih =>
      intro acc hl
      rw [List.foldl_cons, ih (acc ++ a) (fun s hs => hl s (List.mem_cons_of_mem _ hs))]
      rw [ByteArray.size_append, hl a List.mem_cons_self, List.length_cons]
      omega
  rw [show p.siblings.foldl (fun acc s => acc ++ s) p.gapMask
        = p.siblings.toList.foldl (fun acc s => acc ++ s) p.gapMask from
      (Array.foldl_toList ..).symm]
  rw [h p.siblings.toList p.gapMask (fun s hs => h_sibs s (by simpa using hs))]
  simp

end FaultProof
end LegalKernel

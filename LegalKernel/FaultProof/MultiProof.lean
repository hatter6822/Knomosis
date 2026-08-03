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

end FaultProof
end LegalKernel

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.SmtInjective — injectivity of the SMT root.

## Why this exists

`commitExtendedState` hashes seven concatenated sub-state ENCODINGS,
and its injectivity is proved by decomposing that concatenation
(`commitExtendedState_subcommits_extensional_eq_under_collision_free`,
EI.8).  Replacing it with a root over CELLS — which is what makes a
post-root computable on L1 from a pre-root plus the step's proven
writes — replaces that argument wholesale: the SMT root is not a
concatenation of the things it binds.

This module supplies the replacement.  The headline is
`smtRootListAux_perm_of_eq_under_collision_free`: two entry lists
with the same SMT root are permutations of one another, hence equal
as maps.  Without it, swapping the published root would silently
downgrade a guarantee that is in CLAUDE.md's headline table.

## The shape of the argument

`smtRootListAux` recurses on depth, partitioning entries by
`BitsKey.keyBit` at each level and hashing the two sub-roots.  Going
backwards, three things have to hold at every level:

  * **the leaf case is injective** — `leafHash k v` determines
    `(k, v)`, which needs collision-freeness plus the fact that the
    CBE byte-string encoding is self-delimiting;
  * **an empty sub-tree is not a populated one** — the canonical
    `emptySubtreeHash d` must be unreachable as the root of a
    non-empty bucket, or a populated sub-tree could impersonate an
    empty one.  Both sides are well-formed 32-byte hashes, so this
    needs its own induction
    (`smtRootListAux_ne_emptyRootAt_under_collision_free`);
  * **the conclusion is a permutation, not list equality** — the
    partition reorders, so equality as a *map* is the honest form.

## Why the distinctness hypothesis is load-bearing

At depth 0, `smtRootListAux` matches `[(k, v)]` and falls through to
`emptySubtreeHash 0` for *any* other shape.  Two entries sharing all
256 key bits therefore vanish from the root together, and no
injectivity statement can survive that.  `BitsDistinctBelow` is the
exact condition that rules it out, and it is stated on key *bits*
rather than on keys because bits are all `smtRootListAux` ever reads.
`bitsDistinctBelow_of_keys_pairwise_ne` bridges the two for 32-byte
keys.

## Cell updates

The last section builds on the same machinery: a cell root exists so
a post-root is computable from a pre-root plus the proven writes, and
`smtUpdateRoot_proof_independent` is what makes that computation
non-manipulable — the post-root depends on `(pre-root, key, new
value)`, not on which of several verifying openings the responder
chose to supply.
-/

import LegalKernel.FaultProof.Smt

set_option maxRecDepth 4096

namespace LegalKernel
namespace FaultProof

open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Runtime

/-- The entry shape the state's SMT root is built from: a 32-byte
    derived cell key paired with the cell's encoded value. -/
abbrev SmtEntries := List (ByteArray × ByteArray)

/-! ## The canonical empty root

`smtRootListAux` returns a canonical value for an empty bucket, but
spells it two ways: an `emptySubtreeHashes` table lookup below depth
256, and an on-the-fly `hashBytes` at depth 256 itself (the table
only stores depths 0–255).  `emptyRootAt` is the single recursive
characterisation both agree with, which is the form the induction
needs. -/

/-- The canonical empty-sub-tree root at depth `d`, recursively. -/
def emptyRootAt : Nat → ByteArray
  | 0     => emptySubtreeHash 0
  | d + 1 => hashBytes (emptyRootAt d ++ emptyRootAt d)

/-- The canonical empty root is a 32-byte hash at every depth. -/
theorem emptyRootAt_size (d : Nat) : (emptyRootAt d).size = 32 := by
  cases d with
  | zero => exact emptySubtreeHash_size 0 (by decide)
  | succ _ => exact hashBytes_size _

/-- Below depth 256 the recursive characterisation agrees with the
    pre-computed table. -/
theorem emptyRootAt_eq_table (d : Nat) (h : d < 256) :
    emptyRootAt d = emptySubtreeHash d := by
  induction d with
  | zero => rfl
  | succ k ih =>
    rw [emptyRootAt, ih (by omega), emptySubtreeHash_succ k h]

/-- An empty bucket hashes to the canonical empty root, at every
    depth the SMT actually uses. -/
theorem smtRootListAux_nil (d : Nat) (h : d ≤ 256) :
    smtRootListAux (K := ByteArray) (V := ByteArray) d [] = emptyRootAt d := by
  cases d with
  | zero => rfl
  | succ k =>
    show (if ([] : SmtEntries).isEmpty then
            if k + 1 < 256 then emptySubtreeHash (k + 1)
            else hashBytes (emptySubtreeHash k ++ emptySubtreeHash k)
          else _) = _
    rw [if_pos (by rfl)]
    by_cases h_lt : k + 1 < 256
    · rw [if_pos h_lt, emptyRootAt, emptyRootAt_eq_table k (by omega),
        ← emptySubtreeHash_succ k h_lt]
    · rw [if_neg h_lt, emptyRootAt, emptyRootAt_eq_table k (by omega)]

/-! ## Pre-image enumeration

`CollisionFreeOn` is scoped to a finite list, so every `hashBytes`
call the recursion makes has to appear in it.  Two families: the
empty-sub-tree chain, and the roots the entries themselves produce. -/

/-- The `hashBytes` pre-images the empty-sub-tree chain consumes up
    to depth `d`. -/
def emptyRootPreimages : Nat → List ByteArray
  | 0     => [emptyLeafSeedBytes]
  | d + 1 => (emptyRootAt d ++ emptyRootAt d) :: emptyRootPreimages d

/-- The `hashBytes` pre-images `smtRootListAux d entries` consumes. -/
def smtRootPreimages : Nat → SmtEntries → List ByteArray
  | 0, entries =>
    match entries with
    | [(k, v)] => [encodeAsBytes k ++ encodeAsBytes v]
    | _        => []
  | d + 1, entries =>
    if entries.isEmpty then []
    else
      (smtRootListAux d (entries.filter (fun e => ! BitsKey.keyBit e.1 d)) ++
        smtRootListAux d (entries.filter (fun e => BitsKey.keyBit e.1 d))) ::
        (smtRootPreimages d (entries.filter (fun e => ! BitsKey.keyBit e.1 d)) ++
          smtRootPreimages d (entries.filter (fun e => BitsKey.keyBit e.1 d)))

/-! ## Well-formedness of a bucket -/

/-- Entries in a depth-`d` bucket are pairwise distinguishable by
    some key bit *below* `d`.  This is the exact hypothesis the
    recursion consumes: the partition at depth `d` uses up bit `d`,
    so what remains for the sub-buckets is distinguishability below
    it. -/
def BitsDistinctBelow (d : Nat) (e : SmtEntries) : Prop :=
  e.Pairwise (fun a b => ∃ i, i < d ∧ BitsKey.keyBit a.1 i ≠ BitsKey.keyBit b.1 i)

/-- Every key and value fits the CBE byte-string length head, which
    is what makes the leaf encoding self-delimiting. -/
def EntriesEncodable (e : SmtEntries) : Prop :=
  ∀ p ∈ e, p.1.size < 256 ^ 8 ∧ p.2.size < 256 ^ 8

/-- Distinguishability restricts to any sub-list, in particular to
    either half of the partition. -/
theorem BitsDistinctBelow.sublist {d : Nat} {e e' : SmtEntries}
    (h_sub : e'.Sublist e) (h : BitsDistinctBelow d e) :
    BitsDistinctBelow d e' :=
  List.Pairwise.sublist h_sub h

/-- The left half of the depth-`d` partition is distinguishable
    below `d`: its members all read `false` at bit `d`, so the index
    that separates any two of them cannot be `d`. -/
theorem BitsDistinctBelow.filter_low {d : Nat} {e : SmtEntries}
    (h : BitsDistinctBelow (d + 1) e) :
    BitsDistinctBelow d (e.filter (fun p => ! BitsKey.keyBit p.1 d)) := by
  refine List.Pairwise.imp_of_mem ?_
    (BitsDistinctBelow.sublist (d := d + 1) List.filter_sublist h)
  intro a b ha hb hab
  obtain ⟨i, h_lt, h_ne⟩ := hab
  have ha' : BitsKey.keyBit a.1 d = false := by
    have := (List.mem_filter.mp ha).2
    simpa using this
  have hb' : BitsKey.keyBit b.1 d = false := by
    have := (List.mem_filter.mp hb).2
    simpa using this
  refine ⟨i, ?_, h_ne⟩
  rcases Nat.lt_succ_iff_lt_or_eq.mp h_lt with h_i | rfl
  · exact h_i
  · exact absurd (ha'.trans hb'.symm) h_ne

/-- The right half of the depth-`d` partition, symmetrically. -/
theorem BitsDistinctBelow.filter_high {d : Nat} {e : SmtEntries}
    (h : BitsDistinctBelow (d + 1) e) :
    BitsDistinctBelow d (e.filter (fun p => BitsKey.keyBit p.1 d)) := by
  refine List.Pairwise.imp_of_mem ?_
    (BitsDistinctBelow.sublist (d := d + 1) List.filter_sublist h)
  intro a b ha hb hab
  obtain ⟨i, h_lt, h_ne⟩ := hab
  have ha' : BitsKey.keyBit a.1 d = true := (List.mem_filter.mp ha).2
  have hb' : BitsKey.keyBit b.1 d = true := (List.mem_filter.mp hb).2
  refine ⟨i, ?_, h_ne⟩
  rcases Nat.lt_succ_iff_lt_or_eq.mp h_lt with h_i | rfl
  · exact h_i
  · exact absurd (ha'.trans hb'.symm) h_ne

/-- `EntriesEncodable` restricts to any sub-list. -/
theorem EntriesEncodable.sublist {e e' : SmtEntries}
    (h_sub : e'.Sublist e) (h : EntriesEncodable e) : EntriesEncodable e' :=
  fun p hp => h p (h_sub.mem hp)

/-- At depth 0 every key bit has been consumed, so a well-formed
    bucket holds at most one entry.  This is what makes the leaf
    case of `smtRootListAux` the only reachable non-empty shape. -/
theorem length_le_one_of_bitsDistinctBelow_zero {e : SmtEntries}
    (h : BitsDistinctBelow 0 e) : e.length ≤ 1 := by
  match e with
  | []      => simp
  | [_]     => simp
  | a :: b :: _ =>
    obtain ⟨i, h_lt, _⟩ := (List.pairwise_cons.mp h).1 b (by simp)
    omega

/-! ### From distinct keys to distinct bit-vectors

`BitsDistinctBelow` is stated on key *bits* because bits are all
`smtRootListAux` reads.  Callers hold the stronger, more natural
fact — the keys themselves differ — so this is the bridge.  It only
holds because the keys are exactly 32 bytes: `BitsKey.keyBit` reads
`false` past the end of a key, so a shorter key and its zero-padded
extension would share a bit-vector. -/

/-- The `ByteArray` `BitsKey` instance, restated at a decomposed
    index.  Bit `8 * j + (7 - m)` is bit `m` of byte `j`. -/
private theorem keyBit_byteArray_eq (k : ByteArray) (i j m : Nat)
    (hj : j < k.size) (h_div : i / 8 = j) (h_mod : 7 - i % 8 = m) :
    BitsKey.keyBit k i = decide (((k[j]'hj).toNat >>> m) % 2 = 1) := by
  show (if h : i / 8 < k.size then
          decide (((k[i / 8]'h).toNat >>> (7 - i % 8)) % 2 = 1)
        else false) = _
  subst h_div
  subst h_mod
  rw [dif_pos hj]

/-- `Nat.testBit` in the shape the `BitsKey` instance produces. -/
private theorem testBit_eq_decide (x n : Nat) :
    x.testBit n = decide ((x >>> n) % 2 = 1) := by
  simp [Nat.testBit]

/-- Two 32-byte keys with the same 256-bit vector are equal. -/
theorem byteArray_eq_of_keyBits_eq {k₁ k₂ : ByteArray}
    (h₁ : k₁.size = 32) (h₂ : k₂.size = 32)
    (h : ∀ i, i < smtDepth → BitsKey.keyBit k₁ i = BitsKey.keyBit k₂ i) :
    k₁ = k₂ := by
  refine ByteArray.ext_getElem (by omega) ?_
  intro j hj₁ hj₂
  have h_nat : (k₁[j]'hj₁).toNat = (k₂[j]'hj₂).toNat := by
    refine Nat.eq_of_testBit_eq ?_
    intro n
    by_cases hn : n < 8
    · -- Bit `n` of byte `j` is bit `8 * j + (7 - n)` of the key.
      have hj : j < 32 := by omega
      have h_i : 8 * j + (7 - n) < smtDepth := by unfold smtDepth; omega
      have h_bit := h (8 * j + (7 - n)) h_i
      rw [keyBit_byteArray_eq k₁ _ j n hj₁ (by omega) (by omega),
        keyBit_byteArray_eq k₂ _ j n hj₂ (by omega) (by omega)] at h_bit
      rw [testBit_eq_decide, testBit_eq_decide]
      exact h_bit
    · -- Past the byte's width both bits are zero.
      have h_pow : (2 : Nat) ^ 8 ≤ 2 ^ n :=
        Nat.pow_le_pow_right (by omega) (by omega)
      rw [Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (UInt8.toNat_lt _) h_pow),
        Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (UInt8.toNat_lt _) h_pow)]
  exact UInt8.toNat_inj.mp h_nat

/-- Two distinct 32-byte keys are separated by some bit below the
    SMT depth. -/
theorem exists_keyBit_ne_of_ne {k₁ k₂ : ByteArray}
    (h₁ : k₁.size = 32) (h₂ : k₂.size = 32) (h : k₁ ≠ k₂) :
    ∃ i, i < smtDepth ∧ BitsKey.keyBit k₁ i ≠ BitsKey.keyBit k₂ i :=
  Classical.byContradiction fun h_c =>
    h (byteArray_eq_of_keyBits_eq h₁ h₂ fun i hi =>
      Classical.byContradiction fun h_bit => h_c ⟨i, hi, h_bit⟩)

/-- Pairwise-distinct 32-byte keys give the `BitsDistinctBelow`
    hypothesis at full depth, which is what the root-injectivity
    theorem consumes. -/
theorem bitsDistinctBelow_of_keys_pairwise_ne {e : SmtEntries}
    (h_size : ∀ p ∈ e, p.1.size = 32)
    (h_ne : e.Pairwise (fun a b => a.1 ≠ b.1)) :
    BitsDistinctBelow smtDepth e :=
  List.Pairwise.imp_of_mem
    (fun ha hb hab => exists_keyBit_ne_of_ne (h_size _ ha) (h_size _ hb) hab) h_ne

/-! ## Leaf injectivity

The leaf pre-image is `encode key ++ encode value` in the CBE byte
string form, whose 9-byte length head makes the split unambiguous.
That is what `byteArray_roundtrip` — decode-with-suffix — expresses,
so the split is read off it rather than re-proved. -/

/-- The `Stream` under an `encodeAsBytes` is the encoding itself. -/
private theorem encodeAsBytes_data_toList {T : Type} [Encodable T] (v : T) :
    (encodeAsBytes v).data.toList = Encodable.encode v := by
  show (Encodable.encode v).toArray.toList = Encodable.encode v
  exact List.toList_toArray

/-- The CBE byte-string head is 9 bytes, so every `encodeAsBytes` of
    a `ByteArray` is at least that long. -/
private theorem encodeAsBytes_size_ge_nine (x : ByteArray) :
    9 ≤ (encodeAsBytes x).size := by
  have h : (encodeAsBytes x).size = (Encodable.encode (T := ByteArray) x).length := by
    show (Encodable.encode (T := ByteArray) x).toArray.size = _
    simp
  rw [h]
  show 9 ≤ (encodeBytesList x.data.toList).length
  unfold encodeBytesList cborHeadEncode
  rw [List.length_append, List.length_cons, natToBytesLE_length]
  omega

/-- Leaf-hash injectivity: under collision-freeness on the two leaf
    pre-images, equal leaf hashes force equal keys *and* equal
    values.  The key/value split comes from the self-delimiting CBE
    byte-string head, not from any size assumption on the key. -/
theorem leafHash_inj_under_collision_free
    (k₁ v₁ k₂ v₂ : ByteArray)
    (h_cf : CollisionFreeOn
      [encodeAsBytes k₁ ++ encodeAsBytes v₁,
       encodeAsBytes k₂ ++ encodeAsBytes v₂] hashBytes)
    (hk₁ : k₁.size < 256 ^ 8) (hv₁ : v₁.size < 256 ^ 8)
    (hk₂ : k₂.size < 256 ^ 8) (hv₂ : v₂.size < 256 ^ 8)
    (h : leafHash k₁ v₁ = leafHash k₂ v₂) :
    k₁ = k₂ ∧ v₁ = v₂ := by
  -- Undo the outer hash.
  have h_pre : encodeAsBytes k₁ ++ encodeAsBytes v₁
             = encodeAsBytes k₂ ++ encodeAsBytes v₂ :=
    h_cf.apply (by simp) (by simp) h
  -- Descend to the `Stream` level, where the decoder lives.
  have h_stream : Encodable.encode (T := ByteArray) k₁ ++
                    Encodable.encode (T := ByteArray) v₁
                = Encodable.encode (T := ByteArray) k₂ ++
                    Encodable.encode (T := ByteArray) v₂ := by
    have h_list : (encodeAsBytes k₁ ++ encodeAsBytes v₁).data.toList
                = (encodeAsBytes k₂ ++ encodeAsBytes v₂).data.toList := by
      rw [h_pre]
    have h_split : ∀ a b : ByteArray,
        (a ++ b).data.toList = a.data.toList ++ b.data.toList := fun _ _ => rfl
    rw [h_split, h_split, encodeAsBytes_data_toList, encodeAsBytes_data_toList,
      encodeAsBytes_data_toList, encodeAsBytes_data_toList] at h_list
    exact h_list
  -- Decode the head off each side; the residue is the value encoding.
  have r₁ := byteArray_roundtrip k₁ (Encodable.encode (T := ByteArray) v₁) hk₁
  have r₂ := byteArray_roundtrip k₂ (Encodable.encode (T := ByteArray) v₂) hk₂
  rw [h_stream] at r₁
  have h_eq : (Except.ok (k₁, Encodable.encode (T := ByteArray) v₁) :
                 Except DecodeError (ByteArray × Stream))
            = Except.ok (k₂, Encodable.encode (T := ByteArray) v₂) := r₁.symm.trans r₂
  have h_pair := (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj h_eq)
  exact ⟨h_pair.1, byteArray_encode_injective v₁ v₂ hv₁ hv₂ h_pair.2⟩

/-- A populated leaf is never the canonical depth-0 empty root.  The
    two are both 32-byte hashes, so the separation is a pre-image
    length argument: the empty seed is 10 bytes, and a leaf pre-image
    carries two 9-byte CBE heads. -/
theorem leafHash_ne_emptyRootAt_zero (k v : ByteArray)
    (h_cf : CollisionFreeOn
      [encodeAsBytes k ++ encodeAsBytes v, emptyLeafSeedBytes] hashBytes) :
    leafHash k v ≠ emptyRootAt 0 := by
  intro h_eq
  have h_pre : encodeAsBytes k ++ encodeAsBytes v = emptyLeafSeedBytes := by
    refine h_cf.apply (by simp) (by simp) ?_
    show leafHash k v = hashBytes emptyLeafSeedBytes
    rw [h_eq]
    show emptyRootAt 0 = hashBytes emptyLeafSeedBytes
    rw [emptyRootAt, emptySubtreeHash_zero]
  have h_size : (encodeAsBytes k ++ encodeAsBytes v).size = emptyLeafSeedBytes.size := by
    rw [h_pre]
  rw [ByteArray.size_append, show emptyLeafSeedBytes.size = 10 from rfl] at h_size
  have := encodeAsBytes_size_ge_nine k
  have := encodeAsBytes_size_ge_nine v
  omega

/-! ## Empty/non-empty separation

A populated bucket must not hash to the canonical empty root at its
depth, or the map that produced it could be replaced by nothing.
Both sides are 32-byte hashes, which is precisely why this needs an
induction rather than a size check. -/

/-- A non-empty bucket has a non-empty half: the partition at depth
    `d` sends every entry to exactly one side. -/
theorem filter_partition_ne_nil (d : Nat) (e : SmtEntries) (h : e ≠ []) :
    e.filter (fun p => ! BitsKey.keyBit p.1 d) ≠ [] ∨
      e.filter (fun p => BitsKey.keyBit p.1 d) ≠ [] := by
  match e with
  | [] => exact absurd rfl h
  | p :: t =>
    by_cases h_bit : BitsKey.keyBit p.1 d
    · refine Or.inr (fun h_c => ?_)
      have h_mem : p ∈ (p :: t).filter (fun q => BitsKey.keyBit q.1 d) :=
        List.mem_filter.mpr ⟨by simp, h_bit⟩
      rw [h_c] at h_mem
      exact absurd h_mem (by simp)
    · refine Or.inl (fun h_c => ?_)
      have h_mem : p ∈ (p :: t).filter (fun q => ! BitsKey.keyBit q.1 d) :=
        List.mem_filter.mpr ⟨by simp, by simp [h_bit]⟩
      rw [h_c] at h_mem
      exact absurd h_mem (by simp)

/-- A non-empty well-formed bucket never hashes to the canonical
    empty root at its depth. -/
theorem smtRootListAux_ne_emptyRootAt_under_collision_free :
    ∀ (d : Nat), d ≤ 256 → ∀ (e : SmtEntries),
      BitsDistinctBelow d e → EntriesEncodable e → e ≠ [] →
      CollisionFreeOn (smtRootPreimages d e ++ emptyRootPreimages d) hashBytes →
      smtRootListAux d e ≠ emptyRootAt d
  | 0, _, e, h_wf, h_enc, h_ne, h_cf => by
    -- Depth 0: the bucket holds exactly one entry, so the root is a
    -- leaf hash and the empty root is the seed hash.
    have h_len := length_le_one_of_bitsDistinctBelow_zero h_wf
    match e, h_ne, h_len with
    | [(k, v)], _, _ =>
      have h_enc' := h_enc (k, v) (by simp)
      refine leafHash_ne_emptyRootAt_zero k v (h_cf.mono ?_)
      intro x hx
      -- Both pre-images are in the enumerated list, one per half.
      rcases List.mem_cons.mp hx with rfl | hx'
      · exact List.mem_append_left _ (by simp [smtRootPreimages])
      · rw [List.mem_singleton.mp hx']
        exact List.mem_append_right _ (by simp [emptyRootPreimages])
  | d + 1, h_d, e, h_wf, h_enc, h_ne, h_cf => by
    -- Depth d+1: undo the outer hash, then one of the two halves is
    -- non-empty and contradicts the induction hypothesis.
    have h_isEmpty : e.isEmpty = false := by
      cases e with
      | nil => exact absurd rfl h_ne
      | cons _ _ => rfl
    have h_root : smtRootListAux (d + 1) e
                = hashBytes
                    (smtRootListAux d (e.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
                      smtRootListAux d (e.filter (fun p => BitsKey.keyBit p.1 d))) := by
      show (if e.isEmpty then _ else _) = _
      rw [if_neg (by simp [h_isEmpty])]
    have h_pre_mem :
        (smtRootListAux d (e.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
          smtRootListAux d (e.filter (fun p => BitsKey.keyBit p.1 d))) ∈
        smtRootPreimages (d + 1) e ++ emptyRootPreimages (d + 1) := by
      refine List.mem_append_left _ ?_
      show _ ∈ (if e.isEmpty then [] else _)
      rw [if_neg (by simp [h_isEmpty])]
      exact List.mem_cons_self
    have h_empty_mem : (emptyRootAt d ++ emptyRootAt d) ∈
        smtRootPreimages (d + 1) e ++ emptyRootPreimages (d + 1) :=
      List.mem_append_right _ (by simp [emptyRootPreimages])
    intro h_eq
    have h_split :
        smtRootListAux d (e.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
            smtRootListAux d (e.filter (fun p => BitsKey.keyBit p.1 d))
          = emptyRootAt d ++ emptyRootAt d := by
      refine h_cf.apply h_pre_mem h_empty_mem ?_
      rw [← h_root, h_eq, emptyRootAt]
    obtain ⟨h_lo_eq, h_hi_eq⟩ :=
      byteArray_append_inj_left _ _ _ _ h_split
        (by rw [smtRootListAux_size, emptyRootAt_size])
    -- One half is non-empty; recurse into it.
    have h_half := filter_partition_ne_nil d e h_ne
    have h_sub : ∀ b : Bool,
        CollisionFreeOn
          (smtRootPreimages d (e.filter (fun p =>
              if b then BitsKey.keyBit p.1 d else ! BitsKey.keyBit p.1 d)) ++
            emptyRootPreimages d) hashBytes := by
      intro b
      refine h_cf.mono ?_
      intro x hx
      rcases List.mem_append.mp hx with hx' | hx'
      · refine List.mem_append_left _ ?_
        show _ ∈ (if e.isEmpty then [] else _)
        rw [if_neg (by simp [h_isEmpty])]
        refine List.mem_cons_of_mem _ ?_
        cases b with
        | false => exact List.mem_append_left _ (by simpa using hx')
        | true  => exact List.mem_append_right _ (by simpa using hx')
      · exact List.mem_append_right _ (List.mem_cons_of_mem _ hx')
    rcases h_half with h_lo_ne | h_hi_ne
    · exact smtRootListAux_ne_emptyRootAt_under_collision_free d (by omega) _
        (BitsDistinctBelow.filter_low h_wf)
        (EntriesEncodable.sublist List.filter_sublist h_enc)
        h_lo_ne (by simpa using h_sub false) h_lo_eq
    · exact smtRootListAux_ne_emptyRootAt_under_collision_free d (by omega) _
        (BitsDistinctBelow.filter_high h_wf)
        (EntriesEncodable.sublist List.filter_sublist h_enc)
        h_hi_ne (by simpa using h_sub true) h_hi_eq

/-! ## The root determines the map -/

/-- Every entry list is a permutation of its own depth-`d`
    partition. -/
theorem perm_partition (d : Nat) (e : SmtEntries) :
    (e.filter (fun p => ! BitsKey.keyBit p.1 d) ++
      e.filter (fun p => BitsKey.keyBit p.1 d)).Perm e :=
  List.Perm.trans List.perm_append_comm
    (List.filter_append_perm (fun p => BitsKey.keyBit p.1 d) e)

/-- **SMT root injectivity.**  Two well-formed entry lists with the
    same SMT root are permutations of one another — equal as maps.

    This is the replacement for the `extendedStateCommitPreimages`
    decomposition that carried EI.8 for the concatenation-shaped
    root.  It is *permutation*, not list equality, because
    `smtRootListAux` partitions and therefore reorders; the
    distinctness hypothesis is what makes "equal as maps" the right
    reading of that conclusion. -/
theorem smtRootListAux_perm_of_eq_under_collision_free :
    ∀ (d : Nat), d ≤ 256 → ∀ (e₁ e₂ : SmtEntries),
      BitsDistinctBelow d e₁ → BitsDistinctBelow d e₂ →
      EntriesEncodable e₁ → EntriesEncodable e₂ →
      CollisionFreeOn
        (smtRootPreimages d e₁ ++ smtRootPreimages d e₂ ++ emptyRootPreimages d)
        hashBytes →
      smtRootListAux d e₁ = smtRootListAux d e₂ →
      e₁.Perm e₂
  | 0, _, e₁, e₂, h_wf₁, h_wf₂, h_enc₁, h_enc₂, h_cf, h_eq => by
    -- Depth 0: each bucket is empty or a single leaf.  Three of the
    -- four combinations are settled by leaf/empty separation; the
    -- fourth by leaf injectivity.
    have h_len₁ := length_le_one_of_bitsDistinctBelow_zero h_wf₁
    have h_len₂ := length_le_one_of_bitsDistinctBelow_zero h_wf₂
    match e₁, h_len₁, e₂, h_len₂ with
    | [], _, [], _ => exact List.Perm.refl _
    | [], _, [(k, v)], _ =>
      exact absurd h_eq.symm (leafHash_ne_emptyRootAt_zero k v (h_cf.mono (by
        intro x hx
        rcases List.mem_cons.mp hx with rfl | hx'
        · exact List.mem_append_left _
            (List.mem_append_right _ (by simp [smtRootPreimages]))
        · rw [List.mem_singleton.mp hx']
          exact List.mem_append_right _ (by simp [emptyRootPreimages]))))
    | [(k, v)], _, [], _ =>
      exact absurd h_eq (leafHash_ne_emptyRootAt_zero k v (h_cf.mono (by
        intro x hx
        rcases List.mem_cons.mp hx with rfl | hx'
        · exact List.mem_append_left _
            (List.mem_append_left _ (by simp [smtRootPreimages]))
        · rw [List.mem_singleton.mp hx']
          exact List.mem_append_right _ (by simp [emptyRootPreimages]))))
    | [(k₁, v₁)], _, [(k₂, v₂)], _ =>
      have hb₁ := h_enc₁ (k₁, v₁) (by simp)
      have hb₂ := h_enc₂ (k₂, v₂) (by simp)
      obtain ⟨hk, hv⟩ := leafHash_inj_under_collision_free k₁ v₁ k₂ v₂
        (h_cf.mono (by
          intro x hx
          rcases List.mem_cons.mp hx with rfl | hx'
          · exact List.mem_append_left _
              (List.mem_append_left _ (by simp [smtRootPreimages]))
          · rw [List.mem_singleton.mp hx']
            exact List.mem_append_left _
              (List.mem_append_right _ (by simp [smtRootPreimages]))))
        hb₁.1 hb₁.2 hb₂.1 hb₂.2 h_eq
      rw [hk, hv]
  | d + 1, h_d, e₁, e₂, h_wf₁, h_wf₂, h_enc₁, h_enc₂, h_cf, h_eq => by
    by_cases h_e₁ : e₁ = []
    · subst h_e₁
      by_cases h_e₂ : e₂ = []
      · subst h_e₂; exact List.Perm.refl _
      · -- Empty root on the left, populated bucket on the right.
        exact absurd h_eq.symm
          (by
            rw [smtRootListAux_nil (d + 1) h_d]
            exact smtRootListAux_ne_emptyRootAt_under_collision_free (d + 1) h_d e₂
              h_wf₂ h_enc₂ h_e₂
              (h_cf.mono (by
                intro x hx
                rcases List.mem_append.mp hx with hx' | hx'
                · exact List.mem_append_left _ (List.mem_append_right _ hx')
                · exact List.mem_append_right _ hx')))
    · by_cases h_e₂ : e₂ = []
      · subst h_e₂
        exact absurd h_eq
          (by
            rw [smtRootListAux_nil (d + 1) h_d]
            exact smtRootListAux_ne_emptyRootAt_under_collision_free (d + 1) h_d e₁
              h_wf₁ h_enc₁ h_e₁
              (h_cf.mono (by
                intro x hx
                rcases List.mem_append.mp hx with hx' | hx'
                · exact List.mem_append_left _ (List.mem_append_left _ hx')
                · exact List.mem_append_right _ hx')))
      · -- Both populated: undo the outer hash, then recurse on both
        -- halves and recombine the two permutations.
        have h_ne₁ : e₁.isEmpty = false := by
          cases e₁ with
          | nil => exact absurd rfl h_e₁
          | cons _ _ => rfl
        have h_ne₂ : e₂.isEmpty = false := by
          cases e₂ with
          | nil => exact absurd rfl h_e₂
          | cons _ _ => rfl
        have h_root : ∀ e : SmtEntries, e.isEmpty = false →
            smtRootListAux (d + 1) e
              = hashBytes (smtRootListAux d (e.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
                  smtRootListAux d (e.filter (fun p => BitsKey.keyBit p.1 d))) := by
          intro e h_e
          show (if e.isEmpty then _ else _) = _
          rw [if_neg (by simp [h_e])]
        have h_mem : ∀ e : SmtEntries, e.isEmpty = false →
            (smtRootListAux d (e.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
              smtRootListAux d (e.filter (fun p => BitsKey.keyBit p.1 d))) ∈
              smtRootPreimages (d + 1) e := by
          intro e h_e
          show _ ∈ (if e.isEmpty then [] else _)
          rw [if_neg (by simp [h_e])]
          exact List.mem_cons_self
        have h_split : smtRootListAux d (e₁.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
              smtRootListAux d (e₁.filter (fun p => BitsKey.keyBit p.1 d))
            = smtRootListAux d (e₂.filter (fun p => ! BitsKey.keyBit p.1 d)) ++
              smtRootListAux d (e₂.filter (fun p => BitsKey.keyBit p.1 d)) := by
          refine h_cf.apply
            (List.mem_append_left _ (List.mem_append_left _ (h_mem e₁ h_ne₁)))
            (List.mem_append_left _ (List.mem_append_right _ (h_mem e₂ h_ne₂))) ?_
          rw [← h_root e₁ h_ne₁, ← h_root e₂ h_ne₂]
          exact h_eq
        obtain ⟨h_lo, h_hi⟩ :=
          byteArray_append_inj_left _ _ _ _ h_split
            (by rw [smtRootListAux_size, smtRootListAux_size])
        -- Collision-freeness restricted to a matched pair of halves.
        have h_cf_half : ∀ b : Bool,
            CollisionFreeOn
              (smtRootPreimages d (e₁.filter (fun p =>
                  if b then BitsKey.keyBit p.1 d else ! BitsKey.keyBit p.1 d)) ++
                smtRootPreimages d (e₂.filter (fun p =>
                  if b then BitsKey.keyBit p.1 d else ! BitsKey.keyBit p.1 d)) ++
                emptyRootPreimages d)
              hashBytes := by
          intro b
          refine h_cf.mono ?_
          intro x hx
          have h_tail : ∀ (e : SmtEntries), e.isEmpty = false →
              ∀ y ∈ smtRootPreimages d (e.filter (fun p =>
                  if b then BitsKey.keyBit p.1 d else ! BitsKey.keyBit p.1 d)),
                y ∈ smtRootPreimages (d + 1) e := by
            intro e h_e y hy
            show _ ∈ (if e.isEmpty then [] else _)
            rw [if_neg (by simp [h_e])]
            refine List.mem_cons_of_mem _ ?_
            cases b with
            | false => exact List.mem_append_left _ (by simpa using hy)
            | true  => exact List.mem_append_right _ (by simpa using hy)
          rcases List.mem_append.mp hx with hx' | hx'
          · rcases List.mem_append.mp hx' with hx'' | hx''
            · exact List.mem_append_left _
                (List.mem_append_left _ (h_tail e₁ h_ne₁ x hx''))
            · exact List.mem_append_left _
                (List.mem_append_right _ (h_tail e₂ h_ne₂ x hx''))
          · exact List.mem_append_right _ (List.mem_cons_of_mem _ hx')
        have p_lo : (e₁.filter (fun p => ! BitsKey.keyBit p.1 d)).Perm
              (e₂.filter (fun p => ! BitsKey.keyBit p.1 d)) :=
          smtRootListAux_perm_of_eq_under_collision_free d (by omega) _ _
            (BitsDistinctBelow.filter_low h_wf₁) (BitsDistinctBelow.filter_low h_wf₂)
            (EntriesEncodable.sublist List.filter_sublist h_enc₁)
            (EntriesEncodable.sublist List.filter_sublist h_enc₂)
            (by simpa using h_cf_half false) h_lo
        have p_hi : (e₁.filter (fun p => BitsKey.keyBit p.1 d)).Perm
              (e₂.filter (fun p => BitsKey.keyBit p.1 d)) :=
          smtRootListAux_perm_of_eq_under_collision_free d (by omega) _ _
            (BitsDistinctBelow.filter_high h_wf₁) (BitsDistinctBelow.filter_high h_wf₂)
            (EntriesEncodable.sublist List.filter_sublist h_enc₁)
            (EntriesEncodable.sublist List.filter_sublist h_enc₂)
            (by simpa using h_cf_half true) h_hi
        exact ((perm_partition d e₁).symm.trans
          (List.Perm.append p_lo p_hi)).trans (perm_partition d e₂)

/-! ## Cell updates

A cell root exists so that a post-root is computable on L1 from a
pre-root plus the step's proven writes.  Writing a cell replaces one
leaf and leaves every sibling on its path alone, so the new root is
the same walk with a new leaf — that is all `smtUpdateRoot` is.

The property that makes it usable in adjudication is not that it
computes *something*, but that it computes the *same* thing whichever
verifying proof the responder supplies.  Otherwise a responder facing
a losing terminal step could shop for a proof whose update lands on
the root it needs.  `smtUpdateRoot_proof_independent` rules that out,
and it needs a strengthening of the existing walk injectivity: equal
walks must force equal SIBLINGS, not only equal leaves. -/

/-- Strengthened walk injectivity.  `walk_leaf_inj_under_collision_free`
    concludes only `leaf₁ = leaf₂`; its induction establishes the
    per-level sibling equality on the way and then discards it.  The
    update argument needs it kept. -/
theorem walk_inj_under_collision_free :
    ∀ (bits : List Bool) (sibs₁ sibs₂ : List ByteArray)
      (leaf₁ leaf₂ : ByteArray),
      CollisionFreeOn
        (walkPreimages leaf₁ (sibs₁.zip bits) ++
         walkPreimages leaf₂ (sibs₂.zip bits)) hashBytes →
      sibs₁.length = bits.length →
      sibs₂.length = bits.length →
      leaf₁.size = 32 →
      leaf₂.size = 32 →
      (∀ s ∈ sibs₁, s.size = 32) →
      (∀ s ∈ sibs₂, s.size = 32) →
      (sibs₁.zip bits).foldl stepPair leaf₁ =
        (sibs₂.zip bits).foldl stepPair leaf₂ →
      leaf₁ = leaf₂ ∧ sibs₁ = sibs₂ := by
  intro bits
  induction bits with
  | nil =>
    intro sibs₁ sibs₂ leaf₁ leaf₂ _ h_len₁ h_len₂ _ _ _ _ h_walk
    have h₁ : sibs₁ = [] := List.eq_nil_of_length_eq_zero h_len₁
    have h₂ : sibs₂ = [] := List.eq_nil_of_length_eq_zero h_len₂
    subst h₁; subst h₂
    exact ⟨by simpa using h_walk, rfl⟩
  | cons b rest_bits ih =>
    intro sibs₁ sibs₂ leaf₁ leaf₂ h_cf h_len₁ h_len₂
      h_leaf₁ h_leaf₂ h_s₁ h_s₂ h_walk
    cases sibs₁ with
    | nil => simp at h_len₁
    | cons s₁ rest₁ =>
      cases sibs₂ with
      | nil => simp at h_len₂
      | cons s₂ rest₂ =>
        -- Peel one level off each fold.
        rw [show ((s₁ :: rest₁).zip (b :: rest_bits)).foldl stepPair leaf₁ =
              (rest₁.zip rest_bits).foldl stepPair (stepPair leaf₁ (s₁, b)) from by
            simp [List.zip_cons_cons, List.foldl_cons],
          show ((s₂ :: rest₂).zip (b :: rest_bits)).foldl stepPair leaf₂ =
              (rest₂.zip rest_bits).foldl stepPair (stepPair leaf₂ (s₂, b)) from by
            simp [List.zip_cons_cons, List.foldl_cons]] at h_walk
        have h_expand :
            walkPreimages leaf₁ ((s₁ :: rest₁).zip (b :: rest_bits)) ++
              walkPreimages leaf₂ ((s₂ :: rest₂).zip (b :: rest_bits)) =
            smtStepPreimage leaf₁ s₁ b ::
              (walkPreimages (stepPair leaf₁ (s₁, b)) (rest₁.zip rest_bits) ++
                (smtStepPreimage leaf₂ s₂ b ::
                  walkPreimages (stepPair leaf₂ (s₂, b)) (rest₂.zip rest_bits))) := by
          simp [List.zip_cons_cons, walkPreimages]
        rw [h_expand] at h_cf
        obtain ⟨h_step_eq, h_rest_eq⟩ :=
          ih rest₁ rest₂ (stepPair leaf₁ (s₁, b)) (stepPair leaf₂ (s₂, b))
            (h_cf.mono (by
              intro z hz
              rcases List.mem_append.mp hz with hz₁ | hz₂
              · exact List.mem_cons_of_mem _ (List.mem_append_left _ hz₁)
              · exact List.mem_cons_of_mem _ (List.mem_append_right _
                  (List.mem_cons_of_mem _ hz₂))))
            (by simp [List.length_cons] at h_len₁; exact h_len₁)
            (by simp [List.length_cons] at h_len₂; exact h_len₂)
            (stepPair_size _ _) (stepPair_size _ _)
            (fun s hs => h_s₁ s (List.mem_cons_of_mem _ hs))
            (fun s hs => h_s₂ s (List.mem_cons_of_mem _ hs))
            h_walk
        -- One backward step recovers both the leaf and this level's sibling.
        obtain ⟨h_leaf_eq, h_sib_eq⟩ :=
          smtStep_inj_under_collision_free leaf₁ leaf₂ s₁ s₂ b
            (h_cf.mono (by
              intro z hz
              simp only [List.mem_cons, List.not_mem_nil, or_false] at hz
              rcases hz with rfl | rfl
              · exact List.mem_cons_self
              · exact List.mem_cons_of_mem _
                  (List.mem_append_right _ List.mem_cons_self)))
            h_leaf₁ h_leaf₂ (h_s₁ s₁ List.mem_cons_self) (h_s₂ s₂ List.mem_cons_self)
            h_step_eq
        exact ⟨h_leaf_eq, by rw [h_sib_eq, h_rest_eq]⟩

/-- The root after writing `newValue` into the cell the proof opens.
    Same walk, new leaf: writing a cell replaces exactly one leaf and
    leaves every sibling on its path unchanged. -/
def smtUpdateRoot {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (key : K) (newValue : V) (proof : SmtCellProof) : ByteArray :=
  smtWalk key newValue proof

/-- The updated root is 32 bytes, so it composes with the next
    update in a multi-write step. -/
theorem smtUpdateRoot_size {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (key : K) (newValue : V) (proof : SmtCellProof)
    (h_wf : proof.isWellFormed = true) :
    (smtUpdateRoot key newValue proof).size = 32 := by
  unfold smtUpdateRoot smtWalk
  -- The fold's carrier is 32 bytes at every step, starting from the leaf.
  have h_gen : ∀ (l : List (ByteArray × Bool)) (acc : ByteArray),
      acc.size = 32 → (l.foldl stepPair acc).size = 32 := by
    intro l
    induction l with
    | nil => intro acc h; exact h
    | cons p rest ih => intro acc _; exact ih (stepPair acc p) (stepPair_size _ _)
  let _ := h_wf
  exact h_gen _ _ (leafHash_size _ _)

/-- Completeness of the update: the same opening verifies the new
    value against the updated root.  This is what makes a chain of
    writes well-formed — the next write's opening is against a root
    the previous one produced. -/
theorem smtUpdateRoot_verifies {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (key : K) (newValue : V) (proof : SmtCellProof)
    (h_wf : proof.isWellFormed = true) :
    verifySmtCellProof (smtUpdateRoot key newValue proof) key newValue proof = true :=
  verifySmtCellProof_walks_to_root key newValue proof h_wf

/-- **The updated root does not depend on which verifying proof was
    supplied.**

    Two proofs that both open `(root, key, value)` produce the same
    root after writing `newValue`.  Without this a responder facing a
    losing terminal step could shop among openings for one whose
    update lands on the root it needs; with it, the post-root the L1
    computes is a function of `(pre-root, key, new value)` alone. -/
theorem smtUpdateRoot_proof_independent
    {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (root : ByteArray) (key : K) (value newValue : V)
    (proof₁ proof₂ : SmtCellProof)
    (h_cf : CollisionFreeOn
      (smtCellProofPreimages key value value proof₁ proof₂) hashBytes)
    (h₁ : verifySmtCellProof root key value proof₁ = true)
    (h₂ : verifySmtCellProof root key value proof₂ = true) :
    smtUpdateRoot key newValue proof₁ = smtUpdateRoot key newValue proof₂ := by
  unfold verifySmtCellProof at h₁ h₂
  rw [Bool.and_eq_true] at h₁ h₂
  obtain ⟨h_wf₁, h_walk₁⟩ := h₁
  obtain ⟨h_wf₂, h_walk₂⟩ := h₂
  have h_eq : ((expandSiblings proof₁).zip (keyBits key)).foldl stepPair
                (leafHash key value)
            = ((expandSiblings proof₂).zip (keyBits key)).foldl stepPair
                (leafHash key value) := by
    have e₁ : smtWalk key value proof₁ = root := decide_eq_true_eq.mp h_walk₁
    have e₂ : smtWalk key value proof₂ = root := decide_eq_true_eq.mp h_walk₂
    unfold smtWalk at e₁ e₂
    rw [e₁, e₂]
  -- Equal walks with the same leaf force the sibling lists equal.
  obtain ⟨_, h_sibs⟩ :=
    walk_inj_under_collision_free (keyBits key)
      (expandSiblings proof₁) (expandSiblings proof₂)
      (leafHash key value) (leafHash key value)
      h_cf.append_left
      (by rw [expandSiblings_length, keyBits_length])
      (by rw [expandSiblings_length, keyBits_length])
      (leafHash_size _ _) (leafHash_size _ _)
      (expandSiblings_all_32 proof₁ h_wf₁)
      (expandSiblings_all_32 proof₂ h_wf₂)
      h_eq
  -- The new walk differs only in its leaf, so it agrees too.
  unfold smtUpdateRoot smtWalk
  rw [h_sibs]

/-! ## Operational coherence of the canonical path

Soundness — nothing above — is stated over *any* verifying proofs and
does not care how a proof was built.  The honest defender's side does
care: it must be able to construct an opening that reproduces the
published root, or it cannot compute the post-root the L1 will
accept, which is the failure mode this whole line of work exists to
remove.

`buildSmtCellProof`'s docstring records that coherence as validated
by per-fixture tests rather than proved.  This section proves the
substantive half: the canonical sibling path along a key's route
walks back to exactly the root the recursion computes.  The
representation half — that the shipped bitmask-compressed encoding
expands to this path — is `expandSiblings ∘ buildSmtCellProof`, and
is bookkeeping over `setBitmaskBit` rather than content. -/

/-- The key's bit sequence up to depth `d`, in the order the walk
    consumes it (depth 0 first, nearest the leaf). -/
def keyBitsUpTo (d : Nat) (key : ByteArray) : List Bool :=
  (List.range d).map (BitsKey.keyBit key)

/-- `keyBits` is the full-depth instance. -/
theorem keyBits_eq_keyBitsUpTo (key : ByteArray) :
    keyBits key = keyBitsUpTo smtDepth key := rfl

/-- `keyBitsUpTo d` has length `d`. -/
theorem keyBitsUpTo_length (d : Nat) (key : ByteArray) :
    (keyBitsUpTo d key).length = d := by
  unfold keyBitsUpTo
  rw [List.length_map, List.length_range]

/-- The uncompressed sibling path for `key` through `entries`, depth
    0 first.  At each level the sibling is the root of the half the
    key does *not* live in. -/
def canonicalSiblings : Nat → SmtEntries → ByteArray → List ByteArray
  | 0,     _,       _   => []
  | d + 1, entries, key =>
    let lo := entries.filter (fun e => ! BitsKey.keyBit e.1 d)
    let hi := entries.filter (fun e => BitsKey.keyBit e.1 d)
    if BitsKey.keyBit key d then
      canonicalSiblings d hi key ++ [smtRootListAux d lo]
    else
      canonicalSiblings d lo key ++ [smtRootListAux d hi]

/-- The canonical path has one sibling per level. -/
theorem canonicalSiblings_length (d : Nat) (entries : SmtEntries) (key : ByteArray) :
    (canonicalSiblings d entries key).length = d := by
  induction d generalizing entries with
  | zero => rfl
  | succ k ih =>
    show (if BitsKey.keyBit key k then
            canonicalSiblings k (entries.filter (fun e => BitsKey.keyBit e.1 k)) key ++
              [smtRootListAux k (entries.filter (fun e => ! BitsKey.keyBit e.1 k))]
          else
            canonicalSiblings k (entries.filter (fun e => ! BitsKey.keyBit e.1 k)) key ++
              [smtRootListAux k (entries.filter (fun e => BitsKey.keyBit e.1 k))]).length
        = k + 1
    by_cases h : BitsKey.keyBit key k
    · rw [if_pos h, List.length_append, List.length_singleton, ih]
    · rw [if_neg h, List.length_append, List.length_singleton, ih]

/-- **Canonical-path coherence.**  Walking the canonical sibling path
    back from the key's leaf reproduces the bucket's root.

    This is the honest defender's guarantee: the opening it can
    construct is one the verifier accepts against the published root,
    so the post-root it computes is the one the L1 computes too. -/
theorem canonicalSiblings_walks_to_root :
    ∀ (d : Nat) (entries : SmtEntries) (key value : ByteArray),
      (key, value) ∈ entries → BitsDistinctBelow d entries →
      ((canonicalSiblings d entries key).zip (keyBitsUpTo d key)).foldl stepPair
          (leafHash key value)
        = smtRootListAux d entries := by
  intro d
  induction d with
  | zero =>
    intro entries key value h_mem h_wf
    -- At depth 0 the bucket holds this entry alone.
    have h_len := length_le_one_of_bitsDistinctBelow_zero h_wf
    match entries, h_mem, h_len with
    | [(_, _)], h_mem, _ =>
      rw [← List.mem_singleton.mp h_mem]
      rfl
  | succ k ih =>
    intro entries key value h_mem h_wf
    have h_ne : entries.isEmpty = false := by
      cases entries with
      | nil => exact absurd h_mem (by simp)
      | cons _ _ => rfl
    have h_bits : keyBitsUpTo (k + 1) key
                = keyBitsUpTo k key ++ [BitsKey.keyBit key k] := by
      unfold keyBitsUpTo
      rw [List.range_succ, List.map_append, List.map_cons, List.map_nil]
    have h_root : smtRootListAux (k + 1) entries
                = hashBytes
                    (smtRootListAux k (entries.filter (fun e => ! BitsKey.keyBit e.1 k)) ++
                      smtRootListAux k (entries.filter (fun e => BitsKey.keyBit e.1 k))) := by
      show (if entries.isEmpty then _ else _) = _
      rw [if_neg (by simp [h_ne])]
    have h_zip_len : ∀ (f : SmtEntries),
        (canonicalSiblings k f key).length = (keyBitsUpTo k key).length := by
      intro f
      rw [canonicalSiblings_length, keyBitsUpTo_length]
    have h_path : canonicalSiblings (k + 1) entries key
                = (if BitsKey.keyBit key k then
                     canonicalSiblings k (entries.filter (fun e => BitsKey.keyBit e.1 k)) key ++
                       [smtRootListAux k (entries.filter (fun e => ! BitsKey.keyBit e.1 k))]
                   else
                     canonicalSiblings k (entries.filter (fun e => ! BitsKey.keyBit e.1 k)) key ++
                       [smtRootListAux k (entries.filter (fun e => BitsKey.keyBit e.1 k))]) := rfl
    rw [h_path, h_bits, h_root]
    by_cases h_bit : BitsKey.keyBit key k
    · rw [if_pos h_bit, List.zip_append (h_zip_len _), List.foldl_append,
        ih (entries.filter (fun e => BitsKey.keyBit e.1 k)) key value
          (List.mem_filter.mpr ⟨h_mem, h_bit⟩) (BitsDistinctBelow.filter_high h_wf)]
      show smtStep _ _ (BitsKey.keyBit key k) = _
      rw [h_bit]
      rfl
    · rw [if_neg h_bit, List.zip_append (h_zip_len _), List.foldl_append,
        ih (entries.filter (fun e => ! BitsKey.keyBit e.1 k)) key value
          (List.mem_filter.mpr ⟨h_mem, by simp [h_bit]⟩)
          (BitsDistinctBelow.filter_low h_wf)]
      show smtStep _ _ (BitsKey.keyBit key k) = _
      rw [show BitsKey.keyBit key k = false from by simpa using h_bit]
      rfl

/-- Full-depth corollary: an opening built from the canonical path
    verifies against the state's own SMT root. -/
theorem canonicalSiblings_verifies (entries : SmtEntries) (key value : ByteArray)
    (h_mem : (key, value) ∈ entries)
    (h_wf : BitsDistinctBelow smtDepth entries) :
    ((canonicalSiblings smtDepth entries key).zip (keyBits key)).foldl stepPair
        (leafHash key value)
      = smtRootListAux smtDepth entries :=
  canonicalSiblings_walks_to_root smtDepth entries key value h_mem h_wf

end FaultProof
end LegalKernel

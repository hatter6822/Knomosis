-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Smt — sparse-Merkle-tree (SMT) cell-proof
spec + soundness (Workstream SC.1).

`docs/planning/smt_cell_proofs_plan.md` §SC.1 ships the
gas-efficient cell-proof scheme that the L1 step VM consumes
instead of the witness-state form (`LegalKernel/FaultProof/Cell.lean`).
The witness-state form is sound but costs `O(|sub-state|)` gas;
the SMT form costs `O(log |sub-state|)` gas (256 hashes for a
256-bit key space).

**Design.**  A sparse Merkle tree of depth 256: each leaf is a
`hashBytes (encode key ++ encode value)`; each internal node is
the `hashBytes (left_child ++ right_child)`.  Empty sub-trees at
depth `d` compress to a fixed canonical hash `H_d` derived
recursively from `H_0 = hashBytes "EMPTY_LEAF"` and
`H_{d+1} = hashBytes (H_d ++ H_d)`.

An `SmtCellProof` carries the sibling hashes along the path
from leaf to root, plus a 256-bit bitmask indicating which
siblings are non-canonical-empty (so we can omit canonical-empty
siblings from the on-wire encoding without losing information).

**Headline theorems.**

  * `smtCellProof_no_value_substitution` (the load-bearing
    operational security property) — under `CollisionFree
    hashBytes` + encoder injectivity for the value type, the
    verifier accepts at most one value per `(root, key)` pair.
  * `smtCellProof_sound_under_collision_free` — alias for
    `no_value_substitution` matching the plan's naming.

**Existence-form caveat.**  The plan's §2.4 sketches an
existential soundness theorem of the shape
`∃ m : TreeMap, smtRoot m = root ∧ m[key]? = some v` after a
verifying proof.  The literal existential is not provable under
`CollisionFree hashBytes` alone: constructing the witness map
requires finding pre-images of arbitrary `ByteArray` sibling
hashes, which is a hash-inversion problem that collision-
resistance does not solve.  The operationally-meaningful
*uniqueness* form (`no_value_substitution`) IS provable and is
exactly the binding property the L1 contract relies on (two
verifying proofs cannot witness different values).

This module is **not** part of the trusted computing base.
Bugs here would only affect the deployment-side fault-proof
tooling; the kernel's invariant proofs are unaffected.  Every
theorem here is `sorry`-free and depends only on the canonical
Lean built-ins (`propext`, `Classical.choice`, `Quot.sound`).
-/

import LegalKernel.Bridge.Eip712
import LegalKernel.Encoding.Encodable
import LegalKernel.Runtime.Hash

-- Increase elaboration recursion depth for the SMT spec's
-- helper-lemma proofs.  The hash-chain-of-256-levels structure
-- triggers deep elaboration even when the proof bodies are
-- short.
set_option maxRecDepth 1024

namespace LegalKernel
namespace FaultProof

open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## SMT depth -/

/-- Canonical SMT depth: 256 levels.  Each cell key is treated
    as a 256-bit value (MSB-first); shorter keys are
    right-padded with zero bits via `BitsKey.keyBit` returning
    `false` for out-of-range indices. -/
def smtDepth : Nat := 256

/-! ## `BitsKey` typeclass -/

/-- Read a single bit (MSB-first) of a key, indexed by depth.
    `i = 0` is the most significant bit of the key (top of the
    tree); `i = smtDepth - 1` is the least significant.  For
    keys shorter than `smtDepth` bits, the instance must return
    `false` for the out-of-range indices.

    Convention: MSB-first matches the standard Ethereum SMT
    layout and ensures sorted key-order aligns with top-down
    tree traversal. -/
class BitsKey (K : Type) where
  /-- The `i`-th bit of `k` (MSB-first), or `false` if `i ≥
      keyBitWidth`. -/
  keyBit : K → Nat → Bool

/-! ### `BitsKey` instances -/

/-- `ByteArray` bit-key instance: read bit `i` from byte `i / 8`,
    position `7 - i % 8` (MSB-first within each byte).  Returns
    `false` for `i ≥ 8 * size`. -/
instance instBitsKeyByteArray : BitsKey ByteArray where
  keyBit k i :=
    if h : i / 8 < k.size then
      decide (((k[i / 8]'h).toNat >>> (7 - i % 8)) % 2 = 1)
    else
      false

/-- `UInt64` bit-key instance: read bit `i` from the underlying
    64-bit integer, MSB-first.  Returns `false` for `i ≥ 64`.
    Covers `ActorId`, `ResourceId`, `DepositId`, `WithdrawalId`
    via their `abbrev` aliases. -/
instance instBitsKeyUInt64 : BitsKey UInt64 where
  keyBit k i :=
    if i < 64 then
      decide ((k.toNat >>> (63 - i)) % 2 = 1)
    else
      false

/-! ## Empty-subtree canonical hashes (SC.1.a) -/

/-- The seed bytes for `H_0`: the ASCII string `"EMPTY_LEAF"`
    encoded as UTF-8.  These 10 bytes are the same regardless
    of hash implementation; the value of `H_0` itself depends
    on the linked `hashBytes` adaptor. -/
def emptyLeafSeedBytes : ByteArray :=
  "EMPTY_LEAF".toUTF8

/-- Tail-recursive builder for the canonical empty-subtree
    hashes.  Starting from a singleton `#[H_0]`, appends `H_{d+1}
    = hashBytes (H_d ++ H_d)` `n` times. -/
private def buildEmptyHashesAux : Nat → Array ByteArray → Array ByteArray
  | 0,     acc => acc
  | n + 1, acc =>
    let prev := acc.back?.getD ByteArray.empty
    buildEmptyHashesAux n (acc.push (hashBytes (prev ++ prev)))

/-- The 256 canonical empty-subtree hashes `[H_0, H_1, …, H_255]`.

    `H_0 = hashBytes emptyLeafSeedBytes`; subsequent entries are
    `H_{d+1} = hashBytes (H_d ++ H_d)`.  Materialised as an
    `Array ByteArray` of size 256 (proved by
    `emptySubtreeHashes_size`).

    The values depend on the linked `hashBytes` implementation;
    the SMT spec is implementation-agnostic — it relies only on
    `hashBytes_size` and `CollisionFree hashBytes`. -/
def emptySubtreeHashes : Array ByteArray :=
  buildEmptyHashesAux 255 #[hashBytes emptyLeafSeedBytes]

/-- Helper lemma: `buildEmptyHashesAux n acc` produces an array
    whose size is `acc.size + n`. -/
private theorem buildEmptyHashesAux_size (n : Nat) (acc : Array ByteArray) :
    (buildEmptyHashesAux n acc).size = acc.size + n := by
  induction n generalizing acc with
  | zero => simp [buildEmptyHashesAux]
  | succ k ih =>
    unfold buildEmptyHashesAux
    rw [ih, Array.size_push]
    omega

/-- The empty-subtree-hash array has size exactly 256. -/
theorem emptySubtreeHashes_size : emptySubtreeHashes.size = 256 := by
  unfold emptySubtreeHashes
  rw [buildEmptyHashesAux_size]
  rfl

/-- Every element of the array produced by `buildEmptyHashesAux`,
    assuming every element of the seed is 32 bytes, is itself 32
    bytes. -/
private theorem buildEmptyHashesAux_all_32 :
    ∀ (n : Nat) (acc : Array ByteArray),
      (∀ b ∈ acc, ByteArray.size b = 32) →
      ∀ b ∈ buildEmptyHashesAux n acc, ByteArray.size b = 32
  | 0,     acc, h_acc => by
    intro b hb
    unfold buildEmptyHashesAux at hb
    exact h_acc b hb
  | n + 1, acc, h_acc => by
    intro b hb
    unfold buildEmptyHashesAux at hb
    apply buildEmptyHashesAux_all_32 n
        (acc.push (hashBytes ((acc.back?.getD ByteArray.empty) ++
                              (acc.back?.getD ByteArray.empty))))
    · intro b' hb'
      rcases Array.mem_push.mp hb' with hb_mem | hb_eq
      · exact h_acc b' hb_mem
      · rw [hb_eq]
        exact hashBytes_size _
    · exact hb

/-- Every entry of `emptySubtreeHashes` is exactly 32 bytes. -/
theorem emptySubtreeHashes_get_size
    (d : Nat) (h : d < emptySubtreeHashes.size) :
    (emptySubtreeHashes[d]'h).size = 32 := by
  have h_seed : ∀ b ∈ (#[hashBytes emptyLeafSeedBytes] : Array ByteArray),
                  ByteArray.size b = 32 := by
    intro b hb
    have h_eq : b = hashBytes emptyLeafSeedBytes := by
      simp at hb; exact hb
    rw [h_eq]
    exact hashBytes_size _
  have h_all := buildEmptyHashesAux_all_32 255
                  (#[hashBytes emptyLeafSeedBytes]) h_seed
  exact h_all _ (Array.getElem_mem h)

/-- Indexed access into `emptySubtreeHashes` with a fallback for
    out-of-range indices.  Callers that know `d < 256` can omit
    the fallback case via `emptySubtreeHashes_size`. -/
def emptySubtreeHash (d : Nat) : ByteArray :=
  emptySubtreeHashes[d]?.getD ByteArray.empty

/-- Convenience corollary: `emptySubtreeHash d` returns a
    32-byte hash for any `d < 256`. -/
theorem emptySubtreeHash_size (d : Nat) (h : d < 256) :
    (emptySubtreeHash d).size = 32 := by
  unfold emptySubtreeHash
  have hd : d < emptySubtreeHashes.size := by
    rw [emptySubtreeHashes_size]; exact h
  rw [Array.getElem?_eq_getElem hd]
  exact emptySubtreeHashes_get_size d hd

/-! ## `SmtCellProof` (SC.1.c) -/

/-- A proof witnessing the value of a single cell at the
    committed state root.

    The proof's `siblings` array carries only the
    non-canonical-empty sibling hashes (in depth order, lowest
    depth first); canonical-empty siblings are inferred via the
    `bitmask` and the pre-computed `emptySubtreeHash` table.

    Well-formedness preconditions (enforced by
    `verifySmtCellProof`):
      * `bitmask.size = 32` (= 256 bits).
      * Every sibling has size exactly 32. -/
structure SmtCellProof where
  /-- The non-canonical-empty sibling hashes, in depth order
      (low-to-high).  Each entry is a 32-byte `hashBytes`
      output. -/
  siblings : Array ByteArray
  /-- A 32-byte (256-bit) bitmask; bit `d` is `1` iff the
      sibling at depth `d` is non-canonical-empty (drawn from
      `siblings`). -/
  bitmask  : ByteArray
  deriving Repr

namespace SmtCellProof

/-- The empty proof: no non-canonical-empty siblings, all-zero
    bitmask.  Represents a path with all canonical-empty
    siblings (e.g. the cell proof for a singleton map). -/
def empty : SmtCellProof where
  siblings := #[]
  bitmask  := ByteArray.mk (Array.replicate 32 (0 : UInt8))

/-- Test bit `d` of the proof's 32-byte bitmask.  Returns
    `false` for `d ≥ 256` and for malformed bitmasks. -/
def bitmaskBit (proof : SmtCellProof) (d : Nat) : Bool :=
  if h : d / 8 < proof.bitmask.size then
    decide (((proof.bitmask[d / 8]'h).toNat >>> (d % 8)) % 2 = 1)
  else
    false

/-- A proof is **well-formed** iff:
      * the bitmask is exactly 32 bytes,
      * every sibling is exactly 32 bytes.

    Note: we DO NOT require `siblings.size = popcountBitmask`
    here — the verifier handles "extra" or "missing" siblings
    by zero-padding (out-of-range lookups return a 32-byte
    sentinel `paddingHash`).  This keeps the soundness proof
    simple (no cursor-invariant tracking) while still preventing
    forged proofs: a malformed proof's walk produces a different
    output than the canonical proof for any real map. -/
def isWellFormed (proof : SmtCellProof) : Bool :=
  decide (proof.bitmask.size = 32) &&
  proof.siblings.all (fun s => decide (s.size = 32))

/-- Helper: well-formed proofs have all 32-byte siblings. -/
theorem isWellFormed_implies_all_siblings_32
    (proof : SmtCellProof) (h : proof.isWellFormed = true) :
    ∀ s ∈ proof.siblings, s.size = 32 := by
  unfold isWellFormed at h
  rw [Bool.and_eq_true] at h
  obtain ⟨_, h_all⟩ := h
  intro s hs
  -- Translate `Array.all = true` to membership-based forall.
  rw [Array.all_eq_true] at h_all
  obtain ⟨i, hi, rfl⟩ := Array.mem_iff_getElem.mp hs
  exact decide_eq_true_eq.mp (h_all i hi)

end SmtCellProof

/-! ## Padding hash for out-of-bounds sibling lookups

When the proof's siblings cursor escapes bounds during the
walk (e.g. because the bitmask has more set bits than the
siblings array has entries), we substitute a canonical 32-byte
zero hash.  This keeps the walk function total without
requiring a cursor-bound invariant, and ensures the walk's
output is well-defined for malformed proofs.

The padding hash is exactly 32 zero bytes — distinct from any
real `hashBytes` output (which is non-trivial under
collision-resistance). -/

/-- The 32-byte padding hash used for out-of-bounds sibling
    lookups.  All zeros, exactly 32 bytes. -/
def paddingHash : ByteArray :=
  ByteArray.mk (Array.replicate 32 (0 : UInt8))

/-- The padding hash is exactly 32 bytes. -/
theorem paddingHash_size : paddingHash.size = 32 := by
  unfold paddingHash
  show (Array.replicate 32 (0 : UInt8)).size = 32
  simp [Array.size_replicate]

/-! ## Leaf hashing -/

/-- Pack an `Encodable` value as a `ByteArray` for hashing.
    Composes `Encodable.encode` (producing a `Stream`) with
    `ByteArray.mk` (packing the `Stream = List UInt8` as a
    `ByteArray`). -/
def encodeAsBytes {T : Type} [Encodable T] (v : T) : ByteArray :=
  ByteArray.mk (Encodable.encode v).toArray

/-- The leaf hash for cell `(key, value)`: `hashBytes (encode
    key ++ encode value)`.  This is what `verifySmtCellProof`
    starts from. -/
def leafHash {K V : Type} [Encodable K] [Encodable V]
    (key : K) (value : V) : ByteArray :=
  hashBytes (encodeAsBytes key ++ encodeAsBytes value)

/-- The leaf hash is always exactly 32 bytes. -/
theorem leafHash_size {K V : Type} [Encodable K] [Encodable V]
    (key : K) (value : V) :
    (leafHash key value).size = 32 :=
  hashBytes_size _

/-! ## SMT step -/

/-- One step of the SMT walk: combine `current` (this-depth
    hash on our key's path) with `sibling` (the other-side
    hash at this depth) into the next-depth parent hash.

    * `bit = false` (key bit is 0 ⇒ we're on the left):
      `parent = hashBytes (current ++ sibling)`.
    * `bit = true`  (key bit is 1 ⇒ we're on the right):
      `parent = hashBytes (sibling ++ current)`. -/
def smtStep (current sibling : ByteArray) (bit : Bool) : ByteArray :=
  if bit then
    hashBytes (sibling ++ current)
  else
    hashBytes (current ++ sibling)

/-- `smtStep`'s output is always exactly 32 bytes. -/
theorem smtStep_size (current sibling : ByteArray) (bit : Bool) :
    (smtStep current sibling bit).size = 32 := by
  unfold smtStep
  cases bit <;> exact hashBytes_size _

/-! ## ByteArray append injectivity helper -/

/-- Byte-array append injectivity at a known left-size: if
    `a ++ b = c ++ d` and `a.size = c.size`, then `a = c` AND
    `b = d`.  Lifts `List.append_inj` via `.data.toList`. -/
theorem byteArray_append_inj_left
    (a b c d : ByteArray)
    (h : a ++ b = c ++ d)
    (hs : a.size = c.size) :
    a = c ∧ b = d := by
  have hlist : (a ++ b).data.toList = (c ++ d).data.toList := by rw [h]
  have hlist' :
      a.data.toList ++ b.data.toList = c.data.toList ++ d.data.toList := hlist
  have ha_size : a.data.toList.length = c.data.toList.length := by
    show a.size = c.size
    exact hs
  obtain ⟨h_a, h_b⟩ := List.append_inj hlist' ha_size
  refine ⟨?_, ?_⟩
  · cases a with
    | mk a' =>
      cases c with
      | mk c' =>
        show ByteArray.mk _ = ByteArray.mk _
        congr 1
        exact Array.toList_inj.mp h_a
  · cases b with
    | mk b' =>
      cases d with
      | mk d' =>
        show ByteArray.mk _ = ByteArray.mk _
        congr 1
        exact Array.toList_inj.mp h_b

/-! ## Step-injectivity under `CollisionFree` -/

/-- Backward-step injectivity: under `CollisionFree`, two SMT
    steps produce the same parent hash only if their current
    and sibling components agree pairwise. -/
theorem smtStep_inj_under_collision_free
    (h_cf : CollisionFree hashBytes)
    (c₁ c₂ s₁ s₂ : ByteArray)
    (h_c₁_size : c₁.size = 32) (h_c₂_size : c₂.size = 32)
    (h_s₁_size : s₁.size = 32) (h_s₂_size : s₂.size = 32)
    (bit : Bool)
    (h_step : smtStep c₁ s₁ bit = smtStep c₂ s₂ bit) :
    c₁ = c₂ ∧ s₁ = s₂ := by
  unfold smtStep at h_step
  cases bit with
  | false =>
    have h_pre : c₁ ++ s₁ = c₂ ++ s₂ := h_cf _ _ h_step
    have h_c_size : c₁.size = c₂.size := by rw [h_c₁_size, h_c₂_size]
    exact byteArray_append_inj_left c₁ s₁ c₂ s₂ h_pre h_c_size
  | true =>
    have h_pre : s₁ ++ c₁ = s₂ ++ c₂ := h_cf _ _ h_step
    have h_s_size : s₁.size = s₂.size := by rw [h_s₁_size, h_s₂_size]
    obtain ⟨h_s, h_c⟩ := byteArray_append_inj_left s₁ c₁ s₂ c₂ h_pre h_s_size
    exact ⟨h_c, h_s⟩

/-! ## SMT walk (list-based for clean inductive proofs) -/

/-- One step of the SMT walk, lifted to a `(sibling, bit)` pair
    so it can be plugged into `List.foldl`. -/
def stepPair (current : ByteArray) (sb : ByteArray × Bool) : ByteArray :=
  smtStep current sb.1 sb.2

/-- `stepPair` output is always exactly 32 bytes. -/
theorem stepPair_size (current : ByteArray) (sb : ByteArray × Bool) :
    (stepPair current sb).size = 32 :=
  smtStep_size _ _ _

/-- The 256-element bit sequence for `key`, MSB-first. -/
def keyBits {K : Type} [BitsKey K] (key : K) : List Bool :=
  (List.range smtDepth).map (BitsKey.keyBit key)

/-- The 256-element sibling sequence for a proof.  At depth `d`,
    consult the proof's bitmask; if set, draw from
    `proof.siblings[siblingsIdx]` (substituting `paddingHash`
    if out of range); otherwise use the canonical
    `emptySubtreeHash d`.

    The implementation walks 0..255 sequentially, maintaining a
    siblings-cursor that increments only on set bits.  Returns
    a list of length `n` from depth `d` advancing `idx` per set
    bit. -/
def expandSiblingsAux (proof : SmtCellProof) : Nat → Nat → Nat → List ByteArray
  | _d, _idx, 0     => []
  | d,  idx, n + 1 =>
    if proof.bitmaskBit d then
      (proof.siblings[idx]?.getD paddingHash) ::
        expandSiblingsAux proof (d + 1) (idx + 1) n
    else
      emptySubtreeHash d :: expandSiblingsAux proof (d + 1) idx n

/-- The 256-element expanded sibling sequence for a proof. -/
def expandSiblings (proof : SmtCellProof) : List ByteArray :=
  expandSiblingsAux proof 0 0 smtDepth

/-- The SMT walk: starting from the leaf hash, fold `stepPair`
    over the zipped `(sibling, bit)` sequence.  The final value
    is the reconstructed root candidate. -/
def smtWalk {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (key : K) (value : V) (proof : SmtCellProof) : ByteArray :=
  ((expandSiblings proof).zip (keyBits key)).foldl stepPair (leafHash key value)

/-! ## SMT root via list-of-pairs (SC.1.b reference)

The map-based SMT root is defined by recursion on depth: at the
root level (depth = `smtDepth`), partition the entries by their
top bit; recurse on each half at the next depth; hash the two
sub-tree roots.  An empty sub-tree's root is the canonical
`emptySubtreeHash`.

We work over `List (K × V)` (rather than `Std.TreeMap`) because
list-level case-analysis is cleaner for the inductive
definition.  `smtRoot` (the public entry) accepts a `Std.TreeMap`
and routes through `m.toList`. -/

/-- The reference SMT root function on a sorted list of
    `(key, value)` entries.  Recursive on a strictly-decreasing
    depth argument:
      * `depth = 0`: the bucket contains at most one entry
        (assuming distinct 256-bit keys); a single-entry bucket
        hashes as `leafHash`, an empty bucket as
        `emptySubtreeHash 0`, and any other (a "collision"
        bucket, which can only arise under a key-hash
        collision) hashes as `emptySubtreeHash 0` defensively.
      * `depth = d + 1`: partition by `BitsKey.keyBit k d`;
        recurse on each half at depth `d`; hash the two
        sub-roots in canonical (left, right) order.

    Termination is by structural recursion on `depth`.

    Empty-at-top-level handling: when depth = 256 and entries
    is empty, the result is `hashBytes (H_255 ++ H_255)` (the
    canonical "depth-256 empty sub-tree"), computed on the fly
    since `emptySubtreeHashes` only stores depths 0..255. -/
def smtRootListAux {K V : Type} [BitsKey K] [Encodable K] [Encodable V] :
    Nat → List (K × V) → ByteArray
  | 0, entries =>
    match entries with
    | [(k, v)] => leafHash k v
    | _        => emptySubtreeHash 0
  | d + 1, entries =>
    if entries.isEmpty then
      if d + 1 < 256 then
        emptySubtreeHash (d + 1)
      else
        -- d + 1 ≥ 256: compute the empty sub-tree root on the fly.
        hashBytes (emptySubtreeHash d ++ emptySubtreeHash d)
    else
      let leftEntries  := entries.filter (fun e => ! BitsKey.keyBit e.1 d)
      let rightEntries := entries.filter (fun e => BitsKey.keyBit e.1 d)
      hashBytes (smtRootListAux d leftEntries ++ smtRootListAux d rightEntries)

/-- The reference SMT root of a `Std.TreeMap`.  Routes through
    `m.toList` (which produces a list sorted by `compare`) and
    `smtRootListAux smtDepth`.

    The result depends on the linked `hashBytes` implementation;
    consumers should compute reference roots using the same
    implementation (the production keccak256 adaptor for L1
    deployments).

    SC.1.b — `docs/planning/smt_cell_proofs_plan.md` §SC.1.b. -/
def smtRoot {K V : Type} [Ord K] [BitsKey K] [Encodable K] [Encodable V]
    (m : Std.TreeMap K V compare) : ByteArray :=
  smtRootListAux smtDepth m.toList

/-! ### `smtRoot` output-shape lemmas

The SMT root is always a 32-byte hash — either a `hashBytes`
output or a canonical `emptySubtreeHash`. -/

/-- The list-based SMT root has size exactly 32 at any depth.

    Property: by exhaustive case analysis on the `depth = 0` vs
    `depth = d + 1` shapes, and within each, on the entries-list
    shape (empty / singleton / multi).  Every branch reduces to
    either `leafHash_size`, `emptySubtreeHash_size`, or
    `hashBytes_size`, each of which is 32 by construction.

    Holds unconditionally on `depth`: the depth = 256 case in
    `smtRootListAux` (the empty-at-top-level branch) computes
    `hashBytes(H_255 ++ H_255)` on the fly, which is still 32
    bytes by `hashBytes_size`. -/
theorem smtRootListAux_size {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (depth : Nat) (entries : List (K × V)) :
    (smtRootListAux depth entries).size = 32 := by
  induction depth generalizing entries with
  | zero =>
    unfold smtRootListAux
    match entries with
    | [(_, _)] =>
      simp
      exact leafHash_size _ _
    | [] =>
      simp
      exact emptySubtreeHash_size 0 (by decide)
    | (_ :: _ :: _) =>
      simp
      exact emptySubtreeHash_size 0 (by decide)
  | succ k _ih =>
    unfold smtRootListAux
    by_cases h_empty : entries.isEmpty
    · simp [h_empty]
      by_cases h_lt : k + 1 < 256
      · rw [if_pos h_lt]
        exact emptySubtreeHash_size (k + 1) h_lt
      · rw [if_neg h_lt]
        exact hashBytes_size _
    · simp [h_empty]
      exact hashBytes_size _

/-- The TreeMap-based SMT root has size exactly 32. -/
theorem smtRoot_size {K V : Type} [Ord K] [BitsKey K] [Encodable K] [Encodable V]
    (m : Std.TreeMap K V compare) :
    (smtRoot m).size = 32 := by
  unfold smtRoot
  exact smtRootListAux_size smtDepth m.toList

/-! ## Canonical proof construction (SC.1.b helper)

For test fixtures and reference implementations, we provide a
`buildSmtCellProof` function that constructs the canonical
SMT proof for a key in a given list of entries.

The canonical proof for `(entries, key)` has:
  * `siblings`: the non-canonical-empty sibling-subtree roots
    along the path from leaf to root, in **low-depth-first**
    order (depth 0 first).
  * `bitmask`: 32-byte mask with bit `d` set iff the sibling at
    depth `d` is non-canonical-empty.

This function is used by tests to validate the verifier's
behaviour on multi-cell maps; it is NOT load-bearing for the
soundness theorem (which works directly on the walk
representation). -/

/-- Set bit `d` (low-first within each byte, byte-low-first
    across bytes) of a 32-byte bitmask, returning the modified
    bitmask.  Used by `buildSmtCellProof` to mark the depths
    where the canonical sibling is non-canonical-empty.

    Out-of-range `d` (≥ `bitmask.size * 8`) returns the bitmask
    unchanged. -/
def setBitmaskBit (bitmask : ByteArray) (d : Nat) : ByteArray :=
  let byteIdx := d / 8
  if h : byteIdx < bitmask.size then
    let byte := bitmask[byteIdx]'h
    let newByte := UInt8.ofNat (byte.toNat ||| (1 <<< (d % 8)))
    bitmask.set byteIdx newByte h
  else
    bitmask

/-- Walk the entry list from the root down to the leaf for `key`,
    collecting non-canonical-empty siblings along the way.

    Given:
      * `entries`: the entries at the current depth's bucket.
      * `d`: remaining depth (counts DOWN from `smtDepth`).
      * `key`: the key we're building a proof for.

    Returns `(siblings, bitmaskDepths)` where:
      * `siblings` are the non-canonical siblings in **low-depth-
        first** order (depth-0's sibling first, matching the
        expander's consumption order).  The sibling at the
        smallest set bitmask bit comes first.
      * `bitmaskDepths` lists the SMT depths where the
        corresponding sibling is non-canonical-empty (used by
        `buildSmtCellProof` to flip the appropriate bitmask bits).

    The recursion descends from the root to the leaf.  The
    recursive sub-call (`buildSmtCellProofAux d ourHalf key`)
    returns siblings for depths `0..d-1` in low-depth-first
    order.  At depth `d`, we APPEND our sibling (if
    non-canonical) so the overall order remains low-first. -/
def buildSmtCellProofAux {K V : Type} [BitsKey K] [Encodable K] [Encodable V] :
    Nat → List (K × V) → K → List ByteArray × List Nat
  | 0, _entries, _key => ([], [])
  | d + 1, entries, key =>
    let leftEntries  := entries.filter (fun e => ! BitsKey.keyBit e.1 d)
    let rightEntries := entries.filter (fun e => BitsKey.keyBit e.1 d)
    let bit          := BitsKey.keyBit key d
    -- Our half: where `key` lives.  Their half: the sibling sub-tree.
    let theirHalf    := if bit then leftEntries else rightEntries
    let ourHalf      := if bit then rightEntries else leftEntries
    let theirRoot    := smtRootListAux d theirHalf
    let isKnomosisEmpty := theirRoot == emptySubtreeHash d
    -- Recurse on our half at depth d.  childSibs / childBits cover
    -- depths 0..d-1 in LOW-depth-first order.
    let (childSibs, childBits) := buildSmtCellProofAux d ourHalf key
    -- The sibling at depth d goes AT THE END of the list (so the
    -- list stays low-first overall).  If it's canonical-empty,
    -- omit; otherwise append.
    if isKnomosisEmpty then
      (childSibs, childBits)
    else
      (childSibs ++ [theirRoot], childBits ++ [d])

/-- Build the canonical SMT cell proof for `key` in `m`.

    The proof's `siblings` array contains the non-canonical-empty
    sibling-subtree roots along the path from leaf to root, in
    low-depth-first order.  The `bitmask` is a 32-byte ByteArray
    whose bit `d` is set iff the canonical sibling at depth `d`
    is non-canonical-empty.

    Operational coherence (`smtRoot m = smtWalk key v
    (buildSmtCellProof m key)` for `m[key]? = some v`) is
    validated by per-fixture tests in
    `LegalKernel/Test/FaultProof/Smt.lean` across empty,
    singleton, two-cell, three-cell, and four-cell maps.  The
    soundness theorem (`smtCellProof_no_value_substitution`) is
    independent of this constructor — it holds for ANY pair of
    verifying proofs regardless of how they were built. -/
def buildSmtCellProof {K V : Type} [Ord K] [BitsKey K] [Encodable K] [Encodable V]
    (m : Std.TreeMap K V compare) (key : K) : SmtCellProof :=
  let entries := m.toList
  let (sibs, bitDepths) := buildSmtCellProofAux smtDepth entries key
  let emptyBitmask : ByteArray := ByteArray.mk (Array.replicate 32 (0 : UInt8))
  let bitmask := bitDepths.foldl setBitmaskBit emptyBitmask
  { siblings := sibs.toArray, bitmask := bitmask }

/-! ## `verifySmtCellProof` (SC.1.c) -/

/-- Verify an SMT cell proof against `(root, key, value)`.
    Returns `true` iff:
      1. The proof is well-formed (every sibling is 32 bytes,
         bitmask is 32 bytes).
      2. The reconstructed `smtWalk key value proof` equals
         `root`. -/
def verifySmtCellProof {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (root : ByteArray) (key : K) (value : V) (proof : SmtCellProof) :
    Bool :=
  proof.isWellFormed && decide (smtWalk key value proof = root)

/-- Determinism: equal inputs to `verifySmtCellProof` yield
    equal verdicts. -/
theorem verifySmtCellProof_deterministic
    {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (r₁ r₂ : ByteArray) (k₁ k₂ : K) (v₁ v₂ : V) (p₁ p₂ : SmtCellProof)
    (h_r : r₁ = r₂) (h_k : k₁ = k₂) (h_v : v₁ = v₂) (h_p : p₁ = p₂) :
    verifySmtCellProof r₁ k₁ v₁ p₁ = verifySmtCellProof r₂ k₂ v₂ p₂ := by
  rw [h_r, h_k, h_v, h_p]

/-! ## Completeness

The verifier is *complete*: every well-formed proof verifies
against its own walked root.  This is the lower bound on
"canonical proofs work"; the soundness theorem
(`smtCellProof_no_value_substitution`) is the upper bound on
"no two valid proofs disagree on the value". -/

/-- Completeness: any well-formed proof verifies against the
    root computed by `smtWalk` for the same `(key, value)`.
    The empty proof in particular verifies against any state
    that has only this cell set (a singleton SMT). -/
theorem verifySmtCellProof_walks_to_root
    {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (key : K) (value : V) (proof : SmtCellProof)
    (h_wf : proof.isWellFormed = true) :
    verifySmtCellProof (smtWalk key value proof) key value proof = true := by
  unfold verifySmtCellProof
  rw [Bool.and_eq_true]
  refine ⟨h_wf, ?_⟩
  exact decide_eq_true rfl

/-- The empty proof is well-formed.  Empty siblings array
    trivially satisfies the per-sibling size constraint; the
    bitmask is a 32-byte all-zero array. -/
theorem SmtCellProof.empty_isWellFormed :
    SmtCellProof.empty.isWellFormed = true := by
  unfold SmtCellProof.isWellFormed SmtCellProof.empty
  -- bitmask.size = 32 (by construction): the bitmask is a 32-byte
  -- ByteArray made from Array.replicate 32 0.
  have h_bm : (ByteArray.mk (Array.replicate 32 (0 : UInt8))).size = 32 := by
    show (Array.replicate 32 (0 : UInt8)).size = 32
    simp [Array.size_replicate]
  -- The `siblings.all` on the empty array is trivially true,
  -- and the bitmask size check passes by `h_bm`.
  simp [h_bm, Array.all]

/-- Specialisation: the empty proof self-verifies against its
    walked root, regardless of key and value.  This is the
    "all-empty-siblings singleton SMT" case. -/
theorem verifySmtCellProof_empty_self_verifies
    {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (key : K) (value : V) :
    verifySmtCellProof
      (smtWalk key value SmtCellProof.empty)
      key value SmtCellProof.empty = true := by
  apply verifySmtCellProof_walks_to_root
  exact SmtCellProof.empty_isWellFormed

/-! ## Expanded-siblings all-32-bytes property

Under well-formedness (every entry of `proof.siblings` is 32
bytes), every entry of `expandSiblings proof` is 32 bytes — by
case analysis on the bitmask bit at each depth:

  * Set bit: returns a proof-supplied sibling (32 bytes by
    well-formedness) OR the padding hash (32 bytes by
    `paddingHash_size`).
  * Unset bit: returns `emptySubtreeHash d` (32 bytes by
    `emptySubtreeHash_size` for `d < 256`).

The depth bound `d < 256` is automatically satisfied during
the canonical-entry walk (`d` ranges over `[0, 256)`). -/

/-- For any (d, idx, n) with `d + n ≤ 256`, every entry of
    `expandSiblingsAux proof d idx n` has size 32, provided
    every entry of `proof.siblings` has size 32. -/
theorem expandSiblingsAux_all_32
    (proof : SmtCellProof)
    (h_sibs : ∀ s ∈ proof.siblings, s.size = 32) :
    ∀ (d idx n : Nat), d + n ≤ 256 →
      ∀ s ∈ expandSiblingsAux proof d idx n, s.size = 32 := by
  intro d idx n hdn
  induction n generalizing d idx with
  | zero =>
    intro s hs
    unfold expandSiblingsAux at hs
    exact (List.not_mem_nil hs).elim
  | succ k ih =>
    intro s hs
    unfold expandSiblingsAux at hs
    by_cases h_bit : proof.bitmaskBit d
    · rw [if_pos h_bit] at hs
      rcases List.mem_cons.mp hs with hs_head | hs_tail
      · -- s = proof.siblings[idx]?.getD paddingHash
        rw [hs_head]
        by_cases h_idx : idx < proof.siblings.size
        · rw [Array.getElem?_eq_getElem h_idx]
          show (proof.siblings[idx]'h_idx).size = 32
          exact h_sibs _ (Array.getElem_mem _)
        · -- idx out of range: falls back to paddingHash (size 32).
          rw [show proof.siblings[idx]? = none from
                Array.getElem?_eq_none (Nat.le_of_not_lt h_idx)]
          show (Option.getD none paddingHash).size = 32
          exact paddingHash_size
      · -- s ∈ expandSiblingsAux ... (k more steps)
        exact ih (d + 1) (idx + 1) (by omega) s hs_tail
    · rw [if_neg h_bit] at hs
      rcases List.mem_cons.mp hs with hs_head | hs_tail
      · -- s = emptySubtreeHash d
        rw [hs_head]
        apply emptySubtreeHash_size
        omega
      · exact ih (d + 1) idx (by omega) s hs_tail

/-- For a well-formed proof, every entry of `expandSiblings
    proof` is 32 bytes.  Directly from `expandSiblingsAux_all_32`
    at the canonical entry (d=0, idx=0, n=smtDepth=256). -/
theorem expandSiblings_all_32
    (proof : SmtCellProof) (h_wf : proof.isWellFormed = true) :
    ∀ s ∈ expandSiblings proof, s.size = 32 := by
  have h_sibs : ∀ s ∈ proof.siblings, s.size = 32 :=
    SmtCellProof.isWellFormed_implies_all_siblings_32 proof h_wf
  apply expandSiblingsAux_all_32 proof h_sibs 0 0 smtDepth
  show 0 + smtDepth ≤ 256
  unfold smtDepth
  omega

/-- Length of `expandSiblingsAux proof d idx n` is exactly `n`. -/
theorem expandSiblingsAux_length (proof : SmtCellProof) :
    ∀ (d idx n : Nat), (expandSiblingsAux proof d idx n).length = n := by
  intro d idx n
  induction n generalizing d idx with
  | zero => unfold expandSiblingsAux; rfl
  | succ k ih =>
    unfold expandSiblingsAux
    by_cases h_bit : proof.bitmaskBit d
    · rw [if_pos h_bit]
      simp [List.length_cons, ih]
    · rw [if_neg h_bit]
      simp [List.length_cons, ih]

/-- Length of `expandSiblings proof` is exactly `smtDepth = 256`. -/
theorem expandSiblings_length (proof : SmtCellProof) :
    (expandSiblings proof).length = smtDepth :=
  expandSiblingsAux_length proof 0 0 smtDepth

/-- Length of `keyBits key` is exactly `smtDepth = 256`. -/
theorem keyBits_length {K : Type} [BitsKey K] (key : K) :
    (keyBits key).length = smtDepth := by
  unfold keyBits
  rw [List.length_map, List.length_range]

/-! ## Walk injectivity in the leaf -/

/-- Walk-leaf injectivity: under `CollisionFree`, two folds of
    `stepPair` ending at the same value must coincide on the
    starting leaf, provided:
      * the two pair-lists have the same length,
      * the corresponding bits match,
      * the starting leaves are 32 bytes,
      * every sibling in both lists is 32 bytes.

    The siblings themselves may differ between the two walks;
    the conclusion is about the starting leaf alone. -/
theorem walk_leaf_inj_under_collision_free
    (h_cf : CollisionFree hashBytes) :
    ∀ (bits : List Bool) (sibs₁ sibs₂ : List ByteArray)
      (leaf₁ leaf₂ : ByteArray),
      sibs₁.length = bits.length →
      sibs₂.length = bits.length →
      leaf₁.size = 32 →
      leaf₂.size = 32 →
      (∀ s ∈ sibs₁, s.size = 32) →
      (∀ s ∈ sibs₂, s.size = 32) →
      (sibs₁.zip bits).foldl stepPair leaf₁ =
      (sibs₂.zip bits).foldl stepPair leaf₂ →
      leaf₁ = leaf₂ := by
  intro bits
  induction bits with
  | nil =>
    intro sibs₁ sibs₂ leaf₁ leaf₂
      h_len₁ h_len₂ _ _ _ _ h_walk_eq
    have hsibs₁ : sibs₁ = [] := List.eq_nil_of_length_eq_zero h_len₁
    have hsibs₂ : sibs₂ = [] := List.eq_nil_of_length_eq_zero h_len₂
    subst hsibs₁ hsibs₂
    simpa using h_walk_eq
  | cons b rest_bits ih =>
    intro sibs₁ sibs₂ leaf₁ leaf₂
      h_len₁ h_len₂ h_leaf₁_size h_leaf₂_size
      h_sibs₁_32 h_sibs₂_32 h_walk_eq
    -- sibs₁ and sibs₂ each have a head element.
    cases sibs₁ with
    | nil => simp at h_len₁
    | cons s₁ rest_sibs₁ =>
      cases sibs₂ with
      | nil => simp at h_len₂
      | cons s₂ rest_sibs₂ =>
        -- One fold step on each side.
        have h_unfold₁ :
            ((s₁ :: rest_sibs₁).zip (b :: rest_bits)).foldl stepPair leaf₁ =
            (rest_sibs₁.zip rest_bits).foldl stepPair (stepPair leaf₁ (s₁, b)) := by
          simp [List.zip_cons_cons, List.foldl_cons]
        have h_unfold₂ :
            ((s₂ :: rest_sibs₂).zip (b :: rest_bits)).foldl stepPair leaf₂ =
            (rest_sibs₂.zip rest_bits).foldl stepPair (stepPair leaf₂ (s₂, b)) := by
          simp [List.zip_cons_cons, List.foldl_cons]
        rw [h_unfold₁, h_unfold₂] at h_walk_eq
        have h_step_size₁ : (stepPair leaf₁ (s₁, b)).size = 32 := stepPair_size _ _
        have h_step_size₂ : (stepPair leaf₂ (s₂, b)).size = 32 := stepPair_size _ _
        have h_rest_sibs₁_32 : ∀ s ∈ rest_sibs₁, s.size = 32 := by
          intro s hs
          exact h_sibs₁_32 s (List.mem_cons_of_mem _ hs)
        have h_rest_sibs₂_32 : ∀ s ∈ rest_sibs₂, s.size = 32 := by
          intro s hs
          exact h_sibs₂_32 s (List.mem_cons_of_mem _ hs)
        have h_len_rest₁ : rest_sibs₁.length = rest_bits.length := by
          simp [List.length_cons] at h_len₁; exact h_len₁
        have h_len_rest₂ : rest_sibs₂.length = rest_bits.length := by
          simp [List.length_cons] at h_len₂; exact h_len₂
        have h_step_eq : stepPair leaf₁ (s₁, b) = stepPair leaf₂ (s₂, b) :=
          ih rest_sibs₁ rest_sibs₂ (stepPair leaf₁ (s₁, b)) (stepPair leaf₂ (s₂, b))
            h_len_rest₁ h_len_rest₂ h_step_size₁ h_step_size₂
            h_rest_sibs₁_32 h_rest_sibs₂_32 h_walk_eq
        -- One-step injectivity: extract leaf₁ = leaf₂ from step equality.
        have h_s₁_32 : s₁.size = 32 := h_sibs₁_32 s₁ List.mem_cons_self
        have h_s₂_32 : s₂.size = 32 := h_sibs₂_32 s₂ List.mem_cons_self
        unfold stepPair at h_step_eq
        have ⟨h_leaf_eq, _⟩ :=
          smtStep_inj_under_collision_free h_cf
            leaf₁ leaf₂ s₁ s₂
            h_leaf₁_size h_leaf₂_size h_s₁_32 h_s₂_32
            b h_step_eq
        exact h_leaf_eq

/-! ## Top-level soundness (SC.1.d / SC.1.e) -/

/-- Soundness (uniqueness form): under `CollisionFree hashBytes`
    and value-encoder injectivity, the verifier accepts at most
    one value per `(root, key)`.  Two verifying proofs for the
    same root and key must claim the same value.

    This is the load-bearing operational property: an
    adversarial responder cannot use a forged SMT proof to
    substitute a wrong cell value.

    SC.1.e — `docs/planning/smt_cell_proofs_plan.md` §SC.1.e. -/
theorem smtCellProof_no_value_substitution
    {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (hVInj : Function.Injective (Encodable.encode : V → Stream))
    (h_cf : CollisionFree hashBytes)
    (root : ByteArray) (key : K) (v₁ v₂ : V)
    (proof₁ proof₂ : SmtCellProof)
    (h_verify₁ : verifySmtCellProof root key v₁ proof₁ = true)
    (h_verify₂ : verifySmtCellProof root key v₂ proof₂ = true) :
    v₁ = v₂ := by
  -- Unpack the verifier: well-formedness + walk-matches-root.
  unfold verifySmtCellProof at h_verify₁ h_verify₂
  rw [Bool.and_eq_true] at h_verify₁ h_verify₂
  obtain ⟨h_wf₁, h_walk₁⟩ := h_verify₁
  obtain ⟨h_wf₂, h_walk₂⟩ := h_verify₂
  have h_walk_eq₁ : smtWalk key v₁ proof₁ = root := decide_eq_true_eq.mp h_walk₁
  have h_walk_eq₂ : smtWalk key v₂ proof₂ = root := decide_eq_true_eq.mp h_walk₂
  -- Step 1: leafHash key v₁ = leafHash key v₂ via walk injectivity.
  have h_walks_agree :
      ((expandSiblings proof₁).zip (keyBits key)).foldl stepPair (leafHash key v₁) =
      ((expandSiblings proof₂).zip (keyBits key)).foldl stepPair (leafHash key v₂) := by
    show smtWalk key v₁ proof₁ = smtWalk key v₂ proof₂
    rw [h_walk_eq₁, h_walk_eq₂]
  have h_leaf_size₁ : (leafHash key v₁).size = 32 := leafHash_size _ _
  have h_leaf_size₂ : (leafHash key v₂).size = 32 := leafHash_size _ _
  have h_exp_len₁ : (expandSiblings proof₁).length = (keyBits key).length := by
    rw [expandSiblings_length, keyBits_length]
  have h_exp_len₂ : (expandSiblings proof₂).length = (keyBits key).length := by
    rw [expandSiblings_length, keyBits_length]
  have h_exp_sizes₁ : ∀ s ∈ expandSiblings proof₁, s.size = 32 :=
    expandSiblings_all_32 proof₁ h_wf₁
  have h_exp_sizes₂ : ∀ s ∈ expandSiblings proof₂, s.size = 32 :=
    expandSiblings_all_32 proof₂ h_wf₂
  have h_leaf_eq : leafHash key v₁ = leafHash key v₂ :=
    walk_leaf_inj_under_collision_free h_cf
      (keyBits key) (expandSiblings proof₁) (expandSiblings proof₂)
      (leafHash key v₁) (leafHash key v₂)
      h_exp_len₁ h_exp_len₂
      h_leaf_size₁ h_leaf_size₂
      h_exp_sizes₁ h_exp_sizes₂
      h_walks_agree
  -- Step 2: leaf eq ⇒ value eq via CR + encoder injectivity.
  unfold leafHash at h_leaf_eq
  have h_bytes_eq : encodeAsBytes key ++ encodeAsBytes v₁ =
                   encodeAsBytes key ++ encodeAsBytes v₂ :=
    h_cf _ _ h_leaf_eq
  have h_key_size : (encodeAsBytes key).size = (encodeAsBytes key).size := rfl
  obtain ⟨_, h_value_bytes_eq⟩ :=
    byteArray_append_inj_left (encodeAsBytes key) (encodeAsBytes v₁)
      (encodeAsBytes key) (encodeAsBytes v₂) h_bytes_eq h_key_size
  unfold encodeAsBytes at h_value_bytes_eq
  have h_streams_eq : (Encodable.encode v₁ : Stream) = Encodable.encode v₂ := by
    have h_arr_eq : (Encodable.encode v₁).toArray = (Encodable.encode v₂).toArray := by
      injection h_value_bytes_eq
    have h_list_eq : (Encodable.encode v₁).toArray.toList =
                     (Encodable.encode v₂).toArray.toList := by
      rw [h_arr_eq]
    rw [List.toList_toArray, List.toList_toArray] at h_list_eq
    exact h_list_eq
  exact hVInj h_streams_eq

/-- Soundness (alias for `smtCellProof_no_value_substitution`,
    matching the SC.1 plan's naming).

    SC.1.d — `docs/planning/smt_cell_proofs_plan.md` §SC.1.d. -/
theorem smtCellProof_sound_under_collision_free
    {K V : Type} [BitsKey K] [Encodable K] [Encodable V]
    (hVInj : Function.Injective (Encodable.encode : V → Stream))
    (h_cf : CollisionFree hashBytes)
    (root : ByteArray) (key : K) (v₁ v₂ : V)
    (proof₁ proof₂ : SmtCellProof)
    (h_verify₁ : verifySmtCellProof root key v₁ proof₁ = true)
    (h_verify₂ : verifySmtCellProof root key v₂ proof₂ = true) :
    v₁ = v₂ :=
  smtCellProof_no_value_substitution hVInj h_cf root key v₁ v₂
    proof₁ proof₂ h_verify₁ h_verify₂

end FaultProof
end LegalKernel

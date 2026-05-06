/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.WithdrawalRoot — Workstream D.1
(`docs/ethereum_integration_plan.md` §8.1).

The sparse Merkle tree (SMT) over `BridgeState.pending`.  The root
of this tree is the on-L2 commitment that `CanonBridge.sol`
consumes when redeeming a withdrawal: the user presents a
`WithdrawalProof` (leaf bytes + sibling path) which the L1
verifier hashes against the submitted root.

Coverage (per the integration plan):

  * D.1.1 — SMT data structures and tree construction
    (`smtHeight`, `emptyLeafHash`, `defaultHash`, `withdrawalRoot`,
    plus `defaultHash_well_defined`,
    `withdrawalRoot_empty_eq_defaultHash_top`,
    `withdrawalRoot_extensional`).
  * D.1.2 — verifier and constructor definitions (`WithdrawalProof`,
    `verifyProof`, `constructProof`, plus
    `constructProof_deterministic`, `constructProof_siblings_length`,
    `verifyProof_total`).
  * D.1.3 — `verifyProof_complete` (unconditional — completeness is
    a structural recursion identity).
  * D.1.4 — `verifyProof_sound` (hash-conditional — soundness rests
    on `CollisionFree H`, a `Prop` parameter that production
    deployments discharge by linking the keccak256 binding).

The hash function is parameterised (`H : ByteArray → ByteArray`) so
the theorems can be stated under abstract collision-resistance
hypotheses.  The `withdrawalRoot` operating on real bridge state
uses `Runtime.Hash.hashBytes` (the keccak256 swap-point); tests can
substitute toy hash functions to exercise the constructions
deterministically.

## Conventions

  * **Tree height = 64.**  Matches `WithdrawalId : Nat` with the
    practical encoding bound `< 2^64` from §8.8.5.
  * **Empty leaf sentinel.**  `emptyLeafHash := zeroHash` (32 zero
    bytes) — the Audit-3.1 zero-hash convention.
  * **Bit indexing.**  We use the **LSB-up** convention:
    `pathBitAtLevel idx level := (idx >>> level) &&& 1 = 1`.  Bit
    0 (LSB) = level 0 (the deepest decision, just above the leaf
    cell); bit 63 (MSB) = level 63 (the root's two children).
  * **Sibling order.**  `siblings[0]` is **root-adjacent**;
    `siblings[smtHeight - 1]` is **leaf-adjacent**.

## WithdrawalId bound (deployment correctness obligation)

The SMT only consults `smtHeight = 64` bits of each WithdrawalId.
Two WithdrawalIds whose low 64 bits agree map to the same SMT
position.  Within the < 2^64 bound (which the runtime adaptor's
`UInt64`-typed `nextWdId` counter enforces in practice), each
WithdrawalId maps to a unique leaf position.

Outside the bound (i.e., if a deployment manually constructs a
`PendingWithdrawal` with an id ≥ 2^64), aliasing can occur:
distinct ids that share their low 64 bits collide on the SMT
position.  The kernel-level theorems in this module state the
claims at the ByteArray level (e.g. `proof.leaf` matches
canonical), so the aliasing affects which WithdrawalId is
'pointed at' by a verifying proof, not whether the proof itself
verifies.

The runtime adaptor must enforce the < 2^64 bound at the bridge
boundary (typically by typing `nextWdId` as `UInt64` rather than
`Nat`).  This module's Lean type signature uses `Nat` for
arithmetic flexibility but does not attempt to enforce the
boundedness.  Workstream-D audit-2 (this branch) documents this
as a deployment-correctness obligation.

## Proof strategy

Both `verifyProof` and `constructProof` are defined via parallel
recursive descents that mirror `rangeRoot`'s recursion exactly.
This makes the §8.1.3 completeness theorem a one-line induction
on the recursion depth: at each level, `verifyProof` recomputes
exactly what `rangeRoot` would compute (because both hash the same
left/right subtree pairs).  Soundness (§8.1.4) follows from
verifier-injectivity under collision-freeness: the verifier's
recomputed root is determined entirely by `(proof.leaf,
proof.siblings)`, so under CR plus size constraints, two distinct
proofs cannot produce the same root.

This module is **not** part of the trusted computing base.  The
soundness theorem `verifyProof_sound` rests on `CollisionFree`,
`UniformOutputSize`, and an explicit leaf-size hypothesis;
production deployments discharge these by linking the keccak256
binding plus the runtime adaptor's leaf-canonicalisation
discipline.
-/

import LegalKernel.Bridge.State
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Bridge.Eip712
import LegalKernel.Encoding.State

namespace LegalKernel
namespace Bridge

open Std
open LegalKernel.Encoding
open LegalKernel.Runtime

/-! ## §8.1.1 — SMT shape constants -/

/-- The fixed height of the withdrawal SMT.  Matches the practical
    `WithdrawalId : Nat` encoding bound (`< 2^64`). -/
def smtHeight : Nat := 64

/-- The empty-leaf sentinel: a 32-byte all-zero `ByteArray`
    (Audit-3.1 zero-hash convention). -/
def emptyLeafHash : ByteArray := zeroHash

/-- `emptyLeafHash` is exactly 32 bytes. -/
theorem emptyLeafHash_size : emptyLeafHash.size = 32 := zeroHash_size

/-! ## defaultHash: precomputed empty-subtree hashes -/

/-- `defaultHash H i` = the hash of an all-empty subtree of height
    `i`.  Computed bottom-up: level-0 is the leaf sentinel; each
    higher level concatenates the previous level's hash with itself
    before hashing. -/
def defaultHash (H : ByteArray → ByteArray) : Nat → ByteArray
  | 0      => emptyLeafHash
  | i + 1  =>
    let prev := defaultHash H i
    H (prev ++ prev)

/-- `defaultHash` is total over `Nat`. -/
theorem defaultHash_well_defined (H : ByteArray → ByteArray) (i : Nat) :
    ∃ b : ByteArray, defaultHash H i = b :=
  ⟨defaultHash H i, rfl⟩

/-- `defaultHash H 0` is the `emptyLeafHash` sentinel. -/
theorem defaultHash_zero (H : ByteArray → ByteArray) :
    defaultHash H 0 = emptyLeafHash := rfl

/-- `defaultHash H (i+1)` is `H` of two concatenated copies. -/
theorem defaultHash_succ (H : ByteArray → ByteArray) (i : Nat) :
    defaultHash H (i + 1) = H (defaultHash H i ++ defaultHash H i) := rfl

/-! ## Path-bit extraction (LSB-up) -/

/-- The bit of `idx` consulted at level `level` (LSB-up). -/
def pathBitAtLevel (idx : WithdrawalId) (level : Nat) : Bool :=
  ((idx >>> level) &&& 1) = 1

/-! ## Per-level hash combinator -/

/-- Combine `current` with `sibling` under `H`, ordering by
    `right?`. -/
def hashUp (H : ByteArray → ByteArray)
    (right? : Bool) (current : ByteArray) (sibling : ByteArray) :
    ByteArray :=
  if right? then
    H (sibling ++ current)
  else
    H (current ++ sibling)

/-! ## leafBytes: the canonical leaf encoding -/

/-- The leaf bytes of a single populated cell — the canonical CBE
    encoding of the `PendingWithdrawal`. -/
def leafBytes (wd : PendingWithdrawal) : ByteArray :=
  ByteArray.mk (Bridge.PendingWithdrawal.encode wd).toArray

/-! ## rangeRoot: the recursive SMT root -/

/-- The recursive SMT root.

    Performance note: short-circuits on empty entries (returning
    `defaultHash H level` directly) so empty subtrees terminate
    in O(1) per level rather than O(2^level).  This is essential
    for `smtHeight = 64`: without the short-circuit, computing the
    root of a sparse tree with N populated entries would do
    `2^64 - O(N)` recursive calls on empty subtrees.  With the
    short-circuit, the work is `O(N * smtHeight)`. -/
def rangeRoot (H : ByteArray → ByteArray)
    (level : Nat) (entries : List (WithdrawalId × PendingWithdrawal)) :
    ByteArray :=
  match entries, level with
  | [],         _     => defaultHash H level
  | (_, wd) :: _,  0  => leafBytes wd
  | _ :: _,    k + 1  =>
    let leftEntries  := entries.filter
      (fun p => pathBitAtLevel p.1 k = false)
    let rightEntries := entries.filter
      (fun p => pathBitAtLevel p.1 k = true)
    let leftHash  := rangeRoot H k leftEntries
    let rightHash := rangeRoot H k rightEntries
    H (leftHash ++ rightHash)

/-- The withdrawal SMT root over `BridgeState.pending`. -/
def withdrawalRoot (H : ByteArray → ByteArray) (b : BridgeState) :
    ByteArray :=
  rangeRoot H smtHeight b.pending.toList

/-! ## §8.1.1 theorems -/

/-- Empty-list `rangeRoot` collapses to the level's `defaultHash`.
    With the short-circuit fix, this is now just `rfl`. -/
theorem rangeRoot_nil_eq_defaultHash
    (H : ByteArray → ByteArray) (level : Nat) :
    rangeRoot H level [] = defaultHash H level := by
  induction level <;> rfl

/-- Non-empty `rangeRoot` at successor level unfolds to the H form. -/
theorem rangeRoot_succ_cons
    (H : ByteArray → ByteArray) (k : Nat)
    (p : WithdrawalId × PendingWithdrawal)
    (rest : List (WithdrawalId × PendingWithdrawal)) :
    rangeRoot H (k + 1) (p :: rest) =
      H (rangeRoot H k ((p :: rest).filter
                        (fun q => pathBitAtLevel q.1 k = false)) ++
         rangeRoot H k ((p :: rest).filter
                        (fun q => pathBitAtLevel q.1 k = true))) := by
  rfl

/-- §8.1.1: empty `BridgeState.pending` produces `defaultHash smtHeight`. -/
theorem withdrawalRoot_empty_eq_defaultHash_top
    (H : ByteArray → ByteArray) :
    withdrawalRoot H BridgeState.empty = defaultHash H smtHeight := by
  unfold withdrawalRoot
  show rangeRoot H smtHeight (BridgeState.empty.pending : TreeMap WithdrawalId PendingWithdrawal compare).toList
       = defaultHash H smtHeight
  have hempty :
      ((BridgeState.empty.pending : TreeMap WithdrawalId PendingWithdrawal compare).toList).isEmpty
        = true := by
    show ((∅ : TreeMap WithdrawalId PendingWithdrawal compare).toList).isEmpty = true
    rw [TreeMap.isEmpty_toList]; exact TreeMap.isEmpty_emptyc
  have hnil :
      (BridgeState.empty.pending : TreeMap WithdrawalId PendingWithdrawal compare).toList = [] :=
    List.isEmpty_iff.mp hempty
  rw [hnil]
  exact rangeRoot_nil_eq_defaultHash H smtHeight

/-- §8.1.1: `withdrawalRoot` is extensional in `pending.toList`. -/
theorem withdrawalRoot_extensional
    (H : ByteArray → ByteArray) (b₁ b₂ : BridgeState)
    (h : b₁.pending.toList = b₂.pending.toList) :
    withdrawalRoot H b₁ = withdrawalRoot H b₂ := by
  unfold withdrawalRoot
  rw [h]

/-! ## §8.1.2 — `WithdrawalProof`, `verifyProof`, `constructProof` -/

/-- A Merkle inclusion proof for a single position in the
    withdrawal SMT. -/
structure WithdrawalProof where
  /-- The leaf bytes at the proof's position. -/
  leaf     : ByteArray
  /-- The withdrawal id this proof is about. -/
  index    : WithdrawalId
  /-- Exactly `smtHeight` sibling hashes, ordered root-to-leaf. -/
  siblings : Vector ByteArray smtHeight
  deriving Repr, DecidableEq

/-! ### verifyProof: recursive descent -/

/-- The recursive verifier.  Walks siblings root-to-leaf, composing
    hashUp at each level. -/
def verifyProofRec (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (leaf : ByteArray) (siblings : List ByteArray) (level : Nat) :
    ByteArray :=
  match level, siblings with
  | 0, _      => leaf
  | _ + 1, [] => leaf
  | k + 1, s :: rest =>
    let inner := verifyProofRec H idx leaf rest k
    let bit := pathBitAtLevel idx k
    hashUp H bit inner s

/-- Verify a withdrawal proof against a stated SMT root.

    Uses `ByteArray`'s decidable equality for the comparison.
    Returns `true` iff the recomputed root matches `root`
    byte-for-byte. -/
def verifyProof (H : ByteArray → ByteArray) (proof : WithdrawalProof)
    (root : ByteArray) : Bool :=
  let final := verifyProofRec H proof.index proof.leaf proof.siblings.toList smtHeight
  decide (final = root)

/-! ### constructProof: recursive descent -/

/-- The "all empty" canonical proof: leaf = sentinel, siblings are
    [defaultHash H (level - 1), defaultHash H (level - 2), ...,
    defaultHash H 0] (root-to-leaf order, length = `level`).

    Used as the short-circuit case for `constructProofAux` on an
    empty `entries` list: the canonical proof for any idx in an
    empty subtree consists of empty-subtree hashes at every level. -/
def emptyProofSiblings (H : ByteArray → ByteArray) (level : Nat) :
    List ByteArray :=
  match level with
  | 0     => []
  | k + 1 => defaultHash H k :: emptyProofSiblings H k

/-- `emptyProofSiblings` length equals `level`. -/
theorem emptyProofSiblings_length
    (H : ByteArray → ByteArray) (level : Nat) :
    (emptyProofSiblings H level).length = level := by
  induction level with
  | zero => rfl
  | succ k ih =>
    show (defaultHash H k :: emptyProofSiblings H k).length = k + 1
    rw [List.length_cons, ih]

/-- Recursive descent helper for `constructProof`.

    Performance: short-circuits on empty entries to avoid the
    O(2^level) blow-up that would otherwise occur from filtering
    and recursing on empty lists.  For empty entries, the leaf is
    `emptyLeafHash` and the siblings are `defaultHash` values at
    each level (matching `rangeRoot`'s short-circuit form).

    Note: avoids `let (leaf, sibsBelow) := ...` destructuring (which
    Lean compiles to a `match`) and avoids intermediate `let`
    bindings in favour of explicit `.1` / `.2` projections, so
    downstream proofs can rewrite the result cleanly. -/
def constructProofAux (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (entries : List (WithdrawalId × PendingWithdrawal))
    (level : Nat) : ByteArray × List ByteArray :=
  match entries, level with
  | [], _ =>
    -- Empty subtree: emit the empty-leaf sentinel and `defaultHash`
    -- siblings at each level.
    (emptyLeafHash, emptyProofSiblings H level)
  | (_, wd) :: _, 0 =>
    -- Non-empty leaf cell: take the head's wd.  In the recursion's
    -- intended use (top-level call from `constructProof` with
    -- `level = smtHeight`), the filter chain narrows the entries
    -- list to those whose bits 0..smtHeight-1 all match `idx`.  For
    -- WithdrawalIds in `[0, 2^smtHeight)` (which is the realistic
    -- bound — the runtime adaptor's `nextWdId` is a `UInt64`), this
    -- is at most one entry and it is exactly `(idx, wd)` if mapped.
    (leafBytes wd, [])
  | _ :: _, k + 1 =>
    if pathBitAtLevel idx k then
      ((constructProofAux H idx
          (entries.filter (fun p => pathBitAtLevel p.1 k = true)) k).1,
       rangeRoot H k (entries.filter (fun p => pathBitAtLevel p.1 k = false)) ::
         (constructProofAux H idx
          (entries.filter (fun p => pathBitAtLevel p.1 k = true)) k).2)
    else
      ((constructProofAux H idx
          (entries.filter (fun p => pathBitAtLevel p.1 k = false)) k).1,
       rangeRoot H k (entries.filter (fun p => pathBitAtLevel p.1 k = true)) ::
         (constructProofAux H idx
          (entries.filter (fun p => pathBitAtLevel p.1 k = false)) k).2)

/-- `constructProofAux` on non-empty entries at level `k+1` and
    bit-true unfolds to a `cons` of the left-entries' rangeRoot
    onto the right-entries' sub-proof. -/
private theorem constructProofAux_succ_cons_true
    (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (p : WithdrawalId × PendingWithdrawal)
    (rest : List (WithdrawalId × PendingWithdrawal)) (k : Nat)
    (hbit : pathBitAtLevel idx k = true) :
    constructProofAux H idx (p :: rest) (k + 1) =
      ((constructProofAux H idx
          ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).1,
       rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) ::
         (constructProofAux H idx
          ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).2) := by
  show (if pathBitAtLevel idx k then
          ((constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).1,
           rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) ::
             (constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).2)
        else
          ((constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).1,
           rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) ::
             (constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).2))
        = _
  rw [if_pos hbit]

/-- `constructProofAux` on non-empty entries at level `k+1` and
    bit-false unfolds. -/
private theorem constructProofAux_succ_cons_false
    (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (p : WithdrawalId × PendingWithdrawal)
    (rest : List (WithdrawalId × PendingWithdrawal)) (k : Nat)
    (hbit : ¬ pathBitAtLevel idx k = true) :
    constructProofAux H idx (p :: rest) (k + 1) =
      ((constructProofAux H idx
          ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).1,
       rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) ::
         (constructProofAux H idx
          ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).2) := by
  show (if pathBitAtLevel idx k then
          ((constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).1,
           rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) ::
             (constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).2)
        else
          ((constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).1,
           rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) ::
             (constructProofAux H idx
              ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).2))
        = _
  rw [if_neg hbit]

/-- `constructProofAux` on empty entries: leaf is sentinel,
    siblings are `emptyProofSiblings`. -/
private theorem constructProofAux_nil
    (H : ByteArray → ByteArray) (idx : WithdrawalId) (level : Nat) :
    constructProofAux H idx [] level =
      (emptyLeafHash, emptyProofSiblings H level) := by
  cases level <;> rfl

/-- `constructProofAux` siblings list has length exactly `level`. -/
theorem constructProofAux_siblings_length
    (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (entries : List (WithdrawalId × PendingWithdrawal)) (level : Nat) :
    (constructProofAux H idx entries level).2.length = level := by
  induction level generalizing entries with
  | zero =>
    -- Both nil and cons cases at level 0 produce a snd of `[]`.
    cases entries with
    | nil      => rfl
    | cons _ _ => rfl
  | succ k ih =>
    cases entries with
    | nil =>
      -- Empty entries: snd = emptyProofSiblings H (k+1), length k+1 by lemma.
      show (emptyLeafHash, emptyProofSiblings H (k + 1)).2.length = k + 1
      exact emptyProofSiblings_length H (k + 1)
    | cons p rest =>
      by_cases hbit : pathBitAtLevel idx k
      · rw [constructProofAux_succ_cons_true H idx p rest k hbit]
        show (rangeRoot H k _ ::
              (constructProofAux H idx _ k).2).length = k + 1
        rw [List.length_cons, ih]
      · rw [constructProofAux_succ_cons_false H idx p rest k hbit]
        show (rangeRoot H k _ ::
              (constructProofAux H idx _ k).2).length = k + 1
        rw [List.length_cons, ih]

/-- Construct the canonical SMT proof for `idx` against `b.pending`. -/
def constructProof (H : ByteArray → ByteArray) (b : BridgeState)
    (idx : WithdrawalId) : WithdrawalProof :=
  let raw := constructProofAux H idx b.pending.toList smtHeight
  let h_size : raw.2.toArray.size = smtHeight := by
    rw [List.size_toArray]
    exact constructProofAux_siblings_length H idx b.pending.toList smtHeight
  { leaf     := raw.1
    index    := idx
    siblings := ⟨raw.2.toArray, h_size⟩ }

/-! ## §8.1.2 theorems -/

/-- §8.1.2: `constructProof` is deterministic. -/
theorem constructProof_deterministic
    (H : ByteArray → ByteArray) (b₁ b₂ : BridgeState)
    (idx₁ idx₂ : WithdrawalId)
    (hb : b₁ = b₂) (hi : idx₁ = idx₂) :
    constructProof H b₁ idx₁ = constructProof H b₂ idx₂ := by
  rw [hb, hi]

/-- §8.1.2: the `siblings` vector has length `smtHeight`. -/
theorem constructProof_siblings_length
    (H : ByteArray → ByteArray) (b : BridgeState) (idx : WithdrawalId) :
    (constructProof H b idx).siblings.size = smtHeight := rfl

/-- §8.1.2: `verifyProof` is total. -/
theorem verifyProof_total
    (H : ByteArray → ByteArray) (proof : WithdrawalProof)
    (root : ByteArray) :
    verifyProof H proof root = true ∨ verifyProof H proof root = false := by
  rcases hb : verifyProof H proof root with _ | _
  · exact Or.inr rfl
  · exact Or.inl rfl

/-! ## §8.1.3 — `verifyProof_complete` (unconditional) -/

/-- Bridge: `Vector.toList` of a `Vector` built from `l.toArray`
    recovers `l`. -/
private theorem siblings_toList
    (l : List ByteArray) (h : l.toArray.size = smtHeight) :
    (Vector.mk (n := smtHeight) l.toArray h).toList = l := by
  show l.toArray.toList = l
  exact List.toList_toArray

/-- Auxiliary: running `verifyProofRec` on `(emptyLeafHash,
    emptyProofSiblings H level)` produces `defaultHash H level`.
    Used in the empty-entries case of `verifyProofRec_eq_rangeRoot`. -/
theorem verifyProofRec_emptyProof_eq_defaultHash
    (H : ByteArray → ByteArray) (idx : WithdrawalId) (level : Nat) :
    verifyProofRec H idx emptyLeafHash (emptyProofSiblings H level) level =
      defaultHash H level := by
  induction level with
  | zero      => rfl
  | succ k ih =>
    -- emptyProofSiblings H (k+1) = defaultHash H k :: emptyProofSiblings H k.
    show verifyProofRec H idx emptyLeafHash
            (defaultHash H k :: emptyProofSiblings H k) (k + 1)
       = defaultHash H (k + 1)
    show hashUp H (pathBitAtLevel idx k)
            (verifyProofRec H idx emptyLeafHash (emptyProofSiblings H k) k)
            (defaultHash H k)
       = defaultHash H (k + 1)
    rw [ih]
    -- Goal: hashUp H bit (defaultHash H k) (defaultHash H k) = defaultHash H (k+1)
    -- defaultHash H (k+1) = H (defaultHash H k ++ defaultHash H k).
    -- hashUp H true a b = H (b ++ a); hashUp H false a b = H (a ++ b).
    -- Either way, with a = b = defaultHash H k, we get H (defaultHash k ++ defaultHash k).
    unfold hashUp
    cases pathBitAtLevel idx k with
    | true  => rfl
    | false => rfl

/-- The headline auxiliary identity: `verifyProofRec` applied to
    the canonical proof's data reproduces `rangeRoot`. -/
theorem verifyProofRec_eq_rangeRoot
    (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (entries : List (WithdrawalId × PendingWithdrawal)) (level : Nat) :
    verifyProofRec H idx
      (constructProofAux H idx entries level).1
      (constructProofAux H idx entries level).2
      level
    = rangeRoot H level entries := by
  induction level generalizing entries with
  | zero =>
    cases entries with
    | nil =>
      show emptyLeafHash = defaultHash H 0
      rfl
    | cons p _ =>
      show leafBytes p.2 = leafBytes p.2
      rfl
  | succ k ih =>
    cases entries with
    | nil =>
      -- Empty case: both sides equal defaultHash (k+1).
      show verifyProofRec H idx emptyLeafHash
              (emptyProofSiblings H (k + 1)) (k + 1)
        = defaultHash H (k + 1)
      exact verifyProofRec_emptyProof_eq_defaultHash H idx (k + 1)
    | cons p rest =>
      by_cases hbit : pathBitAtLevel idx k
      · -- idx in right subtree; sibling is leftEntries' rangeRoot.
        rw [constructProofAux_succ_cons_true H idx p rest k hbit]
        dsimp only
        have h_unfold :
            verifyProofRec H idx
              (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).1
              (rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) ::
                (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).2)
              (k + 1)
            = hashUp H (pathBitAtLevel idx k)
                (verifyProofRec H idx
                  (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).1
                  (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) k).2 k)
                (rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false))) := rfl
        rw [h_unfold]
        have ih_right := ih ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true))
        rw [ih_right]
        unfold hashUp
        rw [if_pos hbit]
        -- Goal: H (rangeRoot H k left ++ rangeRoot H k right) = rangeRoot H (k+1) (p :: rest)
        -- The RHS, by rangeRoot_succ_cons, equals H (rangeRoot k left ++ rangeRoot k right). Both equal.
        exact (rangeRoot_succ_cons H k p rest).symm
      · -- idx in left subtree; sibling is rightEntries' rangeRoot.
        rw [constructProofAux_succ_cons_false H idx p rest k hbit]
        dsimp only
        have h_unfold :
            verifyProofRec H idx
              (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).1
              (rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true)) ::
                (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).2)
              (k + 1)
            = hashUp H (pathBitAtLevel idx k)
                (verifyProofRec H idx
                  (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).1
                  (constructProofAux H idx ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false)) k).2 k)
                (rangeRoot H k ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = true))) := rfl
        rw [h_unfold]
        have ih_left := ih ((p :: rest).filter (fun q => pathBitAtLevel q.1 k = false))
        rw [ih_left]
        unfold hashUp
        rw [if_neg hbit]
        exact (rangeRoot_succ_cons H k p rest).symm

/-- The proof's siblings list equals `constructProofAux`'s output. -/
theorem constructProof_siblings_toList
    (H : ByteArray → ByteArray) (b : BridgeState) (idx : WithdrawalId) :
    (constructProof H b idx).siblings.toList =
      (constructProofAux H idx b.pending.toList smtHeight).2 := by
  unfold constructProof
  exact siblings_toList _ _

/-- The proof's leaf equals `constructProofAux`'s leaf. -/
theorem constructProof_leaf
    (H : ByteArray → ByteArray) (b : BridgeState) (idx : WithdrawalId) :
    (constructProof H b idx).leaf =
      (constructProofAux H idx b.pending.toList smtHeight).1 := rfl

/-- The proof's index is the supplied `idx`. -/
theorem constructProof_index
    (H : ByteArray → ByteArray) (b : BridgeState) (idx : WithdrawalId) :
    (constructProof H b idx).index = idx := rfl

/-- The canonical proof for ANY index (mapped or unmapped) verifies
    against `withdrawalRoot`.

    This is a stronger statement than the integration plan's
    §8.1.3: the canonical proof for an unmapped idx is a valid
    *non-membership proof* (its leaf is the empty sentinel and the
    siblings are the canonical sibling path), and it verifies
    against the actual root.  The spec-form theorem
    `verifyProof_complete` (with the `b.pending[idx]? = some wd`
    hypothesis) is a direct corollary. -/
theorem verifyProof_complete_any_index
    (H : ByteArray → ByteArray) (b : BridgeState)
    (idx : WithdrawalId) :
    verifyProof H (constructProof H b idx) (withdrawalRoot H b) = true := by
  unfold verifyProof
  rw [constructProof_siblings_toList, constructProof_leaf,
      constructProof_index]
  rw [verifyProofRec_eq_rangeRoot]
  show decide (rangeRoot H smtHeight b.pending.toList = withdrawalRoot H b) = true
  apply decide_eq_true
  rfl

/-- §8.1.3: the canonical proof for any populated `(idx, wd)`
    verifies against `withdrawalRoot`.  Direct corollary of
    `verifyProof_complete_any_index`; the `b.pending[idx]? = some
    wd` hypothesis is the spec-required form, retained verbatim
    even though the underlying proof works without it. -/
theorem verifyProof_complete
    (H : ByteArray → ByteArray) (b : BridgeState)
    (idx : WithdrawalId) (wd : PendingWithdrawal)
    (_h : b.pending[idx]? = some wd) :
    verifyProof H (constructProof H b idx) (withdrawalRoot H b) = true :=
  verifyProof_complete_any_index H b idx

/-! ## §8.1.4 — `verifyProof_sound` (hash-conditional)

The soundness theorem: under collision-resistance, uniform
output-size, and structural-size hypotheses on the proof, a
verifying proof matches the canonical construction.

The proof rests on three cryptographic / structural facts:

  1. **Collision-freeness.**  `H x = H y → x = y`.
  2. **Uniform output size.**  `(H b).size = 32` for all `b`.
  3. **Leaf size matching.**  `proof.leaf.size = canonical.leaf.size`.
  4. **Sibling sizes.**  Each `proof.siblings[i].size = 32`.

The hypotheses do not appear in the axiom audit (they are
function arguments, not Lean axioms).  The `#print axioms`
report for `verifyProof_sound` returns only `[propext,
Classical.choice, Quot.sound]`. -/

/-- `CollisionFree` injectivity helper.  Imported from
    `Bridge/Eip712.lean`'s definition: `CollisionFree H` says
    `∀ x y, H x = H y → x = y`. -/
private theorem collisionFree_inj {H : ByteArray → ByteArray}
    (hCF : CollisionFree H)
    {x y : ByteArray} (h : H x = H y) : x = y :=
  hCF x y h

/-- `H` produces uniformly-sized outputs (= 32 bytes for keccak256). -/
def UniformOutputSize (H : ByteArray → ByteArray) (n : Nat) : Prop :=
  ∀ b, (H b).size = n

/-- ByteArray append injectivity at known sizes (lifted via `.data`).

    Given `a₁ ++ b₁ = a₂ ++ b₂` as ByteArrays and `a₁.size = a₂.size`,
    extract `a₁ = a₂ ∧ b₁ = b₂`.  Proof goes through the `.data`
    projection (Array of UInt8): `data_append` distributes the
    concatenation, then `Array.toList_append` reduces to
    `List.append_inj` at known lengths. -/
private theorem byteArray_append_inj
    {a₁ a₂ b₁ b₂ : ByteArray}
    (h_concat : a₁ ++ b₁ = a₂ ++ b₂)
    (h_size : a₁.size = a₂.size) :
    a₁ = a₂ ∧ b₁ = b₂ := by
  have h_data : (a₁ ++ b₁).data = (a₂ ++ b₂).data :=
    congrArg ByteArray.data h_concat
  rw [ByteArray.data_append, ByteArray.data_append] at h_data
  have h_data_list : (a₁.data ++ b₁.data).toList = (a₂.data ++ b₂.data).toList :=
    congrArg Array.toList h_data
  rw [Array.toList_append, Array.toList_append] at h_data_list
  have h_size_data : a₁.data.toList.length = a₂.data.toList.length := by
    rw [← Array.size_eq_length_toList, ← Array.size_eq_length_toList]
    show a₁.data.size = a₂.data.size
    exact h_size
  have ⟨h_a_list, h_b_list⟩ := List.append_inj h_data_list h_size_data
  have h_a : a₁ = a₂ :=
    ByteArray.ext_iff.mpr (Array.ext' h_a_list)
  have h_b : b₁ = b₂ :=
    ByteArray.ext_iff.mpr (Array.ext' h_b_list)
  exact ⟨h_a, h_b⟩

/-- `hashUp` injectivity: under collision-freeness and matching
    operand sizes, equal `hashUp` outputs imply equal operands. -/
private theorem hashUp_inj_of_collisionFree
    {H : ByteArray → ByteArray} (hCF : CollisionFree H)
    (right? : Bool) {a₁ s₁ a₂ s₂ : ByteArray}
    (h_eq : hashUp H right? a₁ s₁ = hashUp H right? a₂ s₂)
    (h_size_a : a₁.size = a₂.size)
    (h_size_s : s₁.size = s₂.size) :
    a₁ = a₂ ∧ s₁ = s₂ := by
  unfold hashUp at h_eq
  cases right? with
  | true =>
    -- After unfold + cases, h_eq is already H (s₁ ++ a₁) = H (s₂ ++ a₂).
    have h_inner : (s₁ ++ a₁) = (s₂ ++ a₂) := collisionFree_inj hCF h_eq
    have ⟨h_s, h_a⟩ := byteArray_append_inj h_inner h_size_s
    exact ⟨h_a, h_s⟩
  | false =>
    have h_inner : (a₁ ++ s₁) = (a₂ ++ s₂) := collisionFree_inj hCF h_eq
    exact byteArray_append_inj h_inner h_size_a

/-- The verifier's output at level `k+1` is always the result of
    a `hashUp`, hence has size 32 under `UniformOutputSize`. -/
private theorem verifyProofRec_size_succ
    {H : ByteArray → ByteArray} (h_uniform : UniformOutputSize H 32)
    (idx : WithdrawalId) (leaf : ByteArray) (s : ByteArray)
    (rest : List ByteArray) (k : Nat) :
    (verifyProofRec H idx leaf (s :: rest) (k + 1)).size = 32 := by
  show (hashUp H (pathBitAtLevel idx k)
          (verifyProofRec H idx leaf rest k) s).size = 32
  unfold hashUp
  cases pathBitAtLevel idx k with
  | true  => exact h_uniform _
  | false => exact h_uniform _

/-- Element-wise size match between two sibling lists.  Used as
    the soundness theorem's hypothesis for variable-size siblings
    (e.g. the leaf-adjacent canonical sibling can be `leafBytes
    wd` for a populated other-leaf, which is ~56 bytes — not 32).

    For TreeMaps with sequentially-assigned WithdrawalIds (the
    realistic deployment case), the leaf-adjacent canonical
    sibling at id 0 is `leafBytes wd_1` if id 1 is also mapped;
    the soundness hypothesis must accommodate this. -/
def siblingsHaveMatchingSizes
    (sibs₁ sibs₂ : List ByteArray) : Prop :=
  ∀ p ∈ List.zip sibs₁ sibs₂, p.1.size = p.2.size

/-- A consequence of size-32 hypotheses: element-wise sizes match. -/
theorem siblingsHaveMatchingSizes_of_all_32
    (sibs₁ sibs₂ : List ByteArray)
    (h₁ : ∀ s ∈ sibs₁, s.size = 32)
    (h₂ : ∀ s ∈ sibs₂, s.size = 32) :
    siblingsHaveMatchingSizes sibs₁ sibs₂ := by
  intro p hp
  have ⟨hp₁, hp₂⟩ := List.of_mem_zip hp
  rw [h₁ _ hp₁, h₂ _ hp₂]

/-- Verifier injectivity (general form): under CR + uniform output
    size + matched leaf size + element-wise sibling size match,
    two proof-data tuples that produce the same verifier output
    have identical leaf bytes and siblings.

    The element-wise sibling size match is the relaxed form that
    handles variable-size leaf-adjacent siblings (which can be
    `leafBytes wd` ~56 bytes when the other leaf in the deepest
    pair is populated). -/
theorem verifyProofRec_inj
    {H : ByteArray → ByteArray} (hCF : CollisionFree H)
    (h_uniform : UniformOutputSize H 32)
    (idx : WithdrawalId) (level : Nat) :
    ∀ (leaf₁ leaf₂ : ByteArray) (sibs₁ sibs₂ : List ByteArray),
      sibs₁.length = level → sibs₂.length = level →
      leaf₁.size = leaf₂.size →
      siblingsHaveMatchingSizes sibs₁ sibs₂ →
      verifyProofRec H idx leaf₁ sibs₁ level =
        verifyProofRec H idx leaf₂ sibs₂ level →
      leaf₁ = leaf₂ ∧ sibs₁ = sibs₂ := by
  induction level with
  | zero =>
    intro leaf₁ leaf₂ sibs₁ sibs₂ h_len₁ h_len₂ _ _ h_eq
    have h_sibs_nil : sibs₁ = [] ∧ sibs₂ = [] := by
      refine ⟨?_, ?_⟩
      · exact List.length_eq_zero_iff.mp h_len₁
      · exact List.length_eq_zero_iff.mp h_len₂
    rw [h_sibs_nil.1, h_sibs_nil.2] at h_eq ⊢
    -- Now h_eq : verifyProofRec H idx leaf₁ [] 0 = verifyProofRec H idx leaf₂ [] 0
    -- Both reduce to leaf, so leaf₁ = leaf₂.
    have : leaf₁ = leaf₂ := h_eq
    exact ⟨this, rfl⟩
  | succ k ih =>
    intro leaf₁ leaf₂ sibs₁ sibs₂ h_len₁ h_len₂ h_leaf_size h_sibs_match h_eq
    -- sibs are non-empty.
    cases sibs₁ with
    | nil => simp at h_len₁
    | cons s₁ rest₁ =>
    cases sibs₂ with
    | nil => simp at h_len₂
    | cons s₂ rest₂ =>
    have h_rest_len₁ : rest₁.length = k := by simpa using h_len₁
    have h_rest_len₂ : rest₂.length = k := by simpa using h_len₂
    -- Extract the head pair's size match from siblingsHaveMatchingSizes.
    have h_size_s : s₁.size = s₂.size := by
      apply h_sibs_match (s₁, s₂)
      show (s₁, s₂) ∈ List.zip (s₁ :: rest₁) (s₂ :: rest₂)
      rw [List.zip_cons_cons]
      exact List.mem_cons_self
    have h_rest_match : siblingsHaveMatchingSizes rest₁ rest₂ := by
      intro p hp
      apply h_sibs_match p
      show p ∈ List.zip (s₁ :: rest₁) (s₂ :: rest₂)
      rw [List.zip_cons_cons]
      exact List.mem_cons_of_mem _ hp
    -- h_eq says hashUp _ inner₁ s₁ = hashUp _ inner₂ s₂.
    have h_unfold₁ :
        verifyProofRec H idx leaf₁ (s₁ :: rest₁) (k + 1) =
        hashUp H (pathBitAtLevel idx k)
          (verifyProofRec H idx leaf₁ rest₁ k) s₁ := rfl
    have h_unfold₂ :
        verifyProofRec H idx leaf₂ (s₂ :: rest₂) (k + 1) =
        hashUp H (pathBitAtLevel idx k)
          (verifyProofRec H idx leaf₂ rest₂ k) s₂ := rfl
    rw [h_unfold₁, h_unfold₂] at h_eq
    -- Inner-size: match on k.
    have h_inner_size :
        (verifyProofRec H idx leaf₁ rest₁ k).size =
        (verifyProofRec H idx leaf₂ rest₂ k).size := by
      cases k with
      | zero =>
        cases rest₁ with
        | cons _ _ => simp at h_rest_len₁
        | nil =>
        cases rest₂ with
        | cons _ _ => simp at h_rest_len₂
        | nil =>
        show leaf₁.size = leaf₂.size
        exact h_leaf_size
      | succ k' =>
        cases rest₁ with
        | nil => simp at h_rest_len₁
        | cons s₁' rest₁' =>
        cases rest₂ with
        | nil => simp at h_rest_len₂
        | cons s₂' rest₂' =>
        rw [verifyProofRec_size_succ h_uniform,
            verifyProofRec_size_succ h_uniform]
    -- Apply hashUp_inj to recover inner equality + sibling equality.
    have ⟨h_inner_eq, h_s_eq⟩ :=
      hashUp_inj_of_collisionFree hCF (pathBitAtLevel idx k)
        h_eq h_inner_size h_size_s
    -- Apply IH to inner equality.
    have ⟨h_leaf_eq, h_rest_eq⟩ :=
      ih leaf₁ leaf₂ rest₁ rest₂ h_rest_len₁ h_rest_len₂
        h_leaf_size h_rest_match h_inner_eq
    refine ⟨h_leaf_eq, ?_⟩
    rw [h_s_eq, h_rest_eq]

/-! ## Leaf-recovery lemma (auxiliary for the spec-form soundness)

The integration plan §8.1.4's existential conclusion form
(`∃ wd, b.pending[idx]? = some wd ∧ proof.leaf = encode wd`) requires
identifying the canonical leaf as `leafBytes wd` for the mapped
`wd`.  That identification rests on the recursion's filter chain
narrowing entries down to exactly the singleton `[(idx, wd)]` at
level 0 — provable but structurally involved (the filter at each
level removes entries whose path bit at that level disagrees with
`idx`'s, eventually leaving only entries with all `smtHeight` bits
matching).

Two invariants make the proof tractable:

  1. **Filter preserves matching entries.**  If `(idx, wd) ∈
     entries`, then `(idx, wd) ∈ entries.filter (pathBitAtLevel _ k
     = pathBitAtLevel idx k)` for any `k` (since idx's bit matches
     itself).
  2. **Recursion descends into the matching side.**  At level
     `k + 1`, `constructProofAux` descends into the half whose bit
     k equals `pathBitAtLevel idx k` — exactly the half containing
     `(idx, wd)` if mapped.

By these two invariants, the recursion preserves `(idx, wd) ∈
entries` at every level.  At level 0 with non-empty entries, the
function takes the head's `wd`.  Under the additional structural
assumption that the original entries list is from a TreeMap (so
keys are distinct), only `(idx, wd)` survives all filters when
`idx < 2^smtHeight`, ensuring it's the head. -/

/-- Filtering by idx's path bit preserves entries with key idx. -/
private theorem mem_filter_pathBitAtLevel_self
    (idx : WithdrawalId) (wd : PendingWithdrawal) (k : Nat)
    (entries : List (WithdrawalId × PendingWithdrawal))
    (h : (idx, wd) ∈ entries) :
    (idx, wd) ∈ entries.filter
      (fun p => pathBitAtLevel p.1 k = pathBitAtLevel idx k) := by
  rw [List.mem_filter]
  refine ⟨h, ?_⟩
  show decide _ = true
  exact decide_eq_true rfl

/-- The canonical leaf for `idx` at any level, given that `(idx, wd)`
    is in entries: at level 0 it's `leafBytes wd` (provided the entry
    is the head — guaranteed by the filter chain in the canonical
    construction).

    This auxiliary doesn't characterise the leaf for arbitrary
    `entries`; it captures the singleton case which the canonical
    recursion reduces to. -/
private theorem constructProofAux_leaf_singleton
    (H : ByteArray → ByteArray) (idx : WithdrawalId)
    (wd : PendingWithdrawal) (level : Nat) :
    (constructProofAux H idx [(idx, wd)] level).1 = leafBytes wd := by
  induction level with
  | zero      => rfl
  | succ k ih =>
    -- At level k+1, the recursion filters and descends.
    -- pathBitAtLevel idx k filters [(idx, wd)] → [(idx, wd)]
    -- (idx's bit matches idx's bit trivially).
    by_cases hbit : pathBitAtLevel idx k
    · -- bit = true: descend with rightEntries = [(idx, wd)] (since idx's bit is true).
      rw [constructProofAux_succ_cons_true H idx (idx, wd) [] k hbit]
      dsimp only
      -- Goal: (constructProofAux H idx ([(idx, wd)].filter (bit=true)) k).1 = leafBytes wd.
      have h_filter :
          ([(idx, wd)] : List (WithdrawalId × PendingWithdrawal)).filter
            (fun q => pathBitAtLevel q.1 k = true) = [(idx, wd)] := by
        unfold List.filter
        show (match decide (pathBitAtLevel idx k = true) with
              | true => (idx, wd) :: List.filter _ []
              | false => List.filter _ [])
            = [(idx, wd)]
        rw [hbit]
        rfl
      rw [h_filter]
      exact ih
    · -- bit = false: descend with leftEntries = [(idx, wd)].
      rw [constructProofAux_succ_cons_false H idx (idx, wd) [] k hbit]
      dsimp only
      have h_filter :
          ([(idx, wd)] : List (WithdrawalId × PendingWithdrawal)).filter
            (fun q => pathBitAtLevel q.1 k = false) = [(idx, wd)] := by
        have hne : pathBitAtLevel idx k = false := Bool.not_eq_true _ |>.mp hbit
        unfold List.filter
        show (match decide (pathBitAtLevel idx k = false) with
              | true => (idx, wd) :: List.filter _ []
              | false => List.filter _ [])
            = [(idx, wd)]
        rw [hne]
        rfl
      rw [h_filter]
      exact ih

/-! ## §8.1.4 — `verifyProof_sound` (hash-conditional)

The soundness statement: under CR + uniform-output size + matched
leaf size + element-wise sibling size match, a verifying proof
matches the canonical proof's leaf and siblings as ByteArray
equality.

The element-wise sibling size match is the key generalisation
from a "all siblings are 32 bytes" hypothesis: in our SMT, the
leaf-adjacent canonical sibling is `leafBytes wd` (variable size,
~56 bytes) when the OTHER leaf in the deepest pair is also
populated.  For sequentially-assigned WithdrawalIds (the
realistic deployment case — `nextWdId` increments monotonically),
ids 2k and 2k+1 always share a deepest pair, so for k > 0, the
canonical leaf-adjacent sibling is variable-sized whenever the
peer id is also mapped.

The runtime adaptor's proof-validation flow:

  1. Compute the canonical proof for `proof.index` (Lean-side).
  2. Compare proof's and canonical's leaf sizes — reject on
     mismatch.
  3. Element-wise compare proof's and canonical's sibling sizes
     — reject on mismatch.
  4. Invoke the verifier — reject if it doesn't accept.
  5. By the soundness theorem, proof matches canonical, so it's
     a valid redemption claim.

The size-match hypotheses are dischargeable because the runtime
adaptor knows both the proof's bytes (user-supplied) and the
canonical's bytes (computed from the bridge state). -/

/-- Soundness (general form): under CR + uniform output size +
    matched leaf size + element-wise sibling size match, a
    verifying proof matches the canonical proof's leaf and
    siblings as ByteArray equality.

    This is the §8.1.4 soundness statement, generalised to handle
    variable-size leaf-adjacent siblings (which arise whenever
    two consecutive WithdrawalIds are mapped — the realistic
    deployment case).  The integration plan's existential form
    (`∃ wd, b.pending[idx]? = some wd ∧ proof.leaf = encode wd`)
    follows by case analysis on `b.pending[idx]?` plus the
    leaf-recovery lemma scoped as a follow-up. -/
theorem verifyProof_sound
    {H : ByteArray → ByteArray} (hCF : CollisionFree H)
    (h_uniform : UniformOutputSize H 32)
    (b : BridgeState) (proof : WithdrawalProof)
    (h_leaf_size :
      proof.leaf.size = (constructProof H b proof.index).leaf.size)
    (h_sibs_match :
      siblingsHaveMatchingSizes
        proof.siblings.toList
        (constructProof H b proof.index).siblings.toList)
    (hVerify : verifyProof H proof (withdrawalRoot H b) = true) :
    proof.leaf = (constructProof H b proof.index).leaf ∧
    proof.siblings = (constructProof H b proof.index).siblings := by
  -- Step 1: extract verifier ByteArray equality from hVerify.
  unfold verifyProof at hVerify
  have h_verifier :
      verifyProofRec H proof.index proof.leaf proof.siblings.toList smtHeight =
      withdrawalRoot H b := by
    exact of_decide_eq_true hVerify
  -- Step 2: relate withdrawalRoot to the canonical verifier output.
  have h_canonical :
      verifyProofRec H proof.index
        (constructProof H b proof.index).leaf
        (constructProof H b proof.index).siblings.toList smtHeight
      = withdrawalRoot H b := by
    rw [constructProof_siblings_toList, constructProof_leaf]
    rw [verifyProofRec_eq_rangeRoot]
    show rangeRoot H smtHeight b.pending.toList = withdrawalRoot H b
    rfl
  -- Step 3: combine into verifyProofRec equality (proof side ↔ canonical side).
  have h_verifier_eq :
      verifyProofRec H proof.index proof.leaf proof.siblings.toList smtHeight =
      verifyProofRec H proof.index
        (constructProof H b proof.index).leaf
        (constructProof H b proof.index).siblings.toList smtHeight := by
    rw [h_verifier, h_canonical]
  -- Step 4: apply verifier injectivity.
  have h_proof_sibs_len : proof.siblings.toList.length = smtHeight :=
    Vector.length_toList
  have h_canonical_sibs_len :
      (constructProof H b proof.index).siblings.toList.length = smtHeight :=
    Vector.length_toList
  have h_index_eq : proof.index = (constructProof H b proof.index).index := by
    rw [constructProof_index]
  have ⟨h_leaf, h_sibs_list⟩ :=
    verifyProofRec_inj hCF h_uniform proof.index smtHeight
      proof.leaf
      (constructProof H b proof.index).leaf
      proof.siblings.toList
      (constructProof H b proof.index).siblings.toList
      h_proof_sibs_len h_canonical_sibs_len
      h_leaf_size h_sibs_match
      (h_index_eq ▸ h_verifier_eq)
  refine ⟨h_leaf, ?_⟩
  -- h_sibs_list : List equality. Lift to Vector via Vector.toList_inj.
  exact Vector.toList_inj.mp h_sibs_list

/-- Soundness (32-byte form): a corollary of `verifyProof_sound`
    for the case where ALL siblings (proof and canonical) are
    32 bytes.  This is the original "dense-32-byte" form of the
    soundness theorem; it applies cleanly when the leaf-adjacent
    canonical sibling is the empty sentinel (i.e., the other leaf
    in the deepest pair is unmapped) or when the runtime adaptor
    pre-hashes leaf bytes to 32 bytes before placing them in the
    SMT (the standard SMT design that deviates from the integration
    plan's `proof.leaf = encode wd` semantics). -/
theorem verifyProof_sound_all_32
    {H : ByteArray → ByteArray} (hCF : CollisionFree H)
    (h_uniform : UniformOutputSize H 32)
    (b : BridgeState) (proof : WithdrawalProof)
    (h_leaf_size :
      proof.leaf.size = (constructProof H b proof.index).leaf.size)
    (h_proof_sibs_size :
      ∀ s ∈ proof.siblings.toList, s.size = 32)
    (h_canonical_sibs_size :
      ∀ s ∈ (constructProof H b proof.index).siblings.toList, s.size = 32)
    (hVerify : verifyProof H proof (withdrawalRoot H b) = true) :
    proof.leaf = (constructProof H b proof.index).leaf ∧
    proof.siblings = (constructProof H b proof.index).siblings :=
  verifyProof_sound hCF h_uniform b proof h_leaf_size
    (siblingsHaveMatchingSizes_of_all_32 _ _ h_proof_sibs_size h_canonical_sibs_size)
    hVerify

end Bridge
end LegalKernel

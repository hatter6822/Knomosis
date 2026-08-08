-- SPDX-License-Identifier: GPL-3.0-or-later
-- Knomosis  - A Societal Kernel
-- Copyright (C) 2026  Adam Hall
-- This program comes with ABSOLUTELY NO WARRANTY.
-- This is free software, and you are welcome to redistribute it
-- under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

import LegalKernel.FaultProof.SmtInjective
import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.Runtime.LogFile

/-!
# Batch actions root (Workstream SB — batched state-root submission)

The Merkle commitment a BATCH submission makes to its per-action
authentication data, and the inclusion proof the fault-proof game's
terminal step verifies against it.  Genesis-Plan §15B; plan document
`docs/planning/` Workstream SB.

## Why this exists

`KnomosisStateRootSubmission` used to publish one state root per L2 log
index — one per ACTION — and the log-entry chain folded exactly one
`l1ActionCommit` per entry, so `terminateOnSingleStep` authenticated
the disputed action against `roots[n+1].expectedNextHash` directly.
Under batching a submission covers `(prevEnd, end]` and only batch
BOUNDARIES have on-chain records, so an intra-batch index has no chain
value to check a single action against.  The batch instead commits an
`actionsRoot`: a sparse-Merkle root over the batch's per-action leaf
commits, keyed by absolute log index, and the terminal step
authenticates the one disputed action by an inclusion proof.

## What is reused

Everything structural is the PROVEN cell-SMT machinery of
`FaultProof/Smt.lean` / `SmtInjective.lean`, instantiated at
`K = V = ByteArray` and full `smtDepth`:

  * the root builder `smtRootListAux`,
  * the proof builder `buildSmtCellProofAux` (bitmask-compressed wire,
    the same `bitmask(32) ‖ siblings(N×32)` shape the L1's
    `SmtCellVerifier` walks),
  * the verifier `verifySmtCellProof`,
  * completeness via `canonicalSiblings_walks_to_root`, and
  * soundness in the shape of `smtCellProof_no_value_substitution`
    (re-proved here at `V = ByteArray` because the generic theorem
    asks for GLOBAL encoder injectivity, and `ByteArray`'s CBE
    injectivity is bounded — the commits here are 32-byte hashes, far
    inside the bound).

The key derivation follows the `smtCellKey` recipe: a domain-tagged
`hashBytes`, so keys are uniformly 32 bytes and
`bitsDistinctBelow_of_keys_pairwise_ne` applies verbatim.

## The leaf binds the signature

A leaf commits `(kind ‖ uint64BE signer ‖ fieldsForL1 ‖ sig)` — the
`l1ActionCommitBytes` preimage extended by the action's SIGNATURE.
The L1 chain used to commit the unsigned triple only, so the game
could never learn whether the disputed action was genuinely
authorized; binding the signature now costs one preimage suffix, and
makes later on-chain verification a drop-in instead of another
chain-shape migration.  Verification itself remains a recorded
follow-up (it needs L1 `ActorId → key` resolution); the injectivity
theorem below fixes the signature width at the secp256k1 wire's 65
bytes so the packed preimage still splits unambiguously.
-/

namespace LegalKernel
namespace FaultProof

open LegalKernel.Runtime
open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## Key derivation -/

/-- Domain-separation tag for batch action keys.  Hashing the tagged
    index (rather than using the raw index bytes) gives uniformly
    32-byte keys — the shape `bitsDistinctBelow_of_keys_pairwise_ne`
    consumes — and keeps action keys disjoint from every other
    domain-tagged key family by the tag bytes. -/
def actionKeyDomain : ByteArray :=
  "knomosis.actionsRoot".toUTF8

/-- The SMT key of log index `n` inside a batch's actions root:
    `hashBytes (actionKeyDomain ++ uint64BE n)` — the `smtCellKey`
    recipe over the absolute log index. -/
def actionKey (n : Nat) : ByteArray :=
  LegalKernel.Runtime.hashBytes (actionKeyDomain ++ StepVMCoherence.uint64BE n)

/-- The pre-image `actionKey` hashes; named so collision-freeness
    hypotheses can list it. -/
def actionKeyPreimage (n : Nat) : ByteArray :=
  actionKeyDomain ++ StepVMCoherence.uint64BE n

/-- `actionKey` is `hashBytes` of its pre-image. -/
theorem actionKey_eq_hash_preimage (n : Nat) :
    actionKey n = LegalKernel.Runtime.hashBytes (actionKeyPreimage n) := rfl

/-- Action keys are exactly 32 bytes. -/
theorem actionKey_size (n : Nat) : (actionKey n).size = 32 :=
  LegalKernel.Runtime.hashBytes_size _

/-! ## Leaf values -/

/-- The packed pre-image a batch leaf commits to:
    `kind(1) ‖ uint64BE signer(8) ‖ fieldsForL1(var) ‖ sig(65)`.
    The first nine bytes are fixed-width and the signature suffix is
    fixed at 65 bytes, so the split is unambiguous — see
    `actionLeafPreimage_inj`. -/
def actionLeafPreimage (kind : UInt8) (signer : Nat)
    (fields sig : ByteArray) : ByteArray :=
  ByteArray.mk #[kind] ++ StepVMCoherence.uint64BE signer ++ fields ++ sig

/-- The 32-byte leaf commit of a signed action: `hashBytes` over
    `actionLeafPreimage` of its L1 field layout plus its signature.
    Extends `StepVMCoherence.l1ActionCommit` (which commits the
    unsigned triple) by the signature suffix. -/
def actionLeafValue (st : SignedAction) : ByteArray :=
  LegalKernel.Runtime.hashBytes
    (actionLeafPreimage (StepVMCoherence.actionKindByte st.action)
      st.signer.toNat (StepVMCoherence.actionFieldsForL1 st.action) st.sig)

/-- Leaf commits are exactly 32 bytes. -/
theorem actionLeafValue_size (st : SignedAction) :
    (actionLeafValue st).size = 32 :=
  LegalKernel.Runtime.hashBytes_size _

/-! ## The batch entry list and its root -/

/-- The SMT entries of a batch whose FIRST action sits at absolute log
    index `first`: entry `i` of the list is keyed `actionKey (first + i)`
    and valued at that entry's leaf commit.  The caller passes the
    batch SLICE of the log (`entries[prevEnd..end)` in submission
    terms), not the whole log. -/
def batchActionEntries : Nat → List Runtime.LogEntry → SmtEntries
  | _, [] => []
  | first, e :: rest =>
    (actionKey first, actionLeafValue e.signedAction)
      :: batchActionEntries (first + 1) rest

/-- The batch's actions root: the canonical cell-SMT root of its
    entry list at full depth.  This is the 32-byte word
    `submitStateRoot` folds into the chain in place of the retired
    per-action commit. -/
def actionsRoot (first : Nat) (entries : List Runtime.LogEntry) : ByteArray :=
  smtRootListAux smtDepth (batchActionEntries first entries)

/-- The actions root is always 32 bytes. -/
theorem actionsRoot_size (first : Nat) (entries : List Runtime.LogEntry) :
    (actionsRoot first entries).size = 32 :=
  smtRootListAux_size _ _

/-- Determinism: equal inputs give equal roots. -/
theorem actionsRoot_deterministic (f₁ f₂ : Nat)
    (e₁ e₂ : List Runtime.LogEntry) (hf : f₁ = f₂) (he : e₁ = e₂) :
    actionsRoot f₁ e₁ = actionsRoot f₂ e₂ := by
  rw [hf, he]

/-! ## Proof construction and verification -/

/-- Build the bitmask-compressed inclusion proof for absolute log
    index `n` against the batch starting at `first`.  Same wire shape
    as every other cell proof (`bitmask(32) ‖ siblings(N×32)` via
    `SmtCellProof.toWireBytes`), so the L1 verifies it with the
    existing `SmtCellVerifier` walk. -/
def buildActionProof (first : Nat) (entries : List Runtime.LogEntry)
    (n : Nat) : SmtCellProof :=
  let (sibs, bitDepths) :=
    buildSmtCellProofAux smtDepth (batchActionEntries first entries)
      (actionKey n)
  { siblings := sibs.toArray
  , bitmask  := bitDepths.foldl setBitmaskBit
                  (ByteArray.mk (Array.replicate 32 (0 : UInt8))) }

/-- Verify an inclusion proof: does `commit` open at `actionKey n`
    against `root`?  A thin instantiation of `verifySmtCellProof` at
    `K = V = ByteArray` — deliberately present-leaf-only, because
    every index inside a batch carries exactly one action; there is
    no absent case for an honest submission to need. -/
def verifyActionProof (root : ByteArray) (n : Nat) (commit : ByteArray)
    (proof : SmtCellProof) : Bool :=
  verifySmtCellProof root (actionKey n) commit proof

/-! ## Key distinctness

The entry keys of a batch are hashes of the tagged per-index
pre-images.  Under collision-freeness over those pre-images the keys
are pairwise distinct (indices differ, `uint64BE_inj` separates the
pre-images, `CollisionFreeOn` separates the hashes), which is exactly
the `BitsDistinctBelow` hypothesis the completeness theorem consumes,
via `bitsDistinctBelow_of_keys_pairwise_ne`. -/

/-- The key pre-images of `count` consecutive indices starting at
    `first`.  Named so collision-freeness hypotheses can range over
    exactly the pre-images a batch hashes. -/
def batchKeyPreimages : Nat → Nat → List ByteArray
  | _, 0 => []
  | first, count + 1 =>
    actionKeyPreimage first :: batchKeyPreimages (first + 1) count

/-- Every in-range index's pre-image is in the pre-image list. -/
theorem actionKeyPreimage_mem_batchKeyPreimages
    (first count n : Nat) (h_lo : first ≤ n) (h_hi : n < first + count) :
    actionKeyPreimage n ∈ batchKeyPreimages first count := by
  induction count generalizing first with
  | zero => omega
  | succ c ih =>
    unfold batchKeyPreimages
    rcases Nat.eq_or_lt_of_le h_lo with h_eq | h_lt
    · exact h_eq ▸ List.mem_cons_self
    · exact List.mem_cons_of_mem _ (ih (first + 1) h_lt (by omega))

/-- `actionKeyPreimage` is injective below `2 ^ 64`: the domain tag is
    a fixed-width prefix, and `uint64BE` is injective on the bound. -/
theorem actionKeyPreimage_inj {n₁ n₂ : Nat}
    (h₁ : n₁ < 2 ^ 64) (h₂ : n₂ < 2 ^ 64)
    (h : actionKeyPreimage n₁ = actionKeyPreimage n₂) : n₁ = n₂ := by
  unfold actionKeyPreimage at h
  obtain ⟨-, h_idx⟩ :=
    byteArray_append_inj_left actionKeyDomain (StepVMCoherence.uint64BE n₁)
      actionKeyDomain (StepVMCoherence.uint64BE n₂) h rfl
  exact StepVMCoherence.uint64BE_inj h₁ h₂ h_idx

/-- Under collision-freeness over the two pre-images, distinct
    in-bound indices have distinct keys. -/
theorem actionKey_ne_of_ne {n₁ n₂ : Nat}
    (h₁ : n₁ < 2 ^ 64) (h₂ : n₂ < 2 ^ 64) (h_ne : n₁ ≠ n₂)
    (h_cf : Bridge.CollisionFreeOn
      [actionKeyPreimage n₁, actionKeyPreimage n₂]
      LegalKernel.Runtime.hashBytes) :
    actionKey n₁ ≠ actionKey n₂ := by
  intro h_eq
  exact h_ne (actionKeyPreimage_inj h₁ h₂
    (h_cf.apply (by simp) (by simp) h_eq))

/-- Every key in a batch's entry list is an `actionKey` of an
    in-range index. -/
theorem key_of_mem_batchActionEntries
    (first : Nat) (entries : List Runtime.LogEntry)
    (p : ByteArray × ByteArray)
    (h : p ∈ batchActionEntries first entries) :
    ∃ n, first ≤ n ∧ n < first + entries.length ∧ p.1 = actionKey n := by
  induction entries generalizing first with
  | nil => cases h
  | cons e rest ih =>
    unfold batchActionEntries at h
    rcases List.mem_cons.mp h with h_head | h_tail
    · exact ⟨first, Nat.le_refl _, by simp, by rw [h_head]⟩
    · obtain ⟨n, h_lo, h_hi, h_key⟩ := ih (first + 1) h_tail
      exact ⟨n, by omega, by simp; omega, h_key⟩

/-- Every entry key is 32 bytes (it is a `hashBytes` output). -/
theorem batchActionEntries_keys_size
    (first : Nat) (entries : List Runtime.LogEntry) :
    ∀ p ∈ batchActionEntries first entries, p.1.size = 32 := by
  intro p hp
  obtain ⟨n, -, -, h_key⟩ := key_of_mem_batchActionEntries first entries p hp
  rw [h_key]
  exact actionKey_size n

/-- The batch's entry keys are pairwise distinct, given the index
    range fits in 64 bits and collision-freeness over the batch's key
    pre-images. -/
theorem batchActionEntries_keys_pairwise_ne
    (first : Nat) (entries : List Runtime.LogEntry)
    (h_range : first + entries.length ≤ 2 ^ 64)
    (h_cf : Bridge.CollisionFreeOn
      (batchKeyPreimages first entries.length)
      LegalKernel.Runtime.hashBytes) :
    (batchActionEntries first entries).Pairwise (fun a b => a.1 ≠ b.1) := by
  induction entries generalizing first with
  | nil => exact List.Pairwise.nil
  | cons e rest ih =>
    unfold batchActionEntries
    refine List.Pairwise.cons ?_ ?_
    · intro p hp h_eq
      obtain ⟨n, h_lo, h_hi, h_key⟩ :=
        key_of_mem_batchActionEntries (first + 1) rest p hp
      simp only [List.length_cons] at h_range
      have h_mem₁ : actionKeyPreimage first
          ∈ batchKeyPreimages first (rest.length + 1) :=
        actionKeyPreimage_mem_batchKeyPreimages _ _ _ (Nat.le_refl _)
          (by omega)
      have h_mem₂ : actionKeyPreimage n
          ∈ batchKeyPreimages first (rest.length + 1) :=
        actionKeyPreimage_mem_batchKeyPreimages _ _ _ (by omega) (by omega)
      have h_pair_cf : Bridge.CollisionFreeOn
          [actionKeyPreimage first, actionKeyPreimage n]
          LegalKernel.Runtime.hashBytes := by
        intro x hx y hy h_hash
        have hx' : x ∈ batchKeyPreimages first (rest.length + 1) := by
          rcases List.mem_cons.mp hx with rfl | hx1
          · exact h_mem₁
          · rcases List.mem_cons.mp hx1 with rfl | hx2
            · exact h_mem₂
            · cases hx2
        have hy' : y ∈ batchKeyPreimages first (rest.length + 1) := by
          rcases List.mem_cons.mp hy with rfl | hy1
          · exact h_mem₁
          · rcases List.mem_cons.mp hy1 with rfl | hy2
            · exact h_mem₂
            · cases hy2
        exact h_cf x hx' y hy' h_hash
      exact actionKey_ne_of_ne (by omega) (by omega) (by omega) h_pair_cf
        (h_key ▸ h_eq)
    · refine ih (first + 1) ?_ ?_
      · simp only [List.length_cons] at h_range; omega
      · intro x hx y hy h_hash
        unfold batchKeyPreimages at h_cf
        exact h_cf x (List.mem_cons_of_mem _ hx)
          y (List.mem_cons_of_mem _ hy) h_hash

/-- The `BitsDistinctBelow` hypothesis for a batch, discharged from
    the range bound and pre-image collision-freeness. -/
theorem batchActionEntries_bitsDistinct
    (first : Nat) (entries : List Runtime.LogEntry)
    (h_range : first + entries.length ≤ 2 ^ 64)
    (h_cf : Bridge.CollisionFreeOn
      (batchKeyPreimages first entries.length)
      LegalKernel.Runtime.hashBytes) :
    BitsDistinctBelow smtDepth (batchActionEntries first entries) :=
  bitsDistinctBelow_of_keys_pairwise_ne
    (batchActionEntries_keys_size first entries)
    (batchActionEntries_keys_pairwise_ne first entries h_range h_cf)

/-! ## Completeness -/

/-- The batch's `i`-th entry is in the entry list under its key. -/
theorem mem_batchActionEntries
    (first : Nat) (entries : List Runtime.LogEntry)
    (i : Nat) (e : Runtime.LogEntry) (h : entries[i]? = some e) :
    (actionKey (first + i), actionLeafValue e.signedAction)
      ∈ batchActionEntries first entries := by
  induction entries generalizing first i with
  | nil => simp at h
  | cons hd rest ih =>
    unfold batchActionEntries
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at h
      subst h
      simp
    | succ j =>
      simp only [List.getElem?_cons_succ] at h
      have := ih (first + 1) j h
      have h_idx : first + 1 + j = first + (j + 1) := by omega
      rw [h_idx] at this
      exact List.mem_cons_of_mem _ this

/-- **Completeness (canonical-path form).**  The canonical sibling
    path of an in-batch action walks its leaf back to the batch's
    published `actionsRoot` — the fold the L1 verifier performs.

    Stated over `canonicalSiblings` (the uncompressed path) exactly as
    the state-cell family states it; the bitmask-compressed wire
    `buildActionProof` emits expands to this path, pinned value-level
    by the `faultproof-actions-root` suite across batch shapes, the
    same division of labour `buildSmtCellProof`'s docstring records. -/
theorem actionProof_canonical_walks_to_root
    (first : Nat) (entries : List Runtime.LogEntry)
    (i : Nat) (e : Runtime.LogEntry) (h_get : entries[i]? = some e)
    (h_range : first + entries.length ≤ 2 ^ 64)
    (h_cf : Bridge.CollisionFreeOn
      (batchKeyPreimages first entries.length)
      LegalKernel.Runtime.hashBytes) :
    ((canonicalSiblings smtDepth (batchActionEntries first entries)
        (actionKey (first + i))).zip
      (keyBitsUpTo smtDepth (actionKey (first + i)))).foldl stepPair
        (leafHash (actionKey (first + i)) (actionLeafValue e.signedAction))
      = actionsRoot first entries :=
  canonicalSiblings_walks_to_root smtDepth (batchActionEntries first entries)
    (actionKey (first + i)) (actionLeafValue e.signedAction)
    (mem_batchActionEntries first entries i e h_get)
    (batchActionEntries_bitsDistinct first entries h_range h_cf)

/-! ## Soundness -/

/-- **No value substitution.**  At most one 32-byte commit verifies at
    a given `(root, index)` pair, under collision-freeness over the
    involved pre-images.

    This is `smtCellProof_no_value_substitution` re-proved at
    `V = ByteArray`: the generic theorem asks for GLOBAL injectivity
    of the value encoder, and `ByteArray`'s CBE injectivity is
    bounded (`byteArray_encode_injective` requires `size < 256 ^ 8`)
    — a bound the 32-byte commits sit far inside, so the size
    hypotheses stand in for global injectivity and the rest of the
    argument is unchanged. -/
theorem actionProof_no_value_substitution
    (root : ByteArray) (n : Nat) (c₁ c₂ : ByteArray)
    (h_size₁ : c₁.size = 32) (h_size₂ : c₂.size = 32)
    (proof₁ proof₂ : SmtCellProof)
    (h_cf : Bridge.CollisionFreeOn
      (smtCellProofPreimages (actionKey n) c₁ c₂ proof₁ proof₂)
      LegalKernel.Runtime.hashBytes)
    (h_verify₁ : verifyActionProof root n c₁ proof₁ = true)
    (h_verify₂ : verifyActionProof root n c₂ proof₂ = true) :
    c₁ = c₂ := by
  unfold verifyActionProof verifySmtCellProof at h_verify₁ h_verify₂
  rw [Bool.and_eq_true] at h_verify₁ h_verify₂
  obtain ⟨h_wf₁, h_walk₁⟩ := h_verify₁
  obtain ⟨h_wf₂, h_walk₂⟩ := h_verify₂
  have h_walk_eq₁ : smtWalk (actionKey n) c₁ proof₁ = root :=
    decide_eq_true_eq.mp h_walk₁
  have h_walk_eq₂ : smtWalk (actionKey n) c₂ proof₂ = root :=
    decide_eq_true_eq.mp h_walk₂
  have h_walks_agree :
      ((expandSiblings proof₁).zip (keyBits (actionKey n))).foldl stepPair
          (leafHash (actionKey n) c₁) =
      ((expandSiblings proof₂).zip (keyBits (actionKey n))).foldl stepPair
          (leafHash (actionKey n) c₂) := by
    show smtWalk (actionKey n) c₁ proof₁ = smtWalk (actionKey n) c₂ proof₂
    rw [h_walk_eq₁, h_walk_eq₂]
  have h_leaf_eq : leafHash (actionKey n) c₁ = leafHash (actionKey n) c₂ :=
    walk_leaf_inj_under_collision_free
      (keyBits (actionKey n)) (expandSiblings proof₁) (expandSiblings proof₂)
      (leafHash (actionKey n) c₁) (leafHash (actionKey n) c₂)
      (h_cf.mono (fun _ hz => List.mem_append_left _ hz))
      (by rw [expandSiblings_length, keyBits_length])
      (by rw [expandSiblings_length, keyBits_length])
      (leafHash_size _ _) (leafHash_size _ _)
      (expandSiblings_all_32 proof₁ h_wf₁)
      (expandSiblings_all_32 proof₂ h_wf₂)
      h_walks_agree
  unfold leafHash at h_leaf_eq
  have h_bytes_eq :
      encodeAsBytes (actionKey n) ++ encodeAsBytes c₁ =
      encodeAsBytes (actionKey n) ++ encodeAsBytes c₂ :=
    h_cf.apply
      (List.mem_append_right _ (by simp))
      (List.mem_append_right _ (by simp)) h_leaf_eq
  obtain ⟨-, h_value_bytes_eq⟩ :=
    byteArray_append_inj_left (encodeAsBytes (actionKey n)) (encodeAsBytes c₁)
      (encodeAsBytes (actionKey n)) (encodeAsBytes c₂) h_bytes_eq rfl
  unfold encodeAsBytes at h_value_bytes_eq
  have h_streams_eq : (Encodable.encode c₁ : Stream) = Encodable.encode c₂ := by
    have h_arr_eq : (Encodable.encode c₁).toArray =
        (Encodable.encode c₂).toArray := by
      injection h_value_bytes_eq
    have h_list_eq : (Encodable.encode c₁).toArray.toList =
        (Encodable.encode c₂).toArray.toList := by rw [h_arr_eq]
    rw [List.toList_toArray, List.toList_toArray] at h_list_eq
    exact h_list_eq
  exact Encoding.byteArray_encode_injective c₁ c₂
    (by rw [h_size₁]; decide) (by rw [h_size₂]; decide) h_streams_eq

/-! ## The terminate-level authentication lemma -/

/-- The packed leaf pre-image splits unambiguously when the two
    signatures share the fixed 65-byte secp256k1 wire width: the
    kind byte and the 8-byte signer prefix are fixed-width, and the
    equal-width signature suffix pins the fields boundary. -/
theorem actionLeafPreimage_inj
    {k₁ k₂ : UInt8} {s₁ s₂ : Nat} {f₁ f₂ sig₁ sig₂ : ByteArray}
    (h_s₁ : s₁ < 2 ^ 64) (h_s₂ : s₂ < 2 ^ 64)
    (h_sig₁ : sig₁.size = 65) (h_sig₂ : sig₂.size = 65)
    (h : actionLeafPreimage k₁ s₁ f₁ sig₁ = actionLeafPreimage k₂ s₂ f₂ sig₂) :
    k₁ = k₂ ∧ s₁ = s₂ ∧ f₁ = f₂ ∧ sig₁ = sig₂ := by
  unfold actionLeafPreimage at h
  -- Re-associate so the fixed-width prefixes peel left-to-right.
  rw [ByteArray.append_assoc, ByteArray.append_assoc,
      ByteArray.append_assoc, ByteArray.append_assoc] at h
  obtain ⟨h_kind, h_rest⟩ :=
    byteArray_append_inj_left (ByteArray.mk #[k₁]) _ (ByteArray.mk #[k₂]) _
      h rfl
  have h_k : k₁ = k₂ := by
    have := congrArg (fun b => b.data.toList) h_kind
    simpa using this
  obtain ⟨h_signer, h_tail⟩ :=
    byteArray_append_inj_left (StepVMCoherence.uint64BE s₁) _
      (StepVMCoherence.uint64BE s₂) _ h_rest
      (by rw [StepVMCoherence.uint64BE_size, StepVMCoherence.uint64BE_size])
  have h_s : s₁ = s₂ := StepVMCoherence.uint64BE_inj h_s₁ h_s₂ h_signer
  -- `f ++ sig` with equal 65-byte suffixes ⇒ equal field sizes.
  have h_sizes : (f₁ ++ sig₁).size = (f₂ ++ sig₂).size := by rw [h_tail]
  rw [ByteArray.size_append, ByteArray.size_append, h_sig₁, h_sig₂] at h_sizes
  obtain ⟨h_f, h_sig⟩ :=
    byteArray_append_inj_left f₁ sig₁ f₂ sig₂ h_tail (by omega)
  exact ⟨h_k, h_s, h_f, h_sig⟩

/-- **The authentication guarantee the terminal step rests on.**  If
    two signed-action spellings both open at the same `(root, index)`
    — each as the hash of its packed leaf pre-image — then they are
    the SAME spelling: same kind, same signer, same L1 fields, same
    signature.

    A responding party therefore cannot settle a game by substituting
    a different action (or a different signature) than the one the
    batch committed at the disputed index.  Composes
    `actionProof_no_value_substitution` (one commit per `(root, n)`)
    with collision-freeness (one pre-image per commit) and
    `actionLeafPreimage_inj` (one spelling per pre-image). -/
theorem actionProof_binds_action
    (root : ByteArray) (n : Nat)
    {k₁ k₂ : UInt8} {s₁ s₂ : Nat} {f₁ f₂ sig₁ sig₂ : ByteArray}
    (h_s₁ : s₁ < 2 ^ 64) (h_s₂ : s₂ < 2 ^ 64)
    (h_sig₁ : sig₁.size = 65) (h_sig₂ : sig₂.size = 65)
    (proof₁ proof₂ : SmtCellProof)
    (h_cf : Bridge.CollisionFreeOn
      (smtCellProofPreimages (actionKey n)
        (LegalKernel.Runtime.hashBytes (actionLeafPreimage k₁ s₁ f₁ sig₁))
        (LegalKernel.Runtime.hashBytes (actionLeafPreimage k₂ s₂ f₂ sig₂))
        proof₁ proof₂
       ++ [actionLeafPreimage k₁ s₁ f₁ sig₁,
           actionLeafPreimage k₂ s₂ f₂ sig₂])
      LegalKernel.Runtime.hashBytes)
    (h_verify₁ : verifyActionProof root n
      (LegalKernel.Runtime.hashBytes (actionLeafPreimage k₁ s₁ f₁ sig₁))
      proof₁ = true)
    (h_verify₂ : verifyActionProof root n
      (LegalKernel.Runtime.hashBytes (actionLeafPreimage k₂ s₂ f₂ sig₂))
      proof₂ = true) :
    k₁ = k₂ ∧ s₁ = s₂ ∧ f₁ = f₂ ∧ sig₁ = sig₂ := by
  have h_commit_eq :
      LegalKernel.Runtime.hashBytes (actionLeafPreimage k₁ s₁ f₁ sig₁) =
      LegalKernel.Runtime.hashBytes (actionLeafPreimage k₂ s₂ f₂ sig₂) :=
    actionProof_no_value_substitution root n _ _
      (LegalKernel.Runtime.hashBytes_size _)
      (LegalKernel.Runtime.hashBytes_size _)
      proof₁ proof₂
      (h_cf.mono (fun _ hz => List.mem_append_left _ hz))
      h_verify₁ h_verify₂
  have h_pre_eq :
      actionLeafPreimage k₁ s₁ f₁ sig₁ = actionLeafPreimage k₂ s₂ f₂ sig₂ :=
    h_cf.apply
      (List.mem_append_right _ (by simp))
      (List.mem_append_right _ (by simp)) h_commit_eq
  exact actionLeafPreimage_inj h_s₁ h_s₂ h_sig₁ h_sig₂ h_pre_eq

/-! ## The batch chain -/

/-- The genesis chain seed the constructor-written anchor record
    carries: `l1NextEntryHash zeroHash genesisStateCommit zeroHash` —
    the ordinary chain step evaluated at the all-zero predecessor and
    the empty actions root.  One formula, mirrored byte-for-byte by
    the L1 constructor and pinned by the `batch_chain` corpus. -/
def genesisChainSeed (genesisStateCommit : ByteArray) : ByteArray :=
  StepVMCoherence.l1NextEntryHash Runtime.zeroHash genesisStateCommit
    Runtime.zeroHash

/-- Fold the chain over a run of batches.  Each list element is one
    batch's `(stateCommit, actionsRoot)` pair; the accumulator is the
    running `expectedNextHash`.  The reference the corpus writer and
    the CLI exporter both compute from. -/
def batchChainFold (seed : ByteArray)
    (batches : List (ByteArray × ByteArray)) : ByteArray :=
  batches.foldl
    (fun acc b => StepVMCoherence.l1NextEntryHash acc b.1 b.2) seed

end FaultProof
end LegalKernel

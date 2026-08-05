-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.KeyDerivation — SMT-key derivation
discipline (Workstream H WU H.2.6).

How does an RBMap-keyed sub-state translate to a fixed-height
SMT path?  Critical for cross-stack equivalence: the Lean side
and Solidity side must agree on the path index for each key, or
the two would compute different roots.

This module specifies the canonical mapping from key (a `Nat`)
to SMT path (a `Vector Bool smtHeight`).  The mapping bit-
indexes from MSB to LSB: bit 0 selects at the leaf level, bit
`smtHeight - 1` at the root.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.FaultProof.Cell

namespace LegalKernel
namespace FaultProof

open LegalKernel.Bridge

/-! ## SMT path derivation -/

/-- The canonical SMT path index for an `Nat` key.  Returns the
    key truncated to `smtHeight` low bits, interpreted as a bit
    string from MSB to LSB.  `pathBitAtLevel` from
    Workstream-D's `WithdrawalRoot.lean` is the per-level
    selector. -/
def smtPathFromNat (k : Nat) (smtHeight : Nat) : List Bool :=
  (List.range smtHeight).map (fun i =>
    -- Bit index: bit `i` from MSB.  `smtHeight - 1 - i` is the
    -- LSB-indexed bit position.
    Nat.testBit k (smtHeight - 1 - i))

/-- The path length is exactly `smtHeight`. -/
theorem smtPathFromNat_length (k : Nat) (smtHeight : Nat) :
    (smtPathFromNat k smtHeight).length = smtHeight := by
  unfold smtPathFromNat
  simp [List.length_map, List.length_range]

/-- Determinism: equal keys + heights ⇒ equal paths. -/
theorem smtPathFromNat_deterministic
    (k₁ k₂ height₁ height₂ : Nat)
    (h_k : k₁ = k₂) (h_h : height₁ = height₂) :
    smtPathFromNat k₁ height₁ = smtPathFromNat k₂ height₂ := by
  rw [h_k, h_h]

/-! ## Aliasing analysis

Two distinct keys `k₁ ≠ k₂` map to the same SMT path iff
`k₁ ≡ k₂ (mod 2^smtHeight)`.  For deployments where keys are
allocated sequentially from a `UInt64` counter (the standard
Knomosis pattern: nextActorId, nextWdId, etc.), keys never reach
`2^64` in any practical timeframe, so aliasing is structurally
impossible. -/

/-- Helper: equal SMT paths imply per-bit equality at every
    in-range bit position.  Building block for the full
    injectivity theorem.

    Proof sketch: the i-th element of each path is
    `Nat.testBit k (smtHeight - 1 - i)`.  Equal lists ⇒ equal
    `getElem?`s ⇒ equal bit values via Option.map's injectivity. -/
theorem smtPathFromNat_eq_iff_bits_eq
    (k₁ k₂ smtHeight : Nat)
    (h_eq : smtPathFromNat k₁ smtHeight = smtPathFromNat k₂ smtHeight) :
    ∀ i, i < smtHeight →
      Nat.testBit k₁ (smtHeight - 1 - i) =
      Nat.testBit k₂ (smtHeight - 1 - i) := by
  intro i h_lt
  unfold smtPathFromNat at h_eq
  have h_idx :
      ((List.range smtHeight).map
        (fun j => Nat.testBit k₁ (smtHeight - 1 - j)))[i]? =
      ((List.range smtHeight).map
        (fun j => Nat.testBit k₂ (smtHeight - 1 - j)))[i]? :=
    congrArg (fun l => l[i]?) h_eq
  -- The map's getElem? at i is `Option.map f (range[i]?)` =
  -- `Option.map f (some i)` = `some (f i)` (since i < smtHeight).
  rw [List.getElem?_map, List.getElem?_map] at h_idx
  have h_range : (List.range smtHeight)[i]? = some i := by
    rw [List.getElem?_eq_some_iff]
    refine ⟨by simp [h_lt], ?_⟩
    exact List.getElem_range _
  rw [h_range] at h_idx
  -- Now h_idx : some (testBit k₁ ...) = some (testBit k₂ ...)
  exact Option.some.inj h_idx

/-! ## Per-sub-state path discipline

The Workstream-H sub-states use the following key types:

  * Balance (outer):  ResourceId : Nat
  * Balance (inner):  ActorId : Nat (= UInt64 in practice)
  * NonceState:       ActorId
  * KeyRegistry:      ActorId
  * LocalPolicies:    ActorId
  * BridgeConsumed:   DepositId : Nat
  * BridgePending:    WithdrawalId : Nat

All keys are `Nat` (transparently coercible from `UInt64`).
The standard SMT path height is `smtHeight = 64`. -/

/-- The standard SMT path height for Workstream-H sub-states. -/
def smtHeight : Nat := 64

/-- Path-derivation specialised to the standard 64-bit height. -/
def smtPath (k : Nat) : List Bool := smtPathFromNat k smtHeight

/-- Path length specialisation. -/
theorem smtPath_length (k : Nat) : (smtPath k).length = 64 :=
  smtPathFromNat_length k 64

/-- Injectivity specialisation: per-bit equality at all 64 bit
    positions.  This bit-equivalence form is the one cross-stack
    equivalence consumes; since heights range over the low 64 bits,
    a `k₁ = k₂` structural form (via `Nat.eq_of_testBit_eq`) holds
    only under a `k < 2 ^ 64` bound and is intentionally not
    mechanised — no consumer requires it. -/
theorem smtPath_bits_eq
    (k₁ k₂ : Nat)
    (h_eq : smtPath k₁ = smtPath k₂) :
    ∀ i, i < 64 →
      Nat.testBit k₁ (63 - i) = Nat.testBit k₂ (63 - i) :=
  smtPathFromNat_eq_iff_bits_eq k₁ k₂ 64 h_eq

/-! ## Smoke checks -/

/-- Spot-check: smtPath 0 has length 64. -/
example : (smtPath 0).length = 64 := smtPath_length 0

/-- Spot-check: smtPath 1 differs from smtPath 0 (last bit). -/
example : smtPath 1 ≠ smtPath 0 := by
  -- The 64th element of smtPath k is the LSB of k.
  -- smtPath 1's LSB is true; smtPath 0's LSB is false.
  intro h
  have h_bits := smtPath_bits_eq 1 0 h 63 (by decide)
  simp at h_bits

/-! ## SMT-path forward injectivity under bit-width bound

The `smtPathFromNat_eq_iff_bits_eq` lemma gives per-bit
equality from path equality.  Under a bit-width bound, this
lifts to Nat equality via the standard "bits below the bound
determine the value" argument. -/

/-- A Nat `< 2^k` is uniquely determined by its low-`k` bits.
    The lift from per-bit equality to Nat equality. -/
private theorem nat_eq_of_testBit_below
    (n₁ n₂ : Nat) (k : Nat)
    (h_bound₁ : n₁ < 2 ^ k) (h_bound₂ : n₂ < 2 ^ k)
    (h_bits : ∀ i, i < k → Nat.testBit n₁ i = Nat.testBit n₂ i) :
    n₁ = n₂ := by
  apply Nat.eq_of_testBit_eq
  intro i
  by_cases h : i < k
  · exact h_bits i h
  · -- For i ≥ k: both testBits are false by `Nat.testBit_lt_two_pow`.
    have h_ge : k ≤ i := Nat.le_of_not_lt h
    have h_pow_le : 2 ^ k ≤ 2 ^ i :=
      Nat.pow_le_pow_right (by decide) h_ge
    have hb₁ : Nat.testBit n₁ i = false :=
      Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le h_bound₁ h_pow_le)
    have hb₂ : Nat.testBit n₂ i = false :=
      Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le h_bound₂ h_pow_le)
    rw [hb₁, hb₂]

/-- #258 — `smtPathFromNat` is injective under bit-width bound.
    Two bounded Nats whose SMT paths agree must be equal.
    Discharged via `smtPathFromNat_eq_iff_bits_eq` (per-bit
    equality) + `nat_eq_of_testBit_below` (bit-equality lifts to
    Nat equality under the bound). -/
theorem smtPathFromNat_inj_under_bound
    (n₁ n₂ smtHeight : Nat)
    (h_bound₁ : n₁ < 2 ^ smtHeight) (h_bound₂ : n₂ < 2 ^ smtHeight)
    (h_eq : smtPathFromNat n₁ smtHeight = smtPathFromNat n₂ smtHeight) :
    n₁ = n₂ := by
  -- Equal paths ⇒ per-bit equality at every in-range position.
  have h_bits :=
    smtPathFromNat_eq_iff_bits_eq n₁ n₂ smtHeight h_eq
  -- Reindex: `smtPathFromNat_eq_iff_bits_eq` indexes via
  -- `smtHeight - 1 - i`; we want bits at positions `< smtHeight`
  -- in the natural order.
  have h_bits_reindexed : ∀ j, j < smtHeight →
      Nat.testBit n₁ j = Nat.testBit n₂ j := by
    intro j h_lt
    have h_i : smtHeight - 1 - j < smtHeight := by omega
    have h_swap : smtHeight - 1 - (smtHeight - 1 - j) = j := by omega
    have h := h_bits (smtHeight - 1 - j) h_i
    rw [h_swap] at h
    exact h
  exact nat_eq_of_testBit_below n₁ n₂ smtHeight h_bound₁ h_bound₂ h_bits_reindexed

/-! ## Canonical SMT key for a cell (WU H.2.6 / SC.2)

An SMT cell proof opens ONE leaf of the state tree.  Which leaf is
determined by the key, so if the key were caller-supplied a proof
for cell X could be replayed as a proof for cell Y — the responder
would open the balance cell it likes and present the value as, say,
the AMM kill switch.  `KnomosisStepVM` must therefore DERIVE the
key from `(cellKind, keyA, keyB)` rather than accept one, and the
two stacks must derive byte-identically or they compute different
roots.

The pre-image layout is fixed-width and packed so the Solidity side
is a single `abi.encodePacked`:

```
cellKeyPreimage t
  = [kindIndex : 1 byte] ++ [keyA : 32 bytes BE] ++ [keyB : 32 bytes BE]
```

which is exactly
`abi.encodePacked(uint8(cellKind), uint256(keyA), uint256(keyB))`
— 65 bytes, no length prefixes, no padding ambiguity.

Hashing rather than packing directly into 32 bytes is forced by the
key types: `DepositId` and `WithdrawalId` are `Nat`, so a packed
`(1 + 8 + 8)`-byte key would alias two deposit ids agreeing mod
`2^64`.  Injectivity is therefore conditional on collision-freeness
over the finitely many pre-images in play, in the same
`Bridge.CollisionFreeOn` style the commitment chain uses. -/

/-- Big-endian 32-byte encoding of a `Nat`, truncated mod `2^256`.
    Mirrors Solidity's `uint256` word.

    Byte `i` is `(n >>> (8 * (31 - i))) % 256`, which is exactly the
    EIP-712 `uint256` word `Bridge.encodeUint256BE` already builds
    (little-endian bytes, reversed).  Defined as that rather than
    re-spelled, so the two encoders cannot drift and the bounded
    injectivity below is the one already proved for it. -/
def natToBytes32BE (n : Nat) : ByteArray :=
  Bridge.encodeUint256BE n

/-- `natToBytes32BE` always produces exactly 32 bytes. -/
theorem natToBytes32BE_size (n : Nat) : (natToBytes32BE n).size = 32 :=
  Bridge.encodeUint256BE_size n

/-- `natToBytes32BE` is injective below the `2^256` word boundary.
    The bound is real rather than decorative: the encoding truncates,
    so `0` and `2^256` share a word. -/
theorem natToBytes32BE_injective (n₁ n₂ : Nat)
    (h₁ : n₁ < 256 ^ 32) (h₂ : n₂ < 256 ^ 32)
    (h : natToBytes32BE n₁ = natToBytes32BE n₂) : n₁ = n₂ :=
  Bridge.encodeUint256BE_injective n₁ n₂ h₁ h₂ h

/-- The packed `(kind, keyA, keyB)` pre-image.  Kept separate from
    `cellKeyPreimage` so the layout can be stated and reasoned about
    without case-splitting the 17-constructor tag, and so the
    Solidity mirror has a named counterpart to point at:

        abi.encodePacked(uint8(kind), uint256(keyA), uint256(keyB)) -/
def cellKeyPreimageOf (kind keyA keyB : Nat) : ByteArray :=
  ByteArray.mk #[UInt8.ofNat (kind % 256)] ++
    natToBytes32BE keyA ++ natToBytes32BE keyB

/-- The packed pre-image is exactly 65 bytes: `1 + 32 + 32`. -/
theorem cellKeyPreimageOf_size (kind keyA keyB : Nat) :
    (cellKeyPreimageOf kind keyA keyB).size = 65 := by
  -- Rewrite the appends first: letting `simp` at the whole term
  -- unfold both 32-element `List.range` maps blows `maxRecDepth`.
  unfold cellKeyPreimageOf
  rw [ByteArray.size_append, ByteArray.size_append,
      natToBytes32BE_size, natToBytes32BE_size]
  simp [ByteArray.size]

/-- The packed pre-image determines `(kind, keyA, keyB)` inside the
    widths it can represent.  The three bounds are the truncation
    boundaries of the layout itself — a kind ≥ 256 aliases mod 256
    and a key ≥ `2^256` aliases mod `2^256` — not incidental
    hypotheses. -/
theorem cellKeyPreimageOf_injective
    (k₁ a₁ b₁ k₂ a₂ b₂ : Nat)
    (hk₁ : k₁ < 256) (hk₂ : k₂ < 256)
    (ha₁ : a₁ < 256 ^ 32) (ha₂ : a₂ < 256 ^ 32)
    (hb₁ : b₁ < 256 ^ 32) (hb₂ : b₂ < 256 ^ 32)
    (h : cellKeyPreimageOf k₁ a₁ b₁ = cellKeyPreimageOf k₂ a₂ b₂) :
    k₁ = k₂ ∧ a₁ = a₂ ∧ b₁ = b₂ := by
  -- The layout is `((kindByte ++ keyA) ++ keyB)`; split it right to
  -- left at the two known widths.
  obtain ⟨h_head, h_b⟩ :=
    byteArray_append_inj_left _ _ _ _ h
      (by rw [ByteArray.size_append, ByteArray.size_append,
        natToBytes32BE_size, natToBytes32BE_size]
          simp [ByteArray.size])
  obtain ⟨h_kind, h_a⟩ :=
    byteArray_append_inj_left _ _ _ _ h_head (by simp [ByteArray.size])
  refine ⟨?_, natToBytes32BE_injective a₁ a₂ ha₁ ha₂ h_a,
    natToBytes32BE_injective b₁ b₂ hb₁ hb₂ h_b⟩
  -- The kind byte round-trips through `UInt8.ofNat` below 256.
  have h_byte : UInt8.ofNat (k₁ % 256) = UInt8.ofNat (k₂ % 256) := by
    have h_arr : (#[UInt8.ofNat (k₁ % 256)] : Array UInt8)
               = #[UInt8.ofNat (k₂ % 256)] := by injection h_kind
    have := congrArg (fun (arr : Array UInt8) => arr[0]?) h_arr
    simpa using this
  have h_nat := congrArg UInt8.toNat h_byte
  simp at h_nat
  omega

/-- The hash pre-image for a cell's SMT key. -/
def cellKeyPreimage (t : CellTag) : ByteArray :=
  let (kind, keyA, keyB) := t.flatKey
  cellKeyPreimageOf kind keyA keyB

/-- The pre-image is exactly 65 bytes, for every tag. -/
theorem cellKeyPreimage_size (t : CellTag) :
    (cellKeyPreimage t).size = 65 := by
  unfold cellKeyPreimage
  exact cellKeyPreimageOf_size _ _ _

/-! ### Tag-level pre-image injectivity

`smtCellKey_injective_under_collision_free` takes pre-image
injectivity as a hypothesis rather than proving it, because the two
`Nat`-typed key spaces (`DepositId`, `WithdrawalId`) are unbounded
while the layout's word is 256 bits.  `CellTag.KeyBounded` is that
side condition, stated once so callers discharge it from the state's
canonical bounds instead of re-deriving it. -/

/-- A cell tag whose key components fit the 256-bit words the
    pre-image layout gives them.  Automatic for every tag keyed by a
    `UInt64`-backed id; a real obligation only for `bridgeConsumed`
    and `bridgePending`, whose ids are `Nat`. -/
def CellTag.KeyBounded (t : CellTag) : Prop :=
  t.keyParts.1 < 256 ^ 32 ∧ t.keyParts.2 < 256 ^ 32

/-- Every kind index is a single byte, so the layout's kind slot
    never truncates. -/
theorem CellTag.kindIndex_lt (t : CellTag) : t.kindIndex < 256 := by
  cases t <;> simp [CellTag.kindIndex]

/-- `(kindIndex, keyA, keyB)` determines the tag.  The kind index
    picks the constructor and the key parts carry its fields, so the
    flat projection loses nothing. -/
theorem CellTag.flatKey_injective (t₁ t₂ : CellTag)
    (h : t₁.flatKey = t₂.flatKey) : t₁ = t₂ := by
  cases t₁ <;> cases t₂ <;>
    simp_all [CellTag.flatKey, CellTag.kindIndex, CellTag.keyParts,
      UInt64.toNat_inj]

/-- Pre-image injectivity for bounded tags: the hypothesis
    `smtCellKey_injective_under_collision_free` asks for, discharged
    rather than assumed. -/
theorem cellKeyPreimage_injective (t₁ t₂ : CellTag)
    (hb₁ : t₁.KeyBounded) (hb₂ : t₂.KeyBounded)
    (h : cellKeyPreimage t₁ = cellKeyPreimage t₂) : t₁ = t₂ := by
  obtain ⟨h_kind, h_a, h_b⟩ :=
    cellKeyPreimageOf_injective _ _ _ _ _ _
      (CellTag.kindIndex_lt t₁) (CellTag.kindIndex_lt t₂)
      hb₁.1 hb₂.1 hb₁.2 hb₂.2 h
  refine CellTag.flatKey_injective t₁ t₂ ?_
  show (t₁.kindIndex, t₁.keyParts.1, t₁.keyParts.2)
     = (t₂.kindIndex, t₂.keyParts.1, t₂.keyParts.2)
  rw [h_kind, h_a, h_b]

/-- The canonical SMT key for a cell.

    `KnomosisStepVM` computes
    `keccak256(abi.encodePacked(uint8(cellKind), uint256(keyA),
    uint256(keyB)))`, which is this function under the production
    keccak256 binding. -/
def smtCellKey (t : CellTag) : ByteArray :=
  LegalKernel.Runtime.hashBytes (cellKeyPreimage t)

/-- The cell key is a 32-byte hash, so it indexes a depth-256 SMT. -/
theorem smtCellKey_size (t : CellTag) : (smtCellKey t).size = 32 :=
  LegalKernel.Runtime.hashBytes_size _

/-- Distinct cells get distinct keys, under collision-freeness on
    the two pre-images involved.

    This is the property that makes an SMT cell proof
    non-replayable: a proof opening `smtCellKey t₁` cannot be
    presented as a proof about `t₂`.  Conditional rather than
    unconditional because the pre-image itself is only injective up
    to the `2^256` truncation of the `Nat` key components — which no
    reachable `DepositId` approaches, but which the statement does
    not get to assume. -/
theorem smtCellKey_injective_under_collision_free
    (t₁ t₂ : CellTag)
    (h_cf : Bridge.CollisionFreeOn
      [cellKeyPreimage t₁, cellKeyPreimage t₂] LegalKernel.Runtime.hashBytes)
    (h_preimage_inj : cellKeyPreimage t₁ = cellKeyPreimage t₂ → t₁ = t₂)
    (h_key : smtCellKey t₁ = smtCellKey t₂) :
    t₁ = t₂ := by
  apply h_preimage_inj
  exact h_cf _ (by simp) _ (by simp) h_key

/-- The key derivation is deterministic. -/
theorem smtCellKey_deterministic (t₁ t₂ : CellTag) (h : t₁ = t₂) :
    smtCellKey t₁ = smtCellKey t₂ := by rw [h]

end FaultProof
end LegalKernel

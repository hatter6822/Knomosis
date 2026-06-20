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

end FaultProof
end LegalKernel

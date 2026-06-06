-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-!
LegalKernel.Bridge.AmmMath — Workstream GP.11.3.

The Lean specification and soundness proof mirroring
`solidity/src/lib/AmmMath.sol`'s `getAmountOut` constant-product
(Uniswap-v2-style) swap formula for the embedded ETH<->BOLD AMM.

A swap fee (in basis points) is RETAINED in the reserves: only
`amountIn * (10000 - feeBps)` participates in the constant-product
curve, while the full `amountIn` is added to the input reserve.  Two
soundness properties are proven over `Nat` (the same arithmetic the
on-chain CHECKED `uint256` realises for any non-overflowing input):

  * `getAmountOut_lt_reserveOut` — the floored output is STRICTLY
    below the output reserve, so a swap can never drain the pool to
    (or past) zero.

  * `k_nondecreasing` — the constant product `reserveIn * reserveOut`
    never decreases across a swap (the retained fee, plus the
    down-flooring, make `k` monotonically non-decreasing).  This is the
    formal basis for the on-chain belt-and-braces `>=` k-check in
    `KnomosisBridge.ammSwap`.

This module is Lean-core only (no Mathlib, no batteries) and carries
no `sorry` and no custom axioms — `#print axioms` on each theorem
returns a subset of the canonical `{propext, Classical.choice,
Quot.sound}`.
-/

namespace LegalKernel.Bridge.AmmMath

/-- Basis-points denominator (100% == 10000 bps).  A `feeBps`
    argument is interpreted as a fraction of this.  Mirrors the
    Solidity `AmmMath.BPS_DENOMINATOR`. -/
def bpsDenominator : Nat := 10000

/-- Constant-product output, net of a `feeBps` fee retained in the
    pool.  Byte-for-byte the `solidity/src/lib/AmmMath.sol`
    `getAmountOut` formula over `Nat`:

      amountInWithFee = amountIn * (10000 - feeBps)
      numerator       = amountInWithFee * reserveOut
      denominator     = reserveIn * 10000 + amountInWithFee
      amountOut       = floor(numerator / denominator) -/
def getAmountOut (amountIn reserveIn reserveOut feeBps : Nat) : Nat :=
  let amountInWithFee := amountIn * (bpsDenominator - feeBps)
  (amountInWithFee * reserveOut) / (reserveIn * bpsDenominator + amountInWithFee)

/-- No-drain: the constant-product output is STRICTLY less than the
    output reserve, so a swap can never drain the pool to (or past)
    zero. -/
theorem getAmountOut_lt_reserveOut
    {amountIn reserveIn reserveOut feeBps : Nat}
    (hIn : 0 < reserveIn) (hOut : 0 < reserveOut) (hFee : feeBps < bpsDenominator) :
    getAmountOut amountIn reserveIn reserveOut feeBps < reserveOut := by
  -- Strategy: `getAmountOut = (aiw * rO) / den` with
  -- `den = rI * BPS + aiw`.  By `Nat.div_lt_of_lt_mul` it suffices to
  -- show `aiw * rO < rO * den`; since `den` carries the strictly
  -- positive `rI * BPS` summand, the inequality is linear once the
  -- product is expanded.
  have hBPS : 0 < bpsDenominator := by unfold bpsDenominator; omega
  -- `hFee` records the Solidity precondition `feeBps < BPS`; the Nat
  -- proof does not need it (a too-large fee truncates `aiw` to `0`,
  -- and the bound still holds), so consume it to keep the binding live.
  have _hFee := hFee
  show (amountIn * (bpsDenominator - feeBps) * reserveOut)
        / (reserveIn * bpsDenominator + amountIn * (bpsDenominator - feeBps)) < reserveOut
  apply Nat.div_lt_of_lt_mul
  -- Goal: aiw * rO < (rI * BPS + aiw) * rO.  Expand the RHS.
  rw [Nat.add_mul]
  have hpos : 0 < reserveIn * bpsDenominator * reserveOut :=
    Nat.mul_pos (Nat.mul_pos hIn hBPS) hOut
  omega

/-- k-monotonicity: the constant product `reserveIn * reserveOut`
    never decreases across a swap (the retained fee makes `k`
    non-decreasing). -/
theorem k_nondecreasing
    {amountIn reserveIn reserveOut feeBps : Nat}
    (hIn : 0 < reserveIn) (hOut : 0 < reserveOut) (hFee : feeBps < bpsDenominator) :
    reserveIn * reserveOut
      ≤ (reserveIn + amountIn)
          * (reserveOut - getAmountOut amountIn reserveIn reserveOut feeBps) := by
  -- Write `ao` for the output, `w = BPS - feeBps`, `aiw = amountIn * w`,
  -- `den = rI * BPS + aiw`.  Two ingredients drive the proof:
  --   * the floor fact `ao * den ≤ aiw * rO` (`Nat.div_mul_le_self`), and
  --   * `ao ≤ rO` (`getAmountOut_lt_reserveOut`).
  -- From these we derive the *core* inequality `rI * ao ≤ aI * (rO - ao)`
  -- by cancelling `aiw * ao`, bounding `w ≤ BPS`, and cancelling `BPS`.
  -- The goal then follows by a linear combination (`omega`) over the
  -- product atoms once `(rI + aI) * (rO - ao)` and `rI * (rO - ao) +
  -- rI * ao = rI * rO` are supplied as equalities.
  have hBPS : 0 < bpsDenominator := by unfold bpsDenominator; omega
  have hle : getAmountOut amountIn reserveIn reserveOut feeBps ≤ reserveOut :=
    Nat.le_of_lt (getAmountOut_lt_reserveOut hIn hOut hFee)
  -- Floor fact, stated on the definitional `getAmountOut` form so that
  -- `Nat.div_mul_le_self` applies after exposing the division.
  have hfloor :
      getAmountOut amountIn reserveIn reserveOut feeBps
        * (reserveIn * bpsDenominator + amountIn * (bpsDenominator - feeBps))
        ≤ amountIn * (bpsDenominator - feeBps) * reserveOut := by
    show (amountIn * (bpsDenominator - feeBps) * reserveOut)
          / (reserveIn * bpsDenominator + amountIn * (bpsDenominator - feeBps))
          * (reserveIn * bpsDenominator + amountIn * (bpsDenominator - feeBps))
          ≤ amountIn * (bpsDenominator - feeBps) * reserveOut
    exact Nat.div_mul_le_self _ _
  have hwle : bpsDenominator - feeBps ≤ bpsDenominator := Nat.sub_le _ _
  -- Generalise the opaque output and the with-fee weight to plain atoms
  -- (`ao`, `w`), turning every remaining step into linear arithmetic
  -- over named products that `omega` treats opaquely.
  generalize hao : getAmountOut amountIn reserveIn reserveOut feeBps = ao at hle hfloor ⊢
  generalize hwdef : bpsDenominator - feeBps = w at hfloor hwle
  -- Core inequality: `reserveIn * ao ≤ amountIn * (reserveOut - ao)`.
  have hcore : reserveIn * ao ≤ amountIn * (reserveOut - ao) := by
    -- Expand the floor-fact LHS and commute the second product.
    have hexp : ao * (reserveIn * bpsDenominator) + amountIn * w * ao
                  ≤ amountIn * w * reserveOut := by
      have h := hfloor
      rw [Nat.mul_add, Nat.mul_comm ao (amountIn * w)] at h
      exact h
    -- `aiw * rO = aiw * (rO - ao) + aiw * ao` (since `ao ≤ rO`).
    have hrhs : amountIn * w * (reserveOut - ao) + amountIn * w * ao
                  = amountIn * w * reserveOut := by
      rw [← Nat.mul_add, Nat.sub_add_cancel hle]
    -- Cancel `aiw * ao`: `ao * (rI * BPS) ≤ aiw * (rO - ao)`.
    have hcancel : ao * (reserveIn * bpsDenominator) ≤ amountIn * w * (reserveOut - ao) := by
      rw [← hrhs] at hexp
      exact Nat.le_of_add_le_add_right hexp
    -- Replace `w` by `BPS` on the right via `w ≤ BPS`.
    have hwbound : amountIn * w * (reserveOut - ao)
                    ≤ amountIn * bpsDenominator * (reserveOut - ao) := by
      apply Nat.mul_le_mul_right
      exact Nat.mul_le_mul_left amountIn hwle
    have hstep : ao * (reserveIn * bpsDenominator)
                  ≤ amountIn * bpsDenominator * (reserveOut - ao) :=
      Nat.le_trans hcancel hwbound
    -- Refactor both sides into `BPS * (·)` and cancel `BPS` (`0 < BPS`).
    have hL : ao * (reserveIn * bpsDenominator) = bpsDenominator * (reserveIn * ao) := by
      rw [Nat.mul_comm reserveIn bpsDenominator, ← Nat.mul_assoc, Nat.mul_comm ao bpsDenominator,
          Nat.mul_assoc, Nat.mul_comm ao reserveIn]
    have hR : amountIn * bpsDenominator * (reserveOut - ao)
                = bpsDenominator * (amountIn * (reserveOut - ao)) := by
      rw [Nat.mul_comm amountIn bpsDenominator, Nat.mul_assoc]
    rw [hL, hR] at hstep
    exact Nat.le_of_mul_le_mul_left hstep hBPS
  -- Final closer: distribute `(rI + aI) * (rO - ao)` and reassemble
  -- `rI * (rO - ao) + rI * ao = rI * rO`, then `omega` over the atoms.
  have hdist : (reserveIn + amountIn) * (reserveOut - ao)
                 = reserveIn * (reserveOut - ao) + amountIn * (reserveOut - ao) := by
    rw [Nat.add_mul]
  have hcombine : reserveIn * (reserveOut - ao) + reserveIn * ao = reserveIn * reserveOut := by
    rw [← Nat.mul_add, Nat.sub_add_cancel hle]
  omega

end LegalKernel.Bridge.AmmMath

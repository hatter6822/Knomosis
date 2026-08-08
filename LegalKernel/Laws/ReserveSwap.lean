-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.ReserveSwap — Workstream SB: the USER-facing L2
constant-product swap (frozen `Action` index 25).

## What this is, against what index 23 is

`Laws.ammSwap` (23) is the bridge-signed BOOKKEEPING MIRROR of an L1
swap: it moves only the reserve actor's balances, by amounts supplied
as action fields, with no user party and no price computed — its own
module says the constant-product property "is enforced operationally
by the L1 contract".  Nothing about it lets an L2 user exchange one
resource for another.

`reserveSwap` is the real thing.  A USER signs it; the price is
computed IN THE KERNEL from the reserve actor's live balances via the
proved `Bridge.AmmMath.getAmountOut` at the fixed
`AmmMath.swapFeeBps`; the user's balance and the reserve's balances
move together, conserving BOTH resources; and the constant-product
safety properties are theorems of this module
(`reserveSwap_no_reserve_drain`, `reserveSwap_k_nondecreasing`) —
delegating `AmmMath.getAmountOut_lt_reserveOut` and
`AmmMath.k_nondecreasing`, which until now had no consumer outside
the fixture generator.

## The four writes, and why the price reads the PRE-state

`apply_impl` prices the swap off the ORIGINAL state's reserve
balances, then performs the four writes in a fixed order (user debit
at `fromResource`, reserve credit at `fromResource`, reserve debit at
`toResource`, user credit at `toResource`), each read chained through
the previous intermediate state.  Pre-state pricing is what makes the
law FAULT-PROOF-ADJUDICABLE: the L1 step-VM verifier holds exactly
the proven pre-values of the opened cells, so a price defined off any
intermediate state would be one it cannot re-derive.

## Fund-safety layering (who can move whose balance)

  * The USER's balance moves only debited-by-`amountIn` /
    credited-by-the-quote, and the deployment `AuthorityPolicy` binds
    `user = signer` for this tag
    (`Bridge.reserveSwapUserBinding`) — a third party cannot name
    someone else as `user`.
  * The RESERVE actor never signs this action (its `LocalPolicy`
    denies every tag but 23, and local policies gate signers); its
    balances move here the way `reclaimAmmReserves` moves them —
    as a counterparty under a law whose shape is proven safe
    (no-drain + k-monotone + conservation).
  * `user ≠ reserveActor` is a precondition: the reserve trading
    against itself is not a swap, and excluding it keeps every
    chained read below unambiguous.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.AmountBound
import LegalKernel.Bridge.AmmMath

namespace LegalKernel
namespace Laws

open LegalKernel.Bridge

/-- The constant-product quote for swapping `amountIn` of
    `fromResource` into `toResource` against `reserveActor`'s LIVE
    balances in `s`, at the fixed `AmmMath.swapFeeBps`.

    Both the precondition and the apply read THIS function, and the
    L1 step-VM kind-25 arm re-derives it from the opened pre-value
    cells — one formula, three consumers. -/
def reserveQuote (s : State) (fromResource toResource : ResourceId)
    (reserveActor : ActorId) (amountIn : Amount) : Amount :=
  AmmMath.getAmountOut amountIn
    (getBalance s fromResource reserveActor)
    (getBalance s toResource reserveActor)
    AmmMath.swapFeeBps

/-- The quote's INTERMEDIATE products stay under the amount head:
    the constant-product numerator
    `amountIn × (10⁴ − fee) × reserveOut` and denominator
    `reserveIn × 10⁴ + amountIn × (10⁴ − fee)` are both below
    `maxAmount = 2^256`.

    A precondition conjunct of `reserveSwap`, in the C-3 discipline:
    Lean computes the quote in `Nat`, where nothing overflows, but
    the L1 step-VM mirror computes it in `uint256`, where a product
    past `2^256` REVERTS — and a revert is not a verdict, it costs
    whoever's turn it is the game by timeout.  Without this conjunct
    a swap with `amountIn` near `2^255` (admissible — balances range
    to `maxAmount`) would be a step Lean admits and the mirror cannot
    execute.  With it, the out-of-domain swap is a NO-OP on both
    stacks: the mirror evaluates these bounds wrap-free (the
    `_planRefundBalances` overflow idiom) and no-ops exactly when
    Lean does.

    Every real economy sits far inside the domain — the bound rejects
    only quotes whose 256-bit intermediate terms genuinely do not
    exist on the mirror. -/
def reserveQuoteDomainBounded (s : State)
    (fromResource toResource : ResourceId)
    (reserveActor : ActorId) (amountIn : Amount) : Prop :=
  amountIn * (AmmMath.bpsDenominator - AmmMath.swapFeeBps)
      * getBalance s toResource reserveActor < maxAmount ∧
  getBalance s fromResource reserveActor * AmmMath.bpsDenominator
      + amountIn * (AmmMath.bpsDenominator - AmmMath.swapFeeBps) < maxAmount

/-- Decidable — two `Nat` comparisons. -/
instance reserveQuoteDomainBounded.decidable (s : State)
    (fromResource toResource : ResourceId)
    (reserveActor : ActorId) (amountIn : Amount) :
    Decidable (reserveQuoteDomainBounded s fromResource toResource
      reserveActor amountIn) := by
  unfold reserveQuoteDomainBounded
  infer_instance

/-- Swap `amountIn` of `fromResource` for the constant-product quote
    of `toResource`, user against reserve.

    * Preconditions:
      - `amountIn > 0` (no zero-input dust probing);
      - `fromResource ≠ toResource`;
      - `user ≠ reserveActor`;
      - the user holds at least `amountIn` at `fromResource`;
      - both reserve legs are live (`> 0` — the quote formula's
        no-drain and k-monotonicity hypotheses);
      - the quote clears `max 1 minAmountOut` (the caller's slippage
        floor, and never a zero output — the Uniswap positive-output
        rule, mirroring the L1 `ZeroSwapOutput` guard);
      - both credits stay under the amount head
        (`AmountBounded`, stated over the same chained intermediate
        states the apply reads);
      - the quote's intermediate products stay under the head too
        (`reserveQuoteDomainBounded` — the C-3 discipline: the
        `uint256` mirror must be able to COMPUTE the quote, not just
        represent its result).
    * Effect: the four chained writes described in the module
      docstring, priced off the pre-state. -/
def reserveSwap (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) : Transition where
  pre := fun s =>
    amountIn > 0 ∧
    fromResource ≠ toResource ∧
    user ≠ reserveActor ∧
    getBalance s fromResource user ≥ amountIn ∧
    -- The minimum-liquidity floor, mirroring the three checks
    -- `KnomosisBridge.ammSwap` makes: both legs at entry, and the
    -- output leg AFTER the quote is deducted.  The third implies the
    -- second (a quote is at least 1), but both are stated so the two
    -- stacks' guards line up one-for-one rather than one being derived
    -- from the other -- a reader comparing them should not have to
    -- reconstruct an implication.
    AmmMath.minimumLiquidity ≤ getBalance s fromResource reserveActor ∧
    AmmMath.minimumLiquidity ≤ getBalance s toResource reserveActor ∧
    AmmMath.minimumLiquidity
      ≤ getBalance s toResource reserveActor
          - reserveQuote s fromResource toResource reserveActor amountIn ∧
    max 1 minAmountOut ≤ reserveQuote s fromResource toResource reserveActor amountIn ∧
    AmountBounded
      (setBalance s fromResource user (getBalance s fromResource user - amountIn))
      fromResource reserveActor amountIn ∧
    AmountBounded
      (setBalance
        (setBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor
          (getBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor + amountIn))
        toResource reserveActor
        (getBalance
          (setBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor
            (getBalance
              (setBalance s fromResource user
                (getBalance s fromResource user - amountIn))
              fromResource reserveActor + amountIn))
          toResource reserveActor
          - reserveQuote s fromResource toResource reserveActor amountIn))
      toResource user (reserveQuote s fromResource toResource reserveActor amountIn) ∧
    reserveQuoteDomainBounded s fromResource toResource reserveActor amountIn
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let out := reserveQuote s fromResource toResource reserveActor amountIn
    let s1 := setBalance s fromResource user
                (getBalance s fromResource user - amountIn)
    let s2 := setBalance s1 fromResource reserveActor
                (getBalance s1 fromResource reserveActor + amountIn)
    let s3 := setBalance s2 toResource reserveActor
                (getBalance s2 toResource reserveActor - out)
    setBalance s3 toResource user (getBalance s3 toResource user + out)

/-- Decidability sanity check: `reserveSwap`'s precondition is
    decidable on every state. -/
example (fromResource toResource : ResourceId) (user : ActorId)
    (amountIn minAmountOut : Amount) (reserveActor : ActorId) (s : State) :
    Decidable ((reserveSwap fromResource toResource user amountIn minAmountOut
      reserveActor).pre s) :=
  inferInstance

/-! ## Safety corollaries (the `AmmMath` theorems, finally consumed) -/

/-- No-drain at the law level: on any state satisfying the
    precondition, the quote is strictly below the reserve's output
    leg — the swap cannot zero the pool. -/
theorem reserveSwap_no_reserve_drain
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    (hpre : (reserveSwap fromResource toResource user amountIn minAmountOut
      reserveActor).pre s) :
    reserveQuote s fromResource toResource reserveActor amountIn
      < getBalance s toResource reserveActor :=
  -- The reserve legs are now floored rather than merely non-zero, so
  -- the positivity these lemmas take is derived from the floor.
  AmmMath.getAmountOut_lt_reserveOut
    (Nat.lt_of_lt_of_le AmmMath.minimumLiquidity_pos hpre.2.2.2.2.1)
    (Nat.lt_of_lt_of_le AmmMath.minimumLiquidity_pos hpre.2.2.2.2.2.1)
    AmmMath.swapFeeBps_lt_bpsDenominator

/-- k-monotonicity at the law level: the reserve pair's constant
    product does not decrease across the swap's reserve legs. -/
theorem reserveSwap_k_nondecreasing
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    (hpre : (reserveSwap fromResource toResource user amountIn minAmountOut
      reserveActor).pre s) :
    getBalance s fromResource reserveActor
        * getBalance s toResource reserveActor
      ≤ (getBalance s fromResource reserveActor + amountIn)
          * (getBalance s toResource reserveActor
              - reserveQuote s fromResource toResource reserveActor amountIn) :=
  AmmMath.k_nondecreasing
    (Nat.lt_of_lt_of_le AmmMath.minimumLiquidity_pos hpre.2.2.2.2.1)
    (Nat.lt_of_lt_of_le AmmMath.minimumLiquidity_pos hpre.2.2.2.2.2.1)
    AmmMath.swapFeeBps_lt_bpsDenominator

/-- The slippage floor is honoured: the quote the user is credited
    clears both `1` and `minAmountOut`. -/
theorem reserveSwap_min_out_honoured
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    (hpre : (reserveSwap fromResource toResource user amountIn minAmountOut
      reserveActor).pre s) :
    minAmountOut ≤ reserveQuote s fromResource toResource reserveActor amountIn ∧
    1 ≤ reserveQuote s fromResource toResource reserveActor amountIn := by
  have h := hpre.2.2.2.2.2.2.2.1
  exact ⟨(Nat.max_le.mp h).2, (Nat.max_le.mp h).1⟩

/-! ## Cross-resource and cross-actor independence -/

/-- `TotalSupply` at `r'` ignores a write at `r ≠ r'`.  The
    state-level hop the four-write chain proofs strip unrelated
    writes with. -/
private theorem totalSupply_setBalance_other
    (s : State) (r r' : ResourceId) (a : ActorId) (v : Amount)
    (h : r ≠ r') :
    TotalSupply (setBalance s r a v) r' = TotalSupply s r' := by
  unfold TotalSupply setBalance
  rw [RBMap.find?_insert_other _ r r' _ h]

/-- The per-resource `BalanceMap` at any `r'` outside the swap pair
    is unchanged (legal or rejected). -/
theorem reserveSwap_other_resource_untouched
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    {r' : ResourceId}
    (h1 : fromResource ≠ r') (h2 : toResource ≠ r') :
    (step_impl s (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor)).balances[r']? = s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor).pre s
  · simp only [if_pos hpre]
    simp only [reserveSwap]
    unfold setBalance
    rw [RBMap.find?_insert_other _ toResource r' _ h2,
        RBMap.find?_insert_other _ toResource r' _ h2,
        RBMap.find?_insert_other _ fromResource r' _ h1,
        RBMap.find?_insert_other _ fromResource r' _ h1]
  · simp only [if_neg hpre]

/-- Per-actor balance preservation at any resource outside the swap
    pair. -/
theorem reserveSwap_does_not_touch_other_resources
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (a : ActorId) (s : State)
    {r' : ResourceId}
    (h1 : fromResource ≠ r') (h2 : toResource ≠ r') :
    getBalance (step_impl s (reserveSwap fromResource toResource user
      amountIn minAmountOut reserveActor)) r' a = getBalance s r' a := by
  unfold getBalance
  rw [reserveSwap_other_resource_untouched fromResource toResource user
    amountIn minAmountOut reserveActor s h1 h2]

/-- An actor that is neither the user nor the reserve is untouched at
    EVERY resource — the third party's balances cannot move. -/
theorem reserveSwap_other_actor_untouched
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    {a : ActorId} (h_u : a ≠ user) (h_r : a ≠ reserveActor)
    (r'' : ResourceId) :
    getBalance (step_impl s (reserveSwap fromResource toResource user
      amountIn minAmountOut reserveActor)) r'' a = getBalance s r'' a := by
  rw [step_impl]
  by_cases hpre : (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor).pre s
  · simp only [if_pos hpre]
    simp only [reserveSwap]
    rw [getBalance_setBalance_other _ toResource r'' user a _
          (Or.inr (Ne.symm h_u)),
        getBalance_setBalance_other _ toResource r'' reserveActor a _
          (Or.inr (Ne.symm h_r)),
        getBalance_setBalance_other _ fromResource r'' reserveActor a _
          (Or.inr (Ne.symm h_r)),
        getBalance_setBalance_other _ fromResource r'' user a _
          (Or.inr (Ne.symm h_u))]
  · simp only [if_neg hpre]

/-! ## Conservation (both resources — a real swap, unlike the
mirror law) -/

/-- The shared debit-then-credit leg arithmetic: two master-lemma
    equations plus the debit bound pin the final supply to the
    initial one. -/
private theorem swap_leg_arithmetic
    (T0 T1 T2 D C amt : Nat)
    (h1 : T1 + D = T0 + (D - amt))
    (h2 : T2 + C = T1 + (C + amt))
    (hbal : amt ≤ D) :
    T2 = T0 := by
  omega

/-- Total supply at `fromResource` is conserved: the user's debit and
    the reserve's credit cancel. -/
theorem reserveSwap_conserves_from
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    (hpre : (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor).pre s) :
    TotalSupply (step_impl s (reserveSwap fromResource toResource user
      amountIn minAmountOut reserveActor)) fromResource =
    TotalSupply s fromResource := by
  have hne : fromResource ≠ toResource := hpre.2.1
  rw [step_impl]
  simp only [if_pos hpre]
  simp only [reserveSwap]
  -- Strip the two `toResource` writes (outermost), leaving the two
  -- `fromResource` writes for the master lemma.
  rw [totalSupply_setBalance_other _ toResource fromResource _ _
        (Ne.symm hne),
      totalSupply_setBalance_other _ toResource fromResource _ _
        (Ne.symm hne)]
  exact swap_leg_arithmetic
    (TotalSupply s fromResource)
    (TotalSupply (setBalance s fromResource user
        (getBalance s fromResource user - amountIn)) fromResource)
    (TotalSupply (setBalance
        (setBalance s fromResource user
          (getBalance s fromResource user - amountIn))
        fromResource reserveActor
        (getBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor + amountIn)) fromResource)
    (getBalance s fromResource user)
    (getBalance (setBalance s fromResource user
        (getBalance s fromResource user - amountIn))
      fromResource reserveActor)
    amountIn
    (totalSupply_setBalance s fromResource user
      (getBalance s fromResource user - amountIn))
    (totalSupply_setBalance
      (setBalance s fromResource user
        (getBalance s fromResource user - amountIn))
      fromResource reserveActor
      (getBalance
        (setBalance s fromResource user
          (getBalance s fromResource user - amountIn))
        fromResource reserveActor + amountIn))
    hpre.2.2.2.1

/-- Total supply at `toResource` is conserved: the reserve's debit
    and the user's credit cancel.  The debit bound is DERIVED — the
    quote is strictly below the reserve's output leg (no-drain), and
    the two `fromResource` writes cannot have moved it. -/
theorem reserveSwap_conserves_to
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) (s : State)
    (hpre : (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor).pre s) :
    TotalSupply (step_impl s (reserveSwap fromResource toResource user
      amountIn minAmountOut reserveActor)) toResource =
    TotalSupply s toResource := by
  have hne : fromResource ≠ toResource := hpre.2.1
  have h_drain := reserveSwap_no_reserve_drain fromResource toResource
    user amountIn minAmountOut reserveActor s hpre
  rw [step_impl]
  simp only [if_pos hpre]
  simp only [reserveSwap]
  -- The reserve's `toResource` balance is untouched by the two
  -- `fromResource` writes, so the quote's no-drain bound transfers
  -- to the chained read the debit performs.
  have h_reads :
      getBalance (setBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor
          (getBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor + amountIn))
        toResource reserveActor
      = getBalance s toResource reserveActor := by
    rw [getBalance_setBalance_other _ fromResource toResource _ _ _
          (Or.inl hne),
        getBalance_setBalance_other _ fromResource toResource _ _ _
          (Or.inl hne)]
  have h_bound :
      reserveQuote s fromResource toResource reserveActor amountIn
      ≤ getBalance (setBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor
          (getBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor + amountIn))
        toResource reserveActor := by
    rw [h_reads]
    exact Nat.le_of_lt h_drain
  -- Strip nothing: both `toResource` writes are the master-lemma
  -- steps; the two inner `fromResource` writes disappear from the
  -- SUPPLY side via the other-resource hop applied to the base of
  -- the chain.
  have h_base :
      TotalSupply (setBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor
          (getBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor + amountIn)) toResource
      = TotalSupply s toResource := by
    rw [totalSupply_setBalance_other _ fromResource toResource _ _ hne,
        totalSupply_setBalance_other _ fromResource toResource _ _ hne]
  have h3 := totalSupply_setBalance
    (setBalance
      (setBalance s fromResource user
        (getBalance s fromResource user - amountIn))
      fromResource reserveActor
      (getBalance
        (setBalance s fromResource user
          (getBalance s fromResource user - amountIn))
        fromResource reserveActor + amountIn))
    toResource reserveActor
    (getBalance (setBalance
        (setBalance s fromResource user
          (getBalance s fromResource user - amountIn))
        fromResource reserveActor
        (getBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor + amountIn))
      toResource reserveActor
      - reserveQuote s fromResource toResource reserveActor amountIn)
  have h4 := totalSupply_setBalance
    (setBalance
      (setBalance
        (setBalance s fromResource user
          (getBalance s fromResource user - amountIn))
        fromResource reserveActor
        (getBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor + amountIn))
      toResource reserveActor
      (getBalance (setBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor
          (getBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor + amountIn))
        toResource reserveActor
        - reserveQuote s fromResource toResource reserveActor amountIn))
    toResource user
    (getBalance (setBalance
        (setBalance
          (setBalance s fromResource user
            (getBalance s fromResource user - amountIn))
          fromResource reserveActor
          (getBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor + amountIn))
        toResource reserveActor
        (getBalance (setBalance
            (setBalance s fromResource user
              (getBalance s fromResource user - amountIn))
            fromResource reserveActor
            (getBalance
              (setBalance s fromResource user
                (getBalance s fromResource user - amountIn))
              fromResource reserveActor + amountIn))
          toResource reserveActor
          - reserveQuote s fromResource toResource reserveActor amountIn))
      toResource user
      + reserveQuote s fromResource toResource reserveActor amountIn)
  -- Master lemma over the debit/credit pair, then rebase to `s` via
  -- the other-resource hops.
  exact (swap_leg_arithmetic _ _ _ _ _ _ h3 h4 h_bound).trans h_base

/-- `reserveSwap` is conservative at EVERY resource — the from-leg
    and to-leg each cancel internally, and no other resource is
    touched. -/
instance reserveSwap_isConservative
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) :
    IsConservative (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor) where
  conserves := by
    intro r' s hpre
    by_cases hf : fromResource = r'
    · subst hf
      exact reserveSwap_conserves_from _ _ _ _ _ _ _ hpre
    · by_cases ht : toResource = r'
      · subst ht
        exact reserveSwap_conserves_to _ _ _ _ _ _ _ hpre
      · unfold TotalSupply
        rw [reserveSwap_other_resource_untouched fromResource toResource
          user amountIn minAmountOut reserveActor s hf ht]

/-! ## Classification instances (§5.3 / LX.3) -/

/-- `reserveSwap` is `LocalTo [fromResource, toResource]`. -/
instance reserveSwap_localTo
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) :
    LocalTo [fromResource, toResource]
      (reserveSwap fromResource toResource user amountIn minAmountOut
        reserveActor) where
  local_to := by
    intro r' a s hr_not_in _
    have h1 : fromResource ≠ r' := by
      intro heq; apply hr_not_in; subst heq; simp
    have h2 : toResource ≠ r' := by
      intro heq; apply hr_not_in; subst heq; simp
    exact reserveSwap_does_not_touch_other_resources fromResource
      toResource user amountIn minAmountOut reserveActor a s h1 h2

/-- `reserveSwap` preserves freeze for any resource set disjoint from
    the swap pair.  A theorem (not an instance) because `S` is not
    inferable from the goal. -/
theorem reserveSwap_freezePreserving
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId)
    (S : List ResourceId) (h1 : fromResource ∉ S) (h2 : toResource ∉ S) :
    FreezePreserving S (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne1 : fromResource ≠ r' := fun heq => h1 (heq ▸ hr')
    have hne2 : toResource ≠ r' := fun heq => h2 (heq ▸ hr')
    rw [reserveSwap_other_resource_untouched fromResource toResource user
      amountIn minAmountOut reserveActor s hne1 hne2]
    exact h_init

/-- Empty-resource-set freeze preservation (vacuous case). -/
instance reserveSwap_freezePreserving_empty
    (fromResource toResource : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount)
    (reserveActor : ActorId) :
    FreezePreserving [] (reserveSwap fromResource toResource user amountIn
      minAmountOut reserveActor) :=
  reserveSwap_freezePreserving fromResource toResource user amountIn
    minAmountOut reserveActor [] (by simp) (by simp)


end Laws
end LegalKernel

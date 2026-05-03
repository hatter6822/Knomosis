/-
LegalKernel.Laws.Mint — non-conservative balance creation.

Phase 2 WU 2.5 / WU 2.6.  Defines the `mint` law (a single-actor
credit at a specified resource) and proves explicitly that it is
*not* `IsConservative`: under any positive `amount` there is a state
on which `mint`'s application strictly increases the per-resource
total supply.

`mint` is the canonical example of a "supply-changing" law and is
the reason the Genesis Plan separates the conservative
(`ConservativeLawSet`) from the unrestricted law-set machinery: a
deployment that admits `mint` cannot rely on the
`total_supply_global` theorem to establish a fixed total supply
across reachable states.

This module is **not** part of the trusted computing base.  It is
imported by `LegalKernel.lean` for re-export to deployments and by
`LegalKernel.Test.Laws.Mint` for runtime spot-checking.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation

namespace LegalKernel
namespace Laws

/-- Mint `amount` units of resource `r` into actor `to`'s balance.

    * Precondition: `amount > 0`.  Mint of zero is a no-op and
      excluded by policy (mirroring the `transfer` precondition shape;
      relaxing this clause is safe but not currently useful).
    * Effect: increases `to`'s balance under `r` by `amount`, leaving
      every other balance untouched.

    `decPre` is inferred: the precondition is a single decidable
    arithmetic comparison over `Nat`. -/
def mint (r : ResourceId) (to : ActorId) (amount : Amount) : Transition where
  pre        := fun _ => amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r to (getBalance s r to + amount)

/-- Sanity decidability witness for `mint`'s precondition. -/
example (r : ResourceId) (to : ActorId) (amount : Amount) (s : State) :
    Decidable ((mint r to amount).pre s) :=
  inferInstance

/-! ## Effect on `TotalSupply` (positive change) -/

/-- Master-lemma corollary specialised to `mint`: the post-mint supply
    at the minted resource exceeds the pre-mint supply by exactly
    `amount`.  Proof: a single `totalSupply_setBalance` instance
    discharges the additive identity once the new balance is
    `getBalance s r to + amount`. -/
theorem totalSupply_after_mint
    (r : ResourceId) (to : ActorId) (amount : Amount) (s : State)
    (hpre : (mint r to amount).pre s) :
    TotalSupply (step_impl s (mint r to amount)) r =
    TotalSupply s r + amount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((mint r to amount).apply_impl s) r =
       TotalSupply s r + amount
  simp only [mint]
  -- Single master-lemma instance.
  have h := totalSupply_setBalance s r to (getBalance s r to + amount)
  -- h : TotalSupply (setBalance s r to (getBalance s r to + amount)) r
  --     + getBalance s r to
  --   = TotalSupply s r + (getBalance s r to + amount)
  -- Goal: TotalSupply (setBalance ...) r = TotalSupply s r + amount
  -- omega closes this because (getBalance s r to) cancels.
  omega

/-! ## Non-conservation (§5.6 / WU 2.6) -/

/-- §5.6 / WU 2.6: `mint` is *not* an `IsConservative` law.  Witness:
    apply `mint r to amount` to the empty `genesisState`; the post-mint
    supply is `amount > 0`, but the pre-mint supply is `0`.
    Conservation would force `0 = amount`, contradicting `amount > 0`.

    Stated as a plain `¬ IsConservative …` rather than as the negation
    of a typeclass instance: the witness drives the `conserves`
    obligation through the explicit application above and reads off the
    `0 + amount = 0` contradiction without typeclass machinery. -/
theorem mint_not_conservative
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (hpos : amount > 0) :
    ¬ IsConservative (mint r to amount) := by
  intro hcons
  -- Apply mint to the genesis state and read off the conservation contradiction.
  have hpre : (mint r to amount).pre genesisState := hpos
  have hcons_r := hcons.conserves r genesisState hpre
  -- Rewrite the LHS via `totalSupply_after_mint` (post-mint = pre + amount)
  -- and the RHS via `totalSupply_genesis_eq_zero` (pre = 0).
  rw [totalSupply_after_mint r to amount genesisState hpre] at hcons_r
  rw [totalSupply_genesis_eq_zero r] at hcons_r
  -- hcons_r should now be `0 + amount = 0`; with `hpos : amount > 0`, contradiction.
  simp at hcons_r
  exact absurd hcons_r (Nat.pos_iff_ne_zero.mp hpos)

end Laws
end LegalKernel

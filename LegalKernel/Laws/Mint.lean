/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

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
import LegalKernel.DSL.LexLaw

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

/-! ## LX-M2 (LX.23) Lex re-expression of `mint`

The hand-written `mint` above is the canonical kernel-level law.
The `lexlaw` declaration below produces a definitionally-equivalent
`def legalkernel_mint_transition` (verified by the regression
`example` underneath), serving as the LX-M2 codegen-input source
of truth for the JSON sidecar at
`LegalKernel/_lex_inputs/legalkernel_mint.json`.

Both forms coexist in this file: the hand-written form is the
canonical kernel-level implementation referenced by all
downstream theorems (`mint_isMonotonic`, etc.); the Lex form is
the same `Transition` value, packaged for the codegen pipeline. -/

set_option linter.missingDocs false in
lexlaw legalkernel_mint where
  lex_id              legalkernel.mint
  lex_version         "1.0.0"
  lex_action_index    1
  lex_intent          "Mint `amount` units of resource `r` into actor `to`'s balance.  Non-conservative by design (Genesis Plan §5.6); classified as `IsMonotonic`."
  lex_signed_by       to
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (to : ActorId) (amount : Amount)
  lex_pre             := fun _ => amount > 0
  lex_impl            :=
    fun s => setBalance s r to (getBalance s r to + amount)
  -- Per plan §19.4 LX.23: `mint` claims `monotonic` (succeeds via
  -- synth_monotonic), `local` (touches only resource `r`),
  -- `freeze_preserving` (other resources untouched),
  -- `nonce_advances` (signed_by `to`), and `registry_preserving`
  -- (no registry mutation).  `conservative` is correctly omitted
  -- (mint is non-conservative by design — `synth_conservative`
  -- would fail L004).
  lex_satisfies       := [monotonic, «local», freeze_preserving,
                          nonce_advances, registry_preserving]
  lex_events          := []

/-- LX-M2 LX.23 byte-equivalence regression: the Lex re-expression
    of `mint` is definitionally equal to the hand-written `Laws.mint`.
    Closes by `rfl`. -/
example (r : ResourceId) (to : ActorId) (amount : Amount) :
    legalkernel_mint_transition r to amount = mint r to amount := rfl

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

/-! ## Cross-resource independence

`mint` only writes at the minted resource `r`, so any other resource
`r' ≠ r` is left untouched at every level: per-actor balance, per
resource `BalanceMap`, and per-resource total supply.  The lemmas
below mirror the Phase-2 additions to `Laws/Transfer.lean`. -/

/-- State-level: the per-resource `BalanceMap` at `r' ≠ r` is unchanged
    by a (legal or rejected) mint at `r`.  Proof: case-split on the
    precondition; in the legal branch, the outer-level
    `s.balances.insert r …` lookup at `r' ≠ r` is invisible. -/
theorem mint_other_resource_untouched
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    (step_impl s (mint r to amount)).balances[r']? =
    s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (mint r to amount).pre s
  · simp only [if_pos hpre]
    show ((mint r to amount).apply_impl s).balances[r']? = s.balances[r']?
    simp only [mint, setBalance]
    rw [RBMap.find?_insert_other _ r r' _ h]
  · simp only [if_neg hpre]

/-- Pointwise per-actor balance preservation at any `r' ≠ r`.  Direct
    consequence of `mint_other_resource_untouched` collapsed at the
    `getBalance` level. -/
theorem mint_does_not_touch_other_resources
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (a : ActorId) (s : State) (h : r ≠ r') :
    getBalance (step_impl s (mint r to amount)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [mint_other_resource_untouched r r' to amount s h]

/-- Conservation at any `r' ≠ r`: mint doesn't touch the per-resource
    map there, so `TotalSupply` reduces to the same fold on both sides. -/
theorem mint_conserves_other_resource
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (s : State) (h : r ≠ r') :
    TotalSupply (step_impl s (mint r to amount)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [mint_other_resource_untouched r r' to amount s h]

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

/-! ## Monotonicity classification (positive-incentive tier) -/

/-- `mint` is monotonic at every resource: the supply at the minted
    resource grows by `amount`, and supply at every other resource is
    untouched.  No `IsConservative` instance exists (witnessed by
    `mint_not_conservative` above), so this instance is what places
    `mint` in the positive-incentive tier. -/
instance mint_isMonotonic
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    IsMonotonic (mint r to amount) where
  monotone := by
    intro r' s hpre
    by_cases hr : r = r'
    · subst hr
      have h := totalSupply_after_mint r to amount s hpre
      omega
    · have h := mint_conserves_other_resource r r' to amount s hr
      omega

/-! ## Workstream LX (LX.3) — `LocalTo` instance + freeze-preservation theorem -/

/-- `mint r …` is `LocalTo [r]`: every resource `r' ≠ r` sees no
    balance change for any actor.  Direct consequence of
    `mint_does_not_touch_other_resources`. -/
instance mint_localTo
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    LocalTo [r] (mint r to amount) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : r ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact mint_does_not_touch_other_resources r r' to amount a s hne

/-- `mint r …` preserves freeze for any resource set `S` not
    containing `r`.  Stated as a theorem (rather than an instance)
    because `S` is a parameter; deployments instantiating
    `FreezePreservingLawSet` for a specific `S` invoke this
    explicitly. -/
theorem mint_freezePreserving
    (r : ResourceId) (to : ActorId) (amount : Amount)
    (S : List ResourceId) (h : r ∉ S) :
    FreezePreserving S (mint r to amount) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ r := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [mint_other_resource_untouched r r' to amount s (Ne.symm hne)]
    exact h_init

/-- Vacuous-case `FreezePreserving []` instance for `mint`. -/
instance mint_freezePreserving_empty
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    FreezePreserving [] (mint r to amount) :=
  mint_freezePreserving r to amount [] (by simp)

end Laws
end LegalKernel

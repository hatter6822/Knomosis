/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Freeze — per-resource immutability marker and
preservation lemmas.

Phase 2 WU 2.9.  Defines `freezeResource r` (an identity-effect law
that records a deployment's commitment to never modify resource `r`
after this transition), the `FrozenForResource` invariant (asserts
that `r`'s per-resource `BalanceMap` matches a fixed snapshot), and
the four preservation lemmas the Genesis Plan acceptance criterion
calls for:

  * `freezeResource` itself preserves the freeze trivially (identity).
  * `transfer r' …` preserves the freeze whenever `r' ≠ r` (the
    "no-op by precondition" clause: a transfer at a *different*
    resource cannot move balances under the frozen one).
  * `mint r' …` preserves the freeze whenever `r' ≠ r`.
  * `burn r' …` preserves the freeze whenever `r' ≠ r`.

The kernel does **not** automatically reject mutating laws at the
frozen resource.  Enforcement is deployment-level: a deployment that
freezes `r` commits to a law set whose mutating laws all carry a
disjointness proof against `r`.  This split mirrors the conservation
discipline (where mint/burn are excluded *by typing* from a
`ConservativeLawSet`); Phase 3's authority layer will add the
runtime check that closes the loop.

This module is **not** part of the trusted computing base.  Like the
mint/burn modules, it is pure deployment-facing infrastructure.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Burn
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

/-- A no-op marker law that records a deployment-level commitment to
    never mutate resource `_r` after this transition.

    Why a no-op?  The kernel's `State` has no "frozen set"; encoding
    the freeze as a runtime check would require either (i) a TCB
    expansion to add such a field, or (ii) per-mutating-law parameters
    that propagate the frozen set through the precondition.  Both are
    invasive.  Instead, the freeze is a *deployment commitment*: by
    including `freezeResource r` in the action log and excluding all
    subsequent mutating laws at `r`, the deployment guarantees the
    `FrozenForResource` invariant by construction.

    The parameter `_r` is part of the API and the action-layer
    encoding (different `r` values mean different `Action.freezeResource`
    constructions), but is **deliberately ignored at the kernel
    level**: `freezeResource 1` and `freezeResource 2` are
    *definitionally equal* `Transition` values (both `pre = True`,
    both `apply_impl = id`).  The underscore prefix communicates this
    irrelevance to readers and silences the unused-variable linter
    without resorting to a syntactic hack like `let _ := r`. -/
def freezeResource (_r : ResourceId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s => s

/-! ## LX-M2 (LX.24) Lex re-expression of `freezeResource` -/

set_option linter.missingDocs false in
lexlaw legalkernel_freezeResource where
  lex_id              legalkernel.freezeResource
  lex_version         "1.0.0"
  lex_action_index    3
  lex_intent          "Mark resource `_r` as frozen.  No-op at the kernel level (Genesis Plan §4.10); deployment commitment to never mutate `_r` after this transition."
  lex_signed_by       deployer
  lex_authorized_by   (fun _ _ => True)
  lex_params          (_r : ResourceId)
  lex_pre             := fun _ => True
  lex_impl            := fun s => s
  -- Per plan §19.4 LX.24: `freezeResource` exercises `LocalTo {}`
  -- (touches no balance cell — empty `local` set since the
  -- transition is identity) and `FreezePreserving [*]` (no
  -- balance change preserves any frozen invariant).  Also
  -- `conservative`, `monotonic`, `nonce_advances`,
  -- `registry_preserving` (all hold for an identity transition).
  -- The `local` claim is parameterised in M3 (`local []` for the
  -- empty set); M2 uses the unparameterised form (synthesizer
  -- skips when impl is identity).
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- LX-M2 LX.24 byte-equivalence regression for `freezeResource`. -/
example (r : ResourceId) :
    legalkernel_freezeResource_transition r = freezeResource r := rfl

/-- Sanity decidability witness for `freezeResource`'s precondition. -/
example (r : ResourceId) (s : State) :
    Decidable ((freezeResource r).pre s) :=
  inferInstance

/-! ## The `FrozenForResource` invariant -/

/-- `FrozenForResource r snap s` ↔ the per-resource `BalanceMap` at
    `r` in state `s` equals the snapshot `snap`.

    A deployment freezes resource `r` by:
    1. Snapshotting `s.balances[r]?` at some state `s_freeze`.
    2. Committing `freezeResource r` to the action log at that point.
    3. Restricting subsequent mutating laws to operate on resources
       *other than* `r` (enforced via the lemmas below).

    The invariant then says: in every reachable state `s'`,
    `s'.balances[r]? = snap`.  Per-actor balances under `r` are
    unchanged from the freeze point; downstream auditors can confirm
    "no balance under `r` has moved" by comparing `s'.balances[r]?`
    to the published snapshot. -/
def FrozenForResource (r : ResourceId) (snap : Option BalanceMap)
    (s : State) : Prop :=
  s.balances[r]? = snap

/-! ## Preservation lemmas (§4.10 / WU 2.9) -/

/-- `freezeResource` preserves the freeze trivially.  The transition
    is identity at the kernel level, so every invariant is preserved
    no matter what; the lemma exists as a deployment-facing API and
    a regression check that the marker stays a no-op.

    Proof: `step_impl s (freezeResource r') = s` by definitional
    reduction (`pre := True` reduces the `if` to the `apply_impl`
    branch, and `apply_impl := fun s => s`), so the goal is
    judgmentally equal to `hI`. -/
theorem freezeResource_preserves_freeze
    (r r' : ResourceId) (snap : Option BalanceMap) (s : State)
    (hI : FrozenForResource r snap s) :
    FrozenForResource r snap (step_impl s (freezeResource r')) :=
  hI

/-! ## Conservation / monotonicity classification (positive-incentive tier) -/

/-- `freezeResource _r` is conservative at every resource: its
    `apply_impl` is identity, so `step_impl s (freezeResource _r)`
    reduces definitionally to `s`, and `TotalSupply` is unchanged.

    This instance was missing in Phase 2 — it was unnecessary for the
    `FrozenForResource` invariant, and its absence had no effect on
    deployments using `ConservativeLawSet` because they didn't include
    `freezeResource` either.  The Phase-4 prelude adds it both for
    completeness and so that deployments combining freeze markers with
    other conservative laws (e.g., `transfer + freezeResource`) can
    inhabit `ConservativeLawSet`. -/
instance freezeResource_isConservative (r : ResourceId) :
    IsConservative (freezeResource r) where
  conserves := fun _r' _s _hpre => rfl

/-- `freezeResource _r` is monotonic at every resource — a direct
    consequence of conservation (the auto-upgrade
    `monotonic_of_conservative` would derive this; we ship the
    explicit instance for stable identifier resolution and clearer
    error messages). -/
instance freezeResource_isMonotonic (r : ResourceId) :
    IsMonotonic (freezeResource r) where
  monotone := fun r' s hpre =>
    Nat.le_of_eq ((freezeResource_isConservative r).conserves r' s hpre).symm

/-- `transfer r' …` preserves the freeze of `r` whenever the
    transferred resource `r'` differs from the frozen `r`.  Direct
    consequence of `transfer_other_resource_untouched` (§4.11.2):
    transfers are local to their resource. -/
theorem transfer_preserves_freeze
    (r r' : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (snap : Option BalanceMap) (s : State)
    (h : r ≠ r') (hI : FrozenForResource r snap s) :
    FrozenForResource r snap
      (step_impl s (transfer r' sender receiver amount)) := by
  unfold FrozenForResource at *
  -- transfer at r' leaves the BalanceMap at r untouched whenever r ≠ r'.
  -- `transfer_other_resource_untouched` is stated with the disjointness
  -- in the form `r' ≠ r` (its first resource is the *transferred* one);
  -- supply the symmetric form with `Ne.symm h`.
  rw [transfer_other_resource_untouched r' r sender receiver amount s
        (Ne.symm h)]
  exact hI

/-- `mint r' …` preserves the freeze of `r` whenever the minted
    resource `r'` differs from the frozen `r`.  Direct consequence of
    `mint_other_resource_untouched`: mint writes only at `r'`. -/
theorem mint_preserves_freeze
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (snap : Option BalanceMap) (s : State)
    (h : r ≠ r') (hI : FrozenForResource r snap s) :
    FrozenForResource r snap (step_impl s (mint r' to amount)) := by
  unfold FrozenForResource at *
  rw [mint_other_resource_untouched r' r to amount s (Ne.symm h)]
  exact hI

/-- `burn r' …` preserves the freeze of `r` whenever the burned
    resource `r'` differs from the frozen `r`.  Symmetric to the mint
    case: burn writes only at `r'`. -/
theorem burn_preserves_freeze
    (r r' : ResourceId) (fromActor : ActorId) (amount : Amount)
    (snap : Option BalanceMap) (s : State)
    (h : r ≠ r') (hI : FrozenForResource r snap s) :
    FrozenForResource r snap (step_impl s (burn r' fromActor amount)) := by
  unfold FrozenForResource at *
  rw [burn_other_resource_untouched r' r fromActor amount s (Ne.symm h)]
  exact hI

/-! ## Workstream LX (LX.3) — `LocalTo` and `FreezePreserving`
    instances + `FrozenForResource` ↔ §10.2 phrasing equivalence

`freezeResource _` is the kernel-level identity transition: its
`apply_impl` is `fun s => s`, so `step_impl s (freezeResource _)`
reduces definitionally to `s`.  Every cell's balance is therefore
unchanged regardless of resource set membership — `LocalTo S` and
`FreezePreserving S` hold for arbitrary `S`. -/

/-- `freezeResource _r` is `LocalTo S` for every resource set `S`:
    the kernel-level `apply_impl` is identity, so `step_impl s
    (freezeResource _r) = s` and `getBalance` reads the same value
    on both sides. -/
instance freezeResource_localTo (r : ResourceId) (S : List ResourceId) :
    LocalTo S (freezeResource r) where
  local_to := fun _ _ _ _ _ => rfl

/-- `freezeResource _r` preserves freeze for every resource set
    `S`: the kernel-level `apply_impl` is identity, so
    `(step_impl s (freezeResource _r)).balances[r']?` reduces to
    `s.balances[r']?` definitionally. -/
instance freezeResource_freezePreserving
    (r : ResourceId) (S : List ResourceId) :
    FreezePreserving S (freezeResource r) where
  preserves := fun _ _ _ _ h_init _ => h_init

/-- The §10.2 typeclass formulation of `FreezePreserving` is
    equivalent to the `FrozenForResource` formulation used by the
    earlier preservation lemmas (`*_preserves_freeze`).  Stated as
    a `theorem` rather than a definitional unfolding because the
    typeclass is on `Transition` (not on a specific law) and the
    iff packages the two-direction equivalence cleanly. -/
theorem freezePreserving_iff_FrozenForResource_preserved
    (S : List ResourceId) (t : Transition) :
    FreezePreserving S t ↔
      ∀ (r : ResourceId), r ∈ S →
      ∀ (snap : Option BalanceMap) (s : State),
        FrozenForResource r snap s →
        t.pre s →
        FrozenForResource r snap (step_impl s t) := by
  unfold FrozenForResource
  constructor
  · intro hfp r hr snap s h_init hpre
    exact hfp.preserves r hr snap s h_init hpre
  · intro h
    exact ⟨h⟩

end Laws
end LegalKernel

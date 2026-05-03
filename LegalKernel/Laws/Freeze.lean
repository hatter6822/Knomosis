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

open Std
open scoped Std.TreeMap

namespace LegalKernel
namespace Laws

/-- A no-op marker law that records a deployment-level commitment to
    never mutate resource `r` after this transition.

    Why a no-op?  The kernel's `State` has no "frozen set"; encoding
    the freeze as a runtime check would require either (i) a TCB
    expansion to add such a field, or (ii) per-mutating-law parameters
    that propagate the frozen set through the precondition.  Both are
    invasive.  Instead, the freeze is a *deployment commitment*: by
    including `freezeResource r` in the action log and excluding all
    subsequent mutating laws at `r`, the deployment guarantees the
    `FrozenForResource` invariant by construction.

    The `r` parameter is logically meaningful (it identifies the
    frozen resource at the action layer) but unused at the kernel
    level.  We satisfy the `linter.unusedVariables` rule by binding
    it to a discarded `let` whose only role is to make the `r`
    binder syntactically used.  -/
def freezeResource (r : ResourceId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    -- `r` is logically meaningful (identifies the frozen resource at
    -- the action layer) but unused at the kernel level.  The `let`
    -- below makes the binder syntactically referenced.
    let _ : ResourceId := r
    s

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
    a regression check that the marker stays a no-op. -/
theorem freezeResource_preserves_freeze
    (r r' : ResourceId) (snap : Option BalanceMap) (s : State)
    (hI : FrozenForResource r snap s) :
    FrozenForResource r snap (step_impl s (freezeResource r')) := by
  unfold FrozenForResource
  rw [step_impl]
  -- The precondition `(freezeResource r').pre s` is `True`; the if
  -- reduces by `if_pos` to `apply_impl s`, which is the identity.
  have hpre : (freezeResource r').pre s := trivial
  simp only [if_pos hpre]
  show (freezeResource r').apply_impl s |>.balances[r]? = snap
  -- After unfolding, `apply_impl s` reduces to `s` (the inner `let`
  -- binding for the `r` parameter is discarded); the lookup is
  -- therefore `s.balances[r]?`, and `hI` closes the goal.
  exact hI

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
    resource `r'` differs from the frozen `r`.  Mint writes only at
    `r'`; the outer-level `s.balances.insert r' …` is invisible to a
    lookup at `r ≠ r'`. -/
theorem mint_preserves_freeze
    (r r' : ResourceId) (to : ActorId) (amount : Amount)
    (snap : Option BalanceMap) (s : State)
    (h : r ≠ r') (hI : FrozenForResource r snap s) :
    FrozenForResource r snap
      (step_impl s (mint r' to amount)) := by
  unfold FrozenForResource at *
  rw [step_impl]
  -- Two cases on the precondition.
  by_cases hpre : (mint r' to amount).pre s
  · simp only [if_pos hpre]
    show ((mint r' to amount).apply_impl s).balances[r]? = snap
    -- mint's apply_impl is `setBalance s r' to (...)`; the outer
    -- insert at `r' ≠ r` is invisible at `r`.
    simp only [mint, setBalance]
    rw [RBMap.find?_insert_other _ r' r _ (Ne.symm h)]
    exact hI
  · simp only [if_neg hpre]
    exact hI

/-- `burn r' …` preserves the freeze of `r` whenever the burned
    resource `r'` differs from the frozen `r`.  Symmetric to the mint
    case: burn writes only at `r'`. -/
theorem burn_preserves_freeze
    (r r' : ResourceId) (fromActor : ActorId) (amount : Amount)
    (snap : Option BalanceMap) (s : State)
    (h : r ≠ r') (hI : FrozenForResource r snap s) :
    FrozenForResource r snap
      (step_impl s (burn r' fromActor amount)) := by
  unfold FrozenForResource at *
  rw [step_impl]
  by_cases hpre : (burn r' fromActor amount).pre s
  · simp only [if_pos hpre]
    show ((burn r' fromActor amount).apply_impl s).balances[r]? = snap
    simp only [burn, setBalance]
    rw [RBMap.find?_insert_other _ r' r _ (Ne.symm h)]
    exact hI
  · simp only [if_neg hpre]
    exact hI

end Laws
end LegalKernel

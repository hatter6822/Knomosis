/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Authority.LocalPolicySemantics — Action-dependent
semantics for the LP.1 LocalPolicy data layer.

Workstream LP — work unit LP.1 (semantics layer).  Defines the
`Action.tag` projection (used by `denyTags`), the per-clause
`permits` semantic predicate plus its `LocalPolicy.permits`
lifting, and named `Decidable` instances for both predicates.

This module is split off from `Authority/LocalPolicy.lean` to
break the circular import: `Authority.Action` (LP.4) needs
`LocalPolicy` (the data type) as a field-type for its
`declareLocalPolicy` constructor, while the semantic predicates
need `Action` to dispatch on.  The data layer lives in
`Authority/LocalPolicy.lean` (no Action dependency); the
semantics layer (this file) imports both.

Coverage map:

  * `Action.tag` — constructor-index projection (15 indices, 0..14
    pre-LP-4; LP.4 will append indices 15..16 for the new ctors).
  * `LocalPolicyClause.permits` — per-clause semantic predicate.
  * `LocalPolicy.permits` — whole-policy lifting (every clause
    must permit).
  * Decidability instances for both predicates.
  * Per-clause semantic theorems (`denyTags_permits_iff`, etc.).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Authority.Action
import LegalKernel.Authority.LocalPolicy

namespace LegalKernel
namespace Authority

/-! ## §3.6 Action tag projection

`Action.tag : Action → Nat` is a one-line projection covering the
existing 15 constructor indices (0..14).  It exists for the
`denyTags` clause's decidability and is independent of the CBE
codec — though both must agree on the indexing.  LP.4 extends
this with the two new ctor indices 15..16.

The mapping below is the *inductive* index — i.e. the order the
constructors are declared in `LegalKernel/Authority/Action.lean`.
The CBE encoder (`LegalKernel/Encoding/Action.lean`) tags each
constructor by the same index, so by inspection the two agree.
LP.4's `tag_matches_encode_tag` discharges the agreement
mechanically. -/

/-- The constructor index of an `Action`, as a `Nat`.  Used by the
    `denyTags` clause to test whether a particular action variant
    is in the deny list.  LP.4 extends this with the two new ctor
    indices 15..16. -/
def Action.tag : Action → Nat
  | .transfer            _ _ _ _ =>  0
  | .mint                _ _ _   =>  1
  | .burn                _ _ _   =>  2
  | .freezeResource      _       =>  3
  | .replaceKey          _ _     =>  4
  | .reward              _ _ _   =>  5
  | .distributeOthers    _ _ _   =>  6
  | .proportionalDilute  _ _ _   =>  7
  | .dispute             _       =>  8
  | .disputeWithdraw     _       =>  9
  | .verdict             _       => 10
  | .rollback            _       => 11
  | .registerIdentity    _ _     => 12
  | .deposit             _ _ _ _ => 13
  | .withdraw            _ _ _ _ => 14
  | .declareLocalPolicy  _       => 15
  | .revokeLocalPolicy           => 16
  | .faultProofChallenge _ _ _ _ => 17
  | .faultProofResolution _ _ _ _ => 18
  | .depositWithFee      _ _ _ _ _ _ _ => 19
  | .topUpActionBudget   _ _ _ _ => 20
  | .topUpActionBudgetFor _ _ _ _ _ => 21

/-! ## §3.4 Per-clause semantic predicate

The `permits` predicate is the propositional form: every branch
reduces to a finite conjunction of Nat or List arithmetic
decidable comparisons, so `Decidable` follows from `inferInstance`.

Vacuity: clauses that don't apply to a particular action variant
are vacuously permissive.  E.g. `requireRecipientIn` has no opinion
on `freezeResource` (no recipient field), so it permits any
freeze; `capAmount` has no opinion on actions without an amount
field. -/

namespace LocalPolicyClause

/-- The semantic permission predicate for a single clause.  Each
    branch reduces to a finite conjunction of Nat or List arithmetic
    decidable comparisons.

    The `_signer` argument is unused in the MVP clause set: every
    current clause makes its decision purely from the `Action`.
    Future clauses may inspect the signer (e.g. `requireSelfSigned`);
    the signature is broad enough to accommodate them without a
    type-level break.  See `Authority/LocalPolicy.lean`'s docstring
    for the rationale on why an `(es : ExtendedState)` argument is
    not in the signature (circular import avoidance). -/
def permits
    (_signer : ActorId) (action : Action)
    : LocalPolicyClause → Prop
  | .denyTags tags          => Action.tag action ∉ tags
  | .requireRecipientIn r a =>
      match action with
      | .transfer  r' _ recipient _      => r' ≠ r ∨ recipient ∈ a
      | .mint      r' to _               => r' ≠ r ∨ to ∈ a
      | .reward    r' to _               => r' ≠ r ∨ to ∈ a
      | .deposit   r' recipient _ _      => r' ≠ r ∨ recipient ∈ a
      | _                                => True
  | .capAmount r max        =>
      match action with
      | .transfer            r' _ _ amt    => r' ≠ r ∨ amt ≤ max
      | .mint                r' _ amt      => r' ≠ r ∨ amt ≤ max
      | .burn                r' _ amt      => r' ≠ r ∨ amt ≤ max
      | .reward              r' _ amt      => r' ≠ r ∨ amt ≤ max
      | .distributeOthers    r' _ amt      => r' ≠ r ∨ amt ≤ max
      | .deposit             r' _ amt _    => r' ≠ r ∨ amt ≤ max
      | .withdraw            r' _ amt _    => r' ≠ r ∨ amt ≤ max
      | _                                  => True
  -- GP.3.4: `allowTopUpFrom` is a *positive* clause consulted at the
  -- admission layer against the RECIPIENT's policy (see
  -- `Authority/SignedAction.lean`'s delegated-top-up consent gate),
  -- not a restrictive clause on the SIGNER's own actions.  As a
  -- signer-scoped restrictive predicate it is therefore vacuously
  -- permissive: a signer's own `allowTopUpFrom` clause never blocks
  -- any of the signer's actions.
  | .allowTopUpFrom _       => True

/-- Decidability of `permits` for a single clause.  Each branch
    reduces to a finite conjunction of decidable comparisons. -/
instance instDecidableLocalPolicyClausePermits
    (signer : ActorId) (action : Action)
    (c : LocalPolicyClause) :
    Decidable (c.permits signer action) := by
  cases c with
  | denyTags tags =>
    show Decidable (Action.tag action ∉ tags)
    exact inferInstance
  | requireRecipientIn r a =>
    show Decidable (LocalPolicyClause.permits signer action
                      (.requireRecipientIn r a))
    unfold LocalPolicyClause.permits
    cases action <;> infer_instance
  | capAmount r max =>
    show Decidable (LocalPolicyClause.permits signer action
                      (.capAmount r max))
    unfold LocalPolicyClause.permits
    cases action <;> infer_instance
  | allowTopUpFrom delegates =>
    show Decidable (LocalPolicyClause.permits signer action
                      (.allowTopUpFrom delegates))
    -- `permits … (.allowTopUpFrom _) = True` for every action.
    unfold LocalPolicyClause.permits
    exact inferInstance

/-! ### Per-clause semantic theorems (§9.1) -/

/-- The `denyTags` clause permits an action iff the action's tag is
    not in the deny list. -/
theorem denyTags_permits_iff
    (signer : ActorId) (action : Action) (tags : List Nat) :
    (LocalPolicyClause.denyTags tags).permits signer action ↔
    Action.tag action ∉ tags := Iff.rfl

/-- The `requireRecipientIn` clause permits a `transfer` iff either
    the resource doesn't match or the recipient is allowed. -/
theorem requireRecipientIn_permits_transfer
    (signer : ActorId)
    (r : ResourceId) (allowed : List ActorId)
    (r' : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (LocalPolicyClause.requireRecipientIn r allowed).permits
        signer (.transfer r' sender receiver amount) ↔
    (r' ≠ r ∨ receiver ∈ allowed) := Iff.rfl

/-- The `requireRecipientIn` clause permits a `freezeResource`
    vacuously (no recipient field). -/
theorem requireRecipientIn_permits_freezeResource
    (signer : ActorId)
    (r : ResourceId) (allowed : List ActorId) (r' : ResourceId) :
    (LocalPolicyClause.requireRecipientIn r allowed).permits
        signer (.freezeResource r') ↔ True := Iff.rfl

/-- The `capAmount` clause permits a `transfer` iff either the
    resource doesn't match or the amount is at most the cap. -/
theorem capAmount_permits_transfer
    (signer : ActorId)
    (r : ResourceId) (max : Amount)
    (r' : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (LocalPolicyClause.capAmount r max).permits
        signer (.transfer r' sender receiver amount) ↔
    (r' ≠ r ∨ amount ≤ max) := Iff.rfl

/-- The `capAmount` clause permits a `freezeResource` vacuously
    (no amount field). -/
theorem capAmount_permits_freezeResource
    (signer : ActorId)
    (r : ResourceId) (max : Amount) (r' : ResourceId) :
    (LocalPolicyClause.capAmount r max).permits
        signer (.freezeResource r') ↔ True := Iff.rfl

/-- The `capAmount` clause permits a `proportionalDilute`
    vacuously (the `totalReward` is a *pool*, not an individual
    amount; capping the pool requires a separate clause variant). -/
theorem capAmount_permits_proportionalDilute
    (signer : ActorId)
    (r : ResourceId) (max : Amount)
    (r' : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    (LocalPolicyClause.capAmount r max).permits
        signer (.proportionalDilute r' excluded totalReward) ↔ True := Iff.rfl

/-- GP.3.4: the positive `allowTopUpFrom` clause is vacuously
    permissive in the signer-scoped restrictive predicate (its
    delegated-top-up consent meaning is enforced separately at the
    admission layer, against the recipient's policy).  It therefore
    never narrows the signer's own admissibility — including for a
    `topUpActionBudgetFor` action the signer issues. -/
theorem allowTopUpFrom_permits_iff
    (signer : ActorId) (action : Action) (delegates : List ActorId) :
    (LocalPolicyClause.allowTopUpFrom delegates).permits signer action ↔ True :=
  Iff.rfl

end LocalPolicyClause

/-! ## §3.4 Whole-policy semantic predicate -/

namespace LocalPolicy

/-- The semantic permission predicate for a whole policy: every
    clause must permit. -/
def permits
    (signer : ActorId) (action : Action) (p : LocalPolicy) : Prop :=
  ∀ c ∈ p.clauses, c.permits signer action

/-- Decidability of `LocalPolicy.permits`.  `∀ c ∈ p.clauses, P c`
    over a finite list with decidable per-element `P`; `Decidable`
    via `List.decidableBAll`. -/
instance instDecidableLocalPolicyPermitsList
    (signer : ActorId) (action : Action) (p : LocalPolicy) :
    Decidable (p.permits signer action) := by
  unfold LocalPolicy.permits
  exact List.decidableBAll _ _

/-! ### Composition theorems (§9.1) -/

/-- The empty policy permits every action.  Vacuous quantification
    over an empty clause list. -/
theorem empty_permits_all
    (signer : ActorId) (action : Action) :
    (LocalPolicy.empty).permits signer action := by
  unfold LocalPolicy.permits LocalPolicy.empty
  intro _ h
  cases h

/-- A policy permits `action` iff every clause permits it.  Direct
    unfolding of the definition; useful as a rewrite target at
    call sites that work with the predicate symbolically. -/
theorem permits_extends_to_clauses
    (signer : ActorId) (action : Action) (p : LocalPolicy) :
    p.permits signer action ↔
    ∀ c ∈ p.clauses, c.permits signer action := Iff.rfl

end LocalPolicy

/-! ## Sanity smoke checks

If any identity below stops elaborating, a refactor of the
semantics layer has broken the contract — caught at build time
without running the tests. -/

/-- Empty policy permits a transfer (vacuous over empty clauses). -/
example : LocalPolicy.empty.permits 1 (.transfer 1 1 2 50) :=
  LocalPolicy.empty_permits_all 1 _

/-- A `denyTags [0]` policy denies a transfer (tag 0). -/
example :
    ¬ ({ clauses := [.denyTags [0]] } : LocalPolicy).permits
        1 (.transfer 1 1 2 50) := by
  intro h
  have hc := h (.denyTags [0]) List.mem_cons_self
  -- hc : Action.tag (.transfer 1 1 2 50) ∉ [0]
  exact hc List.mem_cons_self

/-- A `denyTags [1]` policy permits a transfer (tag 0 ≠ 1). -/
example :
    ({ clauses := [.denyTags [1]] } : LocalPolicy).permits
        1 (.transfer 1 1 2 50) := by
  intro c hc
  rcases List.mem_cons.mp hc with hcc | hcc
  · subst hcc
    show Action.tag (Action.transfer _ _ _ _) ∉ [1]
    decide
  · cases hcc

/-- `Action.tag` agrees with the constructor index for `transfer`. -/
example (r : ResourceId) (s r' : ActorId) (am : Amount) :
    Action.tag (.transfer r s r' am) = 0 := rfl

/-- `Action.tag` agrees with the constructor index for `withdraw`
    (the highest pre-LP index, 14). -/
example (r : ResourceId) (s : ActorId) (am : Amount) (rcp : Bridge.EthAddress) :
    Action.tag (.withdraw r s am rcp) = 14 := rfl

/-- `Action.tag` of `declareLocalPolicy` is 15 (LP.4 frozen index). -/
example (p : LocalPolicy) : Action.tag (.declareLocalPolicy p) = 15 := rfl

/-- `Action.tag` of `revokeLocalPolicy` is 16 (LP.4 frozen index). -/
example : Action.tag .revokeLocalPolicy = 16 := rfl

/-- `Action.tag` of `topUpActionBudgetFor` is 21 (GP.3.4 frozen
    index). -/
example (recipient : ActorId) (gr : ResourceId) (ga : Amount) (bi : Nat)
    (pa : ActorId) :
    Action.tag (.topUpActionBudgetFor recipient gr ga bi pa) = 21 := rfl

end Authority
end LegalKernel

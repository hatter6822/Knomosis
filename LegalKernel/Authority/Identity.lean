/-
LegalKernel.Authority.Identity — Identity, KeyRegistry, and AuthorityPolicy.

Phase 3 WU 3.3.  Defines the registered-identity machinery that
the §8.2 admissibility check consults: who is registered, which
public key they use, and what the deployment's authorization
predicate says about each `(actor, action)` pair.

Design notes (deviations from §8.2 and rationale):

  * The Genesis Plan §8.2 sketch lumps the static `authorized`
    predicate and the dynamic `registry` into a single
    `AuthorityPolicy` structure.  Phase 3 splits them: the
    `AuthorityPolicy` carries the static parts (`authorized`,
    `decAuth`), while the dynamic key registry lives in
    `ExtendedState` (see `Authority/Nonce.lean`) so that the
    `replaceKey` action of WU 3.10 can mutate it through the
    `apply_admissible` path.
  * The `KeyRegistry` is a `TreeMap ActorId PublicKey compare`,
    matching the Genesis-Plan spec's `RBMap ActorId PublicKey
    compare` (renamed for the Lean-core `TreeMap` migration).
  * `AuthorityPolicy.empty` registers nothing and authorises nothing;
    `register`, `revoke`, and `union` are the three combinators
    deployments use to assemble a policy.  `union` uses left-biased
    key collision resolution, matching the Genesis-Plan §8.2 spec.

This module is **not** part of the trusted computing base.  A bug in
`AuthorityPolicy.union` could mis-merge two deployment policies; the
kernel's `apply_admissible` would still refuse any action whose
admissibility check fails, so the worst case is a denial-of-service
or an over-permissive authorisation — both deployment-level concerns.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Action

open Std

namespace LegalKernel
namespace Authority

/-! ## Identities and the key registry -/

/-- A registered identity.  The `key` field is what the deployment's
    `Verify` adaptor checks signatures against.  `Identity` values are
    constructed by deployments at registration time; the kernel never
    inspects them beyond looking up `key` from the registry. -/
structure Identity where
  /-- The actor's opaque identifier (typically a sequence number or a
      hash of their initial public key). -/
  id  : ActorId
  /-- The actor's current public key.  Mutable across the deployment
      lifetime via `replaceKey` (WU 3.10), which produces a new
      `Identity` value with the same `id` and a different `key`. -/
  key : PublicKey
  deriving Repr

/-- A key registry: maps each registered actor's `ActorId` to their
    current `PublicKey`.  Held in `ExtendedState` so that
    `replaceKey` actions can mutate it through the `apply_admissible`
    path (WU 3.10). -/
abbrev KeyRegistry : Type := TreeMap ActorId PublicKey compare

/-- The empty key registry. -/
def KeyRegistry.empty : KeyRegistry := ∅

/-- Register a new actor with their initial public key. -/
def KeyRegistry.register (kr : KeyRegistry) (id : ActorId) (key : PublicKey) :
    KeyRegistry :=
  kr.insert id key

/-- Revoke an actor's registration.  After revocation, the actor's
    nonce in `ExtendedState` is irrelevant: any signed action by them
    will fail admissibility condition 1 (registration check). -/
def KeyRegistry.revoke (kr : KeyRegistry) (id : ActorId) : KeyRegistry :=
  kr.erase id

/-- Look up an actor's registered key.  Returns `none` if the actor
    is not registered. -/
def KeyRegistry.lookup (kr : KeyRegistry) (id : ActorId) : Option PublicKey :=
  kr[id]?

/-! ### KeyRegistry semantic lemmas

The four lemmas below pin down the operational semantics of the
basic registry operations.  They are pure consequences of the §8.3
RBMap insert / erase lemmas, and they are what callers — including
the `apply_admissible` registry-update theorems in
`Authority/SignedAction.lean` — reason about. -/

/-- After registering `id ↦ key`, lookup at `id` returns `some key`. -/
theorem KeyRegistry.lookup_register_self
    (kr : KeyRegistry) (id : ActorId) (key : PublicKey) :
    (kr.register id key).lookup id = some key :=
  RBMap.find?_insert_self kr id key

/-- After registering `id₁ ↦ key`, lookup at `id₂ ≠ id₁` is unchanged. -/
theorem KeyRegistry.lookup_register_other
    (kr : KeyRegistry) (id₁ id₂ : ActorId) (key : PublicKey)
    (h : id₁ ≠ id₂) :
    (kr.register id₁ key).lookup id₂ = kr.lookup id₂ :=
  RBMap.find?_insert_other kr id₁ id₂ key h

/-- After revoking `id`, lookup at `id` returns `none`.  Direct
    consequence of `Std.TreeMap.getElem?_erase_self`. -/
theorem KeyRegistry.lookup_revoke_self
    (kr : KeyRegistry) (id : ActorId) :
    (kr.revoke id).lookup id = none := by
  show (kr.erase id)[id]? = none
  rw [TreeMap.getElem?_erase_self]

/-- After revoking `id₁`, lookup at `id₂ ≠ id₁` is unchanged. -/
theorem KeyRegistry.lookup_revoke_other
    (kr : KeyRegistry) (id₁ id₂ : ActorId) (h : id₁ ≠ id₂) :
    (kr.revoke id₁).lookup id₂ = kr.lookup id₂ := by
  show (kr.erase id₁)[id₂]? = kr[id₂]?
  rw [TreeMap.getElem?_erase]
  have : compare id₁ id₂ ≠ .eq := fun he => h (LawfulEqCmp.eq_of_compare he)
  simp [this]

/-! ### KeyRegistry combinators -/

/-- Left-biased merge of two key registries: on `ActorId` collision,
    the value from `kr₁` wins.  Used by `AuthorityPolicy.union` and
    by deployments that need to combine multiple registries (e.g.,
    federation across shards).

    The Genesis Plan §8.2 spec calls this combinator
    `RBMap.mergeLeftBiased`; Phase 3's name is identical modulo the
    `KeyRegistry` namespace. -/
def KeyRegistry.mergeLeftBiased (kr₁ kr₂ : KeyRegistry) : KeyRegistry :=
  kr₂.foldl (fun acc k v => if acc.contains k then acc else acc.insert k v) kr₁

/-! ## AuthorityPolicy -/

/-- The deployment-supplied authorisation predicate.  `authorized a
    act` is `True` exactly when actor `a` is permitted to issue
    action `act`; the kernel's admissibility check (§8.2 condition 2)
    requires this to hold before any state advance.

    Both fields are state-independent: state-dependent authorisation
    (e.g. "this signer must currently own the resource being moved")
    belongs inside the law's precondition, not here.  This separation
    is what allows the static portion of admissibility to be cached
    across state advances. -/
structure AuthorityPolicy where
  /-- The deployment's authorisation predicate. -/
  authorized : ActorId → Action → Prop
  /-- A per-input decidability witness for `authorized`.  The kernel
      consults this to compute admissibility without classical logic. -/
  decAuth    : (a : ActorId) → (act : Action) → Decidable (authorized a act)

/-- Re-export `decAuth` as a typeclass instance so that
    `decide (P.authorized a act)` elaborates without explicit
    annotations.  The `instance` form costs no runtime bytes; it is a
    pure type-elaboration convenience. -/
instance (P : AuthorityPolicy) (a : ActorId) (act : Action) :
    Decidable (P.authorized a act) :=
  P.decAuth a act

/-! ### AuthorityPolicy operations (WU 3.3) -/

/-- The empty authorisation predicate: nothing is authorised.  Useful
    as the base case for `union`-fold constructions and for tests
    that want to verify "no action is admissible without an explicit
    permit". -/
def AuthorityPolicy.empty : AuthorityPolicy where
  authorized := fun _ _ => False
  decAuth    := fun _ _ => Decidable.isFalse id

/-- The unconditionally-permissive policy: every actor can issue
    every action.  Useful as a sanity baseline in tests, and as the
    starting point for "permit, then revoke" policy constructions. -/
def AuthorityPolicy.unrestricted : AuthorityPolicy where
  authorized := fun _ _ => True
  decAuth    := fun _ _ => Decidable.isTrue trivial

/-- Pointwise union of two authorisation predicates: an action is
    authorised under `union P₁ P₂` iff it's authorised under either
    `P₁` or `P₂`.

    Genesis Plan §8.2 specifies this composition explicitly; it is the
    primary mechanism by which deployments combine multiple
    sub-policies (e.g. "core treasury policy" ∪ "user-issued
    authorisations").  The corresponding registry combinator
    (`KeyRegistry.mergeLeftBiased`) lives separately and is invoked
    by the deployment when it constructs the initial
    `ExtendedState`. -/
def AuthorityPolicy.union (P₁ P₂ : AuthorityPolicy) : AuthorityPolicy where
  authorized := fun a act => P₁.authorized a act ∨ P₂.authorized a act
  decAuth    := fun a act =>
    @instDecidableOr _ _ (P₁.decAuth a act) (P₂.decAuth a act)

/-- Pointwise intersection of two authorisation predicates: an action
    is authorised under `intersect P₁ P₂` iff it's authorised under
    *both* `P₁` and `P₂`.  Less commonly used than `union`; provided
    for completeness so deployments can construct policies of the
    form "the treasury policy AND the time-of-day policy". -/
def AuthorityPolicy.intersect (P₁ P₂ : AuthorityPolicy) : AuthorityPolicy where
  authorized := fun a act => P₁.authorized a act ∧ P₂.authorized a act
  decAuth    := fun a act =>
    @instDecidableAnd _ _ (P₁.decAuth a act) (P₂.decAuth a act)

/-- A policy that authorises a specific `(actor, action)` pair via
    decidable equality.  Useful for "single permit" sub-policies that
    are then composed via `union`. -/
def AuthorityPolicy.singleton (a₀ : ActorId) (act₀ : Action) : AuthorityPolicy where
  authorized := fun a act => a = a₀ ∧ act = act₀
  decAuth    := fun a act =>
    @instDecidableAnd _ _ (decEq a a₀) (decEq act act₀)

/-! ### AuthorityPolicy combinator semantics

Each combinator's `authorized` projection has a closed-form
characterisation.  The lemmas below are the "user-facing" forms call
sites should reach for; the underlying `def`s are mostly invisible
once these are in scope. -/

/-- `empty` rejects every `(actor, action)` pair: `authorized` is
    `False` everywhere. -/
theorem AuthorityPolicy.empty_authorized (a : ActorId) (act : Action) :
    AuthorityPolicy.empty.authorized a act ↔ False := Iff.rfl

/-- `unrestricted` permits every `(actor, action)` pair: `authorized`
    is `True` everywhere. -/
theorem AuthorityPolicy.unrestricted_authorized (a : ActorId) (act : Action) :
    AuthorityPolicy.unrestricted.authorized a act ↔ True := Iff.rfl

/-- `union P₁ P₂` permits exactly the disjunction of the two
    policies' authorisations. -/
theorem AuthorityPolicy.union_authorized
    (P₁ P₂ : AuthorityPolicy) (a : ActorId) (act : Action) :
    (AuthorityPolicy.union P₁ P₂).authorized a act ↔
      P₁.authorized a act ∨ P₂.authorized a act :=
  Iff.rfl

/-- `intersect P₁ P₂` permits exactly the conjunction of the two
    policies' authorisations. -/
theorem AuthorityPolicy.intersect_authorized
    (P₁ P₂ : AuthorityPolicy) (a : ActorId) (act : Action) :
    (AuthorityPolicy.intersect P₁ P₂).authorized a act ↔
      P₁.authorized a act ∧ P₂.authorized a act :=
  Iff.rfl

/-- `singleton a₀ act₀` permits exactly the pair `(a₀, act₀)`. -/
theorem AuthorityPolicy.singleton_authorized
    (a₀ : ActorId) (act₀ : Action) (a : ActorId) (act : Action) :
    (AuthorityPolicy.singleton a₀ act₀).authorized a act ↔
      a = a₀ ∧ act = act₀ :=
  Iff.rfl

/-- `union` is commutative *up to logical equivalence* on the
    authorised predicate.  (Not strict structural equality, because
    the `decAuth` field of `AuthorityPolicy` is implementation-
    specific and may differ between `union P₁ P₂` and `union P₂ P₁`.) -/
theorem AuthorityPolicy.union_comm
    (P₁ P₂ : AuthorityPolicy) (a : ActorId) (act : Action) :
    (AuthorityPolicy.union P₁ P₂).authorized a act ↔
    (AuthorityPolicy.union P₂ P₁).authorized a act := by
  unfold AuthorityPolicy.union
  exact Or.comm

/-- `union` with `empty` on either side is the identity. -/
theorem AuthorityPolicy.union_empty
    (P : AuthorityPolicy) (a : ActorId) (act : Action) :
    (AuthorityPolicy.union P AuthorityPolicy.empty).authorized a act ↔
    P.authorized a act := by
  unfold AuthorityPolicy.union AuthorityPolicy.empty
  simp

/-- `intersect` with `unrestricted` on either side is the identity. -/
theorem AuthorityPolicy.intersect_unrestricted
    (P : AuthorityPolicy) (a : ActorId) (act : Action) :
    (AuthorityPolicy.intersect P AuthorityPolicy.unrestricted).authorized a act ↔
    P.authorized a act := by
  unfold AuthorityPolicy.intersect AuthorityPolicy.unrestricted
  simp

/-! ## Sanity smoke checks -/

example : (AuthorityPolicy.empty).authorized 0 (.transfer 1 2 3 4) ↔ False := Iff.rfl

example : (AuthorityPolicy.unrestricted).authorized 0 (.transfer 1 2 3 4) ↔ True := Iff.rfl

example :
    (AuthorityPolicy.union AuthorityPolicy.empty AuthorityPolicy.unrestricted).authorized
      0 (.mint 1 2 3) ↔ True := by
  unfold AuthorityPolicy.union AuthorityPolicy.empty AuthorityPolicy.unrestricted
  simp

example :
    (AuthorityPolicy.intersect AuthorityPolicy.empty AuthorityPolicy.unrestricted).authorized
      0 (.mint 1 2 3) ↔ False := by
  unfold AuthorityPolicy.intersect AuthorityPolicy.empty AuthorityPolicy.unrestricted
  simp

example :
    (KeyRegistry.empty.register 1 (⟨#[0xAA]⟩ : PublicKey)).lookup 1 =
    some (⟨#[0xAA]⟩ : PublicKey) := by
  unfold KeyRegistry.empty KeyRegistry.register KeyRegistry.lookup
  rw [RBMap.find?_insert_self]

example :
    (KeyRegistry.empty.register 1 (⟨#[0xAA]⟩ : PublicKey)).lookup 2 = none := by
  unfold KeyRegistry.empty KeyRegistry.register KeyRegistry.lookup
  rw [RBMap.find?_insert_other _ 1 2 _ (by decide)]
  simp

end Authority
end LegalKernel

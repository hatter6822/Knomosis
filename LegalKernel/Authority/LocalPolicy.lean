/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Authority.LocalPolicy — actor-scoped local-policy data layer.

Workstream LP — work unit LP.1 (data layer).  Defines the
first-order data layer for per-actor, on-chain, mutable policy
filters: a `LocalPolicyClause` inductive (three restrictive MVP
clause variants plus the GP.3.4 positive `allowTopUpFrom` variant),
a `LocalPolicy` structure (a flat list of clauses, conjunctively
combined), the `LocalPolicies` table (`TreeMap ActorId LocalPolicy`)
that LP.3 embeds in `ExtendedState`, and the bound constants from
§3.0 of the actor-scoped policies plan.

This module deliberately ships *only* the data layer — no
`Action`-dependent semantics.  The semantic predicates
(`LocalPolicyClause.permits`, `Action.tag`,
`LocalPolicy.permits`) live in
`LegalKernel/Authority/LocalPolicySemantics.lean`, which imports
this module plus `Authority.Action`.  This split avoids a circular
import: `Authority.Action` (LP.4) needs `LocalPolicy` as a field
type for its `declareLocalPolicy` constructor, while the semantic
predicates need `Action` to dispatch on.

The user-visible model is intentionally a single sentence:

  "Each actor's outgoing actions are admissible iff (a) the
  deployment's `AuthorityPolicy` permits them, AND (b) the actor's
  declared `LocalPolicy` (if any) permits them.  Policy-management
  actions are exempt from (b)."

This module ships piece (b)'s data; the semantic predicates and
the admissibility-conjunct that consumes them live downstream
(`LocalPolicySemantics.lean` for the predicates, `SignedAction.lean`
for the admissibility-conjunct).

**Append-only constructor discipline.**  The clause inductive
constructor indices are *frozen* (`denyTags` = 0,
`requireRecipientIn` = 1, `capAmount` = 2, `allowTopUpFrom` = 3);
future clause variants must append at the end (index 4, 5, ...) per
the same discipline that governs every other inductive in the
codebase.  Mechanical enforcement: the LP.2 codec's tag-dispatch
table fails the build if a future ctor is inserted out-of-order.

**DoS bounds (single source of truth).**  This module exports four
`Nat` constants capping the size of any single declared policy:

  * `MAX_CLAUSES_PER_POLICY = 64`
  * `MAX_TAGS_PER_DENY = 64`
  * `MAX_RECIPIENTS_PER_REQUIRE = 64`
  * `MAX_POLICY_ENCODE_BYTES = 16_384`

These bounds are enforced at the LP.2 `LocalPolicy.fieldsBounded`
level (the canonical decoder rejects oversize inputs as
`DecodeError.invalidLength`); they are *not* new admissibility
conjuncts.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong policy decisions but cannot violate any
kernel invariant.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas

open Std

namespace LegalKernel
namespace Authority
namespace LocalPolicy

/-! ## §3.0 Bound constants (single source of truth) -/

/-- Maximum number of clauses in a single `LocalPolicy`.  Mirrors
    the Solidity-side `MAX_VERDICT_SIGNERS = 64` discipline:
    every Knomosis list-shaped first-order data type has an explicit
    length cap, enforced by the canonical decoder. -/
def MAX_CLAUSES_PER_POLICY : Nat := 64

/-- Maximum number of tags in a `denyTags` clause's `tags` list. -/
def MAX_TAGS_PER_DENY : Nat := 64

/-- Maximum number of recipients in a `requireRecipientIn`
    clause's `allowed` list. -/
def MAX_RECIPIENTS_PER_REQUIRE : Nat := 64

/-- Maximum number of delegates in an `allowTopUpFrom` clause's
    `delegates` list (Workstream GP / GP.3.4).  Caps the per-clause
    state growth a recipient can authorise; enforced by the LP.2
    canonical decoder exactly as `MAX_RECIPIENTS_PER_REQUIRE` is. -/
def MAX_DELEGATES_PER_ALLOW : Nat := 64

/-- Upper bound on the encoded-byte size of a single declared
    policy.  Holds by construction from
    `MAX_CLAUSES_PER_POLICY * (per-clause max bytes)` plus the
    CBE map / list overhead.  Asserted at the LP.2 encoder level
    by the `LocalPolicy.encode_size_bound` lemma. -/
def MAX_POLICY_ENCODE_BYTES : Nat := 16_384

end LocalPolicy

/-! ## §3.1 The `LocalPolicyClause` inductive (three MVP variants)

Each constructor maps to a decidable predicate
`(signer : ActorId) → (action : Action) → Prop`
with a derivable `Decidable` instance (in `LocalPolicySemantics.lean`).

**Initial-set rationale.**  `denyTags` is the universal escape
hatch: any per-action-type constraint can be expressed as "deny
actions with these constructor tags."  `requireRecipientIn` and
`capAmount` are the two most-requested fine-grained constraints in
chain-governance prior art (Cosmos `authz`, EIP-7702 delegation).

**Restrictive vs. positive clauses (Workstream GP / GP.3.4).**  The
first three variants (`denyTags`, `requireRecipientIn`, `capAmount`)
are *restrictive*: they constrain the signer's own actions, and the
default (no clause) is permissive.  `allowTopUpFrom` is the first
*positive* clause: it grants a permission that is otherwise
default-denied.  A positive clause is consulted at admission time
against the *recipient*'s policy (not the signer's), so it does NOT
participate in `LocalPolicyClause.permits` (the signer-scoped
restrictive predicate treats it as vacuously permissive).  The
delegated-top-up consent gate that reads it lives in the GP.3.2/3.4
admission layer (`Authority/SignedAction.lean`). -/

/-- A single clause in an actor's local policy.  Each clause is a
    first-order data value with decidable semantics; clauses compose
    by *conjunction* inside a `LocalPolicy` (every clause must
    permit the action for the policy to permit it).

    **Append-only constructor discipline.**  Constructor indices are
    frozen at first deployment.  Adding a new clause type means
    appending at the end; reordering is forbidden.  The CBE codec
    tags each clause by its constructor index. -/
inductive LocalPolicyClause
  /-- Deny actions whose Action-constructor tag appears in `tags`.
      Tag indices are the same frozen indices used by
      `Action.encode` (transfer = 0, mint = 1, ...).  An empty
      `tags` list is a no-op (permits everything). -/
  | denyTags          (tags : List Nat)
  /-- For balance-mutating actions on `resource` whose recipient/
      target field is `recipient`, require `recipient ∈ allowed`.
      Applies to `transfer.receiver`, `mint.to`, `reward.to`, and
      `deposit.recipient`.  Other action variants are unaffected. -/
  | requireRecipientIn (resource : ResourceId) (allowed : List ActorId)
  /-- For actions on `resource` whose `amount` field exists,
      require `amount ≤ max`.  Applies to `transfer`, `mint`,
      `burn`, `reward`, `distributeOthers`, `deposit`, `withdraw`.
      Other action variants are unaffected.  `proportionalDilute`
      is treated specially: its `totalReward` is a *pool* not an
      individual amount, so capping it requires a separate clause
      variant (deferred). -/
  | capAmount         (resource : ResourceId) (max : Amount)
  /-- GP.3.4: authorise the actors in `delegates` to credit this
      actor's action-budget via `Action.topUpActionBudgetFor`.  A
      *positive* clause (default-deny): with no `allowTopUpFrom`
      clause an actor accepts no delegated top-ups at all.  The
      consent check (signer ∈ `delegates` for the *recipient*'s
      declared policy) is enforced at the admission layer, not by
      `LocalPolicyClause.permits`. -/
  | allowTopUpFrom     (delegates : List ActorId)
  deriving Repr, DecidableEq

/-! ## §3.2 The `LocalPolicy` structure -/

/-- An actor's local policy: a list of clauses combined by
    conjunction.  An action is permitted iff every clause permits
    it; the empty policy permits everything (vacuous quantification).

    Conjunction-only at the top level keeps the encoding flat and
    avoids recursive ADTs. -/
structure LocalPolicy where
  /-- The list of clauses; conjunctively combined by `permits`. -/
  clauses : List LocalPolicyClause
  deriving Repr, DecidableEq

/-- The empty policy: permits every action by vacuous quantification. -/
def LocalPolicy.empty : LocalPolicy := { clauses := [] }

/-! ## §3.3 The `LocalPolicies` table (carried by `ExtendedState` after LP.3)

The runtime's per-actor policy table: maps registered actors to
their currently-declared local policy.  After LP.3, `ExtendedState`
gains a `localPolicies : LocalPolicies` field so the
`declareLocalPolicy` / `revokeLocalPolicy` actions can mutate it
through the `apply_admissible` path.

Missing entries default to `LocalPolicy.empty` (i.e. no constraint),
so signers with no declaration see no admissibility narrowing. -/

/-- The runtime's per-actor policy table: maps registered actors to
    their currently-declared local policy.  Missing entries default
    to `LocalPolicy.empty`. -/
abbrev LocalPolicies : Type :=
  TreeMap ActorId LocalPolicy compare

/-- The empty policy table: no actor has declared a policy. -/
def LocalPolicies.empty : LocalPolicies := ∅

/-- Look up an actor's declared policy, defaulting to the empty
    (unrestricted) policy if the actor has no declaration. -/
def LocalPolicies.lookup (lp : LocalPolicies) (a : ActorId) : LocalPolicy :=
  lp[a]?.getD LocalPolicy.empty

/-- Declare (or replace) an actor's local policy.  Idempotent on
    equal `policy`; replaces on differing `policy`. -/
def LocalPolicies.declare
    (lp : LocalPolicies) (a : ActorId) (policy : LocalPolicy) : LocalPolicies :=
  lp.insert a policy

/-- Revoke an actor's declaration, restoring the unrestricted
    default. -/
def LocalPolicies.revoke (lp : LocalPolicies) (a : ActorId) : LocalPolicies :=
  lp.erase a

/-! ## §9.1 LocalPolicies look-up lemmas

The look-up lemmas are direct consequences of the §8.3 RBMap
insert / erase lemmas.  They are what callers — including the
`apply_admissible` mutation theorems in `Authority/SignedAction.lean`
(LP.5) — reason about. -/

namespace LocalPolicies

/-- After `declare a policy`, lookup at `a` returns `policy`. -/
theorem lookup_declare_self
    (lp : LocalPolicies) (a : ActorId) (policy : LocalPolicy) :
    (lp.declare a policy).lookup a = policy := by
  unfold LocalPolicies.declare LocalPolicies.lookup
  rw [LegalKernel.RBMap.find?_insert_self lp a policy]
  rfl

/-- After `declare a₁ policy`, lookup at `a₂ ≠ a₁` is unchanged. -/
theorem lookup_declare_other
    (lp : LocalPolicies) (a₁ a₂ : ActorId) (policy : LocalPolicy)
    (h : a₁ ≠ a₂) :
    (lp.declare a₁ policy).lookup a₂ = lp.lookup a₂ := by
  unfold LocalPolicies.declare LocalPolicies.lookup
  rw [LegalKernel.RBMap.find?_insert_other lp a₁ a₂ policy h]

/-- After `revoke a`, lookup at `a` returns `LocalPolicy.empty`
    (the unrestricted default).  Direct consequence of
    `Std.TreeMap.getElem?_erase_self`. -/
theorem lookup_revoke_self
    (lp : LocalPolicies) (a : ActorId) :
    (lp.revoke a).lookup a = LocalPolicy.empty := by
  unfold LocalPolicies.revoke LocalPolicies.lookup
  show (lp.erase a)[a]?.getD LocalPolicy.empty = LocalPolicy.empty
  rw [TreeMap.getElem?_erase_self]
  rfl

/-- After `revoke a₁`, lookup at `a₂ ≠ a₁` is unchanged. -/
theorem lookup_revoke_other
    (lp : LocalPolicies) (a₁ a₂ : ActorId) (h : a₁ ≠ a₂) :
    (lp.revoke a₁).lookup a₂ = lp.lookup a₂ := by
  unfold LocalPolicies.revoke LocalPolicies.lookup
  show (lp.erase a₁)[a₂]?.getD LocalPolicy.empty
    = lp[a₂]?.getD LocalPolicy.empty
  rw [TreeMap.getElem?_erase]
  have : compare a₁ a₂ ≠ .eq := fun he => h (LawfulEqCmp.eq_of_compare he)
  simp [this]

/-- Every actor's lookup in the empty table returns
    `LocalPolicy.empty`. -/
theorem empty_lookup (a : ActorId) :
    LocalPolicies.empty.lookup a = LocalPolicy.empty := by
  unfold LocalPolicies.empty LocalPolicies.lookup
  show (∅ : LocalPolicies)[a]?.getD LocalPolicy.empty = LocalPolicy.empty
  rw [TreeMap.getElem?_emptyc]
  rfl

end LocalPolicies

/-! ## Sanity smoke checks -/

/-- Empty-policy lookup behaviour. -/
example (a : ActorId) : LocalPolicies.empty.lookup a = LocalPolicy.empty :=
  LocalPolicies.empty_lookup a

/-- The empty policy has no clauses. -/
example : LocalPolicy.empty.clauses = [] := rfl

/-- A `denyTags [0]` policy structurally distinguishable from empty. -/
example : ({ clauses := [.denyTags [0]] } : LocalPolicy) ≠ LocalPolicy.empty := by
  intro h
  have := congrArg LocalPolicy.clauses h
  cases this

end Authority
end LegalKernel

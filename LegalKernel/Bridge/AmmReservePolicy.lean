-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.AmmReservePolicy — Workstream GP.11.6.

Declares the canonical `LocalPolicy` that governs the AMM-reserve
actor's (`ammReserveActor`, GP.11.5 / `ActorId 3`) outflow.  The
reserve holds the L2 reflection of the L1 bridge's embedded ETH↔BOLD
AMM liquidity at `ResourceId 0` (ETH) and `ResourceId 1` (BOLD); its
*only* legitimate mutation path is a bridge-attested `ammSwap` action
(frozen Action index 23).

`ammReservePolicy` enforces that discipline as a per-actor
`LocalPolicy` (Workstream LP) consulted by the admission layer
(`Authority/SignedAction.lean`'s `localPolicyPermits` conjunct)
whenever `ammReserveActor` signs an action.  It uses a single clause:

  1. `denyTags ammReserveDeniedTags` — deny every Action constructor
     tag EXCEPT `ammSwap` (tag 23).  Reading the `denyTags` semantics
     in `Authority/LocalPolicySemantics.lean`, a clause `denyTags ts`
     *permits* an action iff its tag is NOT in `ts`; so to allow only
     `ammSwap` we deny every other tag.

No `requireRecipientIn` or `capAmount` clauses are needed because:
  - The L1 contract's `ammSwap` math (GP.11.3) already provides the
    deterministic swap output from reserves + caller's input.
  - The bridge actor (the signer of `ammSwap` actions in production)
    has its own `bridgePolicy` controlling what it may sign.
  - The `ammReserveActor` policy is purely defensive: it ensures that
    even if the AMM reserve actor's key were somehow compromised, the
    actor could not be used to sign non-swap actions.

Combined with `bridgePolicy` (which authorises `bridgeActor` to sign
`ammSwap`), `bridgeAuthorizedAction` (which classifies `ammSwap` as
bridge-authorised), and the `ammReserveAuthorityPolicy` (which closes
the LP.7 meta-action escape hatch), this means `ammReserveActor`'s
balances can only be mutated by a legitimate, L1-attested AMM swap.

**Deny-list maintenance contract (forcing function).**
`ammReserveDeniedTags` is `(List.range 24).filter (· ≠ 23)` =
`[0, 1, …, 22]` — every Action tag except `ammSwap`, covering the
current frozen set (0..23).  This range is a manually-maintained
constant: whenever a NEW Action constructor is appended at index N,
this constant must be bumped to `List.range (N+1)`.  The maintenance
is mechanically enforced by `Action.tag_lt_denyListBound` (already
defined in `GasPoolPolicy.lean`), whose exhaustive `cases action`
proof fails to elaborate the moment an Action constructor whose tag is
`≥ 24` is added; `ammReservePolicy_denies_all_non_ammSwap` consumes
that bound (via `mem_ammReserveDeniedTags_of_tag_ne_ammSwap`), so a
forgotten range bump is a build break rather than a silent reserve-
outflow escalation.

**Two-layer policy discipline (mirrors GP.7.2's `gasPoolPolicy`).**
The `ammReservePolicy` (a `LocalPolicy`) is structurally unable to bar
meta-actions (`declareLocalPolicy` / `revokeLocalPolicy`) due to the
LP.7 exemption, and is sender-blind (cannot distinguish the signer from
the action's `sender` field).  The complementary
`ammReserveAuthorityPolicy` (an `AuthorityPolicy`) closes both gaps: it
bars `ammReserveActor` from signing ANY action except `ammSwap`, with no
meta-action exemption.  Both halves are wired at genesis via the
`ammReserveGenesis` bundle, making the discipline both installable and
irrevocable.

This module is **not** part of the kernel TCB.  A bug here would
weaken the reserve-mutation discipline but cannot violate any kernel
invariant.
-/

import LegalKernel.Bridge.BridgeActor
import LegalKernel.Bridge.GasPoolPolicy
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.LocalPolicy

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority
open LegalKernel.Encoding (Encodable)

/-! ## The deny-list and the canonical policy -/

/-- The Action tags the AMM-reserve actor is forbidden from signing:
    every constructor index EXCEPT `ammSwap` (tag 23).

    `(List.range 24).filter (· ≠ 23) = [0, 1, …, 22]` — the current
    frozen Action set spans indices 0..23, all of which (except `ammSwap`
    = 23) the reserve actor must be forbidden from signing.  See the
    module docstring's maintenance contract: a new constructor at index
    ≥ 24 forces a bump here, caught at build time by
    `ammReservePolicy_denies_all_non_ammSwap`. -/
def ammReserveDeniedTags : List Nat := (List.range 24).filter (· ≠ 23)

/-- The canonical `LocalPolicy` governing `ammReserveActor` outflow.

    A single clause: deny every Action tag except `ammSwap` (tag 23).
    This is the simplest possible "only-this-action" filter — no
    recipient restriction or amount cap because the swap's output is
    deterministic (computed by the L1 contract's constant-product
    formula) and the signing authority is `bridgeActor` (not
    `ammReserveActor` itself in normal operation).

    The policy is a defence-in-depth measure: in production, the
    `ammReserveActor` has no externally-controllable key (it is a
    virtual actor whose balance is mutated only by bridge-attested
    `ammSwap` actions signed by `bridgeActor`).  The policy prevents
    any other action type from being applied in the reserve actor's
    name, even under a hypothetical key-compromise scenario. -/
def ammReservePolicy : LocalPolicy :=
  { clauses := [ .denyTags ammReserveDeniedTags ] }

/-! ## Deny-list membership (the forcing-function lemma) -/

/-- 23 is NOT a member of `ammReserveDeniedTags` — the `ammSwap` tag
    survives the deny-list.  This is the necessary condition for an
    `ammSwap` action to pass the policy. -/
theorem ammSwap_tag_not_mem_ammReserveDeniedTags :
    (23 : Nat) ∉ ammReserveDeniedTags := by
  simp [ammReserveDeniedTags]

/-- Every non-`ammSwap` Action's tag is a member of
    `ammReserveDeniedTags`.  Holds because each current Action tag is
    `< 24` (`Action.tag_lt_denyListBound`) and the deny-list is every
    value in `[0, 24)` except `23`. -/
theorem mem_ammReserveDeniedTags_of_tag_ne_ammSwap
    (action : Action) (h : Action.tag action ≠ 23) :
    Action.tag action ∈ ammReserveDeniedTags := by
  simp only [ammReserveDeniedTags, List.mem_filter, List.mem_range, decide_eq_true_eq]
  exact ⟨Action.tag_lt_denyListBound action, h⟩

/-! ## Core security theorem: only `ammSwap` is permitted -/

/-- **Reserve outflow is `ammSwap`-only.**  For any action whose tag is
    not `23` (i.e. every Action constructor except `ammSwap`),
    `ammReservePolicy` denies it for `ammReserveActor` unconditionally.
    This is the headline GP.11.6 guarantee: the AMM reserve can never
    `transfer`, `mint`, `burn`, `withdraw`, or sign any non-swap
    action — its sole permitted path is a bridge-attested `ammSwap`.

    The `denyTags` clause does the work: `ammReserveDeniedTags`
    contains every non-23 tag
    (`mem_ammReserveDeniedTags_of_tag_ne_ammSwap`), so a non-`ammSwap`
    action fails that clause and hence the whole policy. -/
theorem ammReservePolicy_denies_all_non_ammSwap
    (action : Action) (h : Action.tag action ≠ 23) :
    ¬ ammReservePolicy.permits ammReserveActor action := by
  intro hp
  have hd := hp (.denyTags ammReserveDeniedTags) (by simp [ammReservePolicy])
  exact hd (mem_ammReserveDeniedTags_of_tag_ne_ammSwap action h)

/-- **`ammSwap` is admitted by the policy.**  An `ammSwap` action
    passes the `ammReservePolicy` deny-list (its tag 23 is not in
    `ammReserveDeniedTags`), so the policy permits it for any signer.
    This is the positive half of the characterisation: the reserve's
    sole permitted action type is indeed admitted. -/
theorem ammReservePolicy_permits_ammSwap
    (fr tr : ResourceId) (ai ao : Amount) (ra : ActorId) :
    ammReservePolicy.permits ammReserveActor (.ammSwap fr tr ai ao ra) := by
  intro c hc
  simp [ammReservePolicy] at hc
  subst hc
  exact ammSwap_tag_not_mem_ammReserveDeniedTags

/-- **Complete characterisation of `ammReservePolicy`.**  An action is
    permitted by `ammReservePolicy` for `ammReserveActor` if and only
    if its tag equals `23` (i.e. it is an `ammSwap`).  This is the
    single source-of-truth for the reserve policy's behaviour. -/
theorem ammReservePolicy_permits_iff (action : Action) :
    ammReservePolicy.permits ammReserveActor action ↔
    Action.tag action = 23 := by
  constructor
  · intro hp
    exact Classical.byContradiction fun h =>
      absurd hp (ammReservePolicy_denies_all_non_ammSwap action h)
  · intro heq
    unfold LocalPolicy.permits ammReservePolicy
    intro c hc
    simp at hc
    subst hc
    show Action.tag action ∉ ammReserveDeniedTags
    simp [ammReserveDeniedTags, heq]

/-! ## Admission-layer reach: the LP.7 meta-action escape hatch

Like `gasPoolPolicy`, this `LocalPolicy` is subject to the LP.7
meta-action exemption: `localPolicyPermits` (the admission layer's
check) permits `declareLocalPolicy` / `revokeLocalPolicy` for ANY
signer regardless of the declared policy.  The theorem below documents
this structural limitation — and motivates the complementary
`ammReserveAuthorityPolicy` which closes the hole at the authority
layer. -/

/-- **The LP.7 meta-action exemption operates through `localPolicyPermits`.**
    `ammReserveActor` can — at the real admission layer — sign
    `declareLocalPolicy` / `revokeLocalPolicy` regardless of its declared
    policy, because `localPolicyPermits` is structurally the disjunction
    `isMetaPolicyAction action = true ∨ policy.permits signer action`.
    This is proven through the ACTUAL `Authority.localPolicyPermits`
    definition, not just tag arithmetic.  The hole is closed by
    `ammReserveAuthorityPolicy` (the `AuthorityPolicy` conjunct of
    `AdmissibleWith` has NO meta-action exemption). -/
theorem ammReservePolicy_admission_permits_meta_actions
    (es : ExtendedState)
    (_hpol : es.localPolicies.lookup ammReserveActor = ammReservePolicy) :
    Authority.localPolicyPermits es ammReserveActor .revokeLocalPolicy ∧
    (∀ p, Authority.localPolicyPermits es ammReserveActor
            (.declareLocalPolicy p)) := by
  refine ⟨Or.inl rfl, fun p => Or.inl rfl⟩

/-- **Full admission-layer characterisation.**  Under a declared
    `ammReservePolicy`, `localPolicyPermits` admits `ammReserveActor`
    to sign action `a` iff EITHER the action is a meta-action OR
    `ammReservePolicy.permits` it — i.e. `a` is an `ammSwap` or a
    meta-action.  This is the single source of truth for the
    admission layer's behaviour with respect to the AMM reserve. -/
theorem ammReservePolicy_admission_permits_iff
    (es : ExtendedState) (action : Action)
    (hpol : es.localPolicies.lookup ammReserveActor = ammReservePolicy) :
    Authority.localPolicyPermits es ammReserveActor action ↔
      (Authority.isMetaPolicyAction action = true ∨
        ammReservePolicy.permits ammReserveActor action) := by
  unfold Authority.localPolicyPermits
  rw [hpol]

/-! ## The complementary `AuthorityPolicy`

Mirrors the `gasPoolAuthorityPolicy` pattern (GP.7.2).  The admission
layer's `AdmissibleWith` is a conjunction of an
`AuthorityPolicy.authorized` check AND the meta-exempt
`localPolicyPermits` check; the meta-action exemption relaxes ONLY the
latter.  So an `AuthorityPolicy` that withholds non-`ammSwap` authority
from `ammReserveActor` blocks the escape hatch.

`ammReserveAuthorityPolicy` is designed to be intersected with the
deployment's base policy:

  * For `signer = ammReserveActor`: authorise EXACTLY `ammSwap` — the
    same surface `ammReservePolicy` permits, but now also barring
    meta-actions (which the `LocalPolicy` left open).
  * For `signer ≠ ammReserveActor`: authorise everything (`True`), so
    the intersection is a no-op on every other actor. -/

/-- The authority predicate restricting `ammReserveActor`: it may sign
    EXACTLY an `ammSwap` action whose reserve-actor field (`ra`) is
    `ammReserveActor` itself — so the signed swap can only ever mutate
    the reserve's OWN balances; every other action — including the
    meta-actions the LP.7 exemption would otherwise admit — is
    unauthorised.  Other signers are authorised unconditionally (the
    deployment's base policy governs them after intersection).

    The `ra = ammReserveActor` binding is defence-in-depth (mirrors
    GP.7.2's sender-binding in `gasPoolActorAuthorized`): in production
    the `ammSwap` is always signed by `bridgeActor` (not
    `ammReserveActor`), and `bridgePolicy` is the binding gate.  But
    if `bridgePolicy` were ever relaxed or if the reserve actor key
    were hypothetically compromised, this binding prevents the key
    from signing an `ammSwap` targeting a DIFFERENT actor's balances
    (e.g. `.ammSwap 0 1 100 95 victimActor`). -/
def ammReserveActorAuthorized : ActorId → Action → Prop :=
  fun signer action =>
    if signer = ammReserveActor then
      match action with
      | .ammSwap _ _ _ _ ra => ra = ammReserveActor
      | _ => False
    else True

/-- Decidability of `ammReserveActorAuthorized`. -/
instance ammReserveActorAuthorized_decidable
    (signer : ActorId) (action : Action) :
    Decidable (ammReserveActorAuthorized signer action) := by
  unfold ammReserveActorAuthorized
  by_cases h : signer = ammReserveActor
  · rw [if_pos h]; cases action <;> simp <;> infer_instance
  · rw [if_neg h]; infer_instance

/-- **The complementary `AuthorityPolicy` (closes the meta-action
    hole).**  Intersect this with the deployment's base policy at
    genesis.  It restricts `ammReserveActor` to `ammSwap` only and
    leaves every other actor unconstrained. -/
def ammReserveAuthorityPolicy : AuthorityPolicy where
  authorized := ammReserveActorAuthorized
  decAuth    := fun _ _ => inferInstance

/-- **The authority policy bars `ammReserveActor` meta-actions.**  Closes
    the hole `ammReservePolicy_admission_permits_meta_actions` exposed:
    `ammReserveAuthorityPolicy` does NOT authorise `ammReserveActor` to
    sign `revokeLocalPolicy` or any `declareLocalPolicy`. -/
theorem ammReserveAuthorityPolicy_rejects_meta :
    ¬ ammReserveAuthorityPolicy.authorized ammReserveActor .revokeLocalPolicy ∧
    (∀ p, ¬ ammReserveAuthorityPolicy.authorized ammReserveActor
              (.declareLocalPolicy p)) :=
  ⟨id, fun _ => id⟩

/-- **The authority policy bars every non-`ammSwap` action for
    `ammReserveActor`.**  Any action whose tag is not `23` is
    unauthorised — strictly stronger than the `LocalPolicy`'s deny-list,
    since it also covers the meta-actions. -/
theorem ammReserveAuthorityPolicy_rejects_non_ammSwap
    (action : Action) (h : Action.tag action ≠ 23) :
    ¬ ammReserveAuthorityPolicy.authorized ammReserveActor action := by
  intro hauth
  cases action <;> first | exact absurd rfl h | exact hauth

/-- **The authority policy authorises `ammSwap` targeting the reserve.**
    `ammReserveActor` may sign an `ammSwap` action whose reserve-actor
    field is `ammReserveActor` itself — the sole permitted path.  The
    `ra = ammReserveActor` hypothesis is defence-in-depth (gap #1 fix):
    only swaps that name the correct reserve are authorised. -/
theorem ammReserveAuthorityPolicy_authorizes_ammSwap
    (fr tr : ResourceId) (ai ao : Amount) :
    ammReserveAuthorityPolicy.authorized ammReserveActor
      (.ammSwap fr tr ai ao ammReserveActor) :=
  rfl

/-- **The authority policy bars an `ammSwap` targeting a different actor.**
    Defence-in-depth (mirrors GP.7.2's
    `gasPoolAuthorityPolicy_rejects_non_pool_sender`): an `ammSwap` whose
    reserve-actor field (`ra`) is NOT `ammReserveActor` is rejected, so a
    hypothetically compromised reserve key cannot sign a swap that would
    mutate some OTHER actor's balances. -/
theorem ammReserveAuthorityPolicy_rejects_non_reserve_target
    (fr tr : ResourceId) (ai ao : Amount) (ra : ActorId)
    (h : ra ≠ ammReserveActor) :
    ¬ ammReserveAuthorityPolicy.authorized ammReserveActor
        (.ammSwap fr tr ai ao ra) := by
  intro hauth
  exact h hauth

/-- **Positive extraction: an authorised `ammSwap` targets the reserve.**
    If `ammReserveAuthorityPolicy` authorises an `ammReserveActor`-signed
    `ammSwap`, then the swap's reserve-actor field must be
    `ammReserveActor`.  The positive form suited to downstream consumption
    (e.g. a future per-trace accounting argument). -/
theorem ammReserveAuthorityPolicy_authorized_ammSwap_target
    (fr tr : ResourceId) (ai ao : Amount) (ra : ActorId)
    (hp : ammReserveAuthorityPolicy.authorized ammReserveActor
            (.ammSwap fr tr ai ao ra)) :
    ra = ammReserveActor :=
  hp

/-- **The intersection is a no-op on non-reserve actors.**  For any
    `signer ≠ ammReserveActor`, intersecting `ammReserveAuthorityPolicy`
    into a base policy `P` leaves that signer's authority exactly `P`'s
    — the restriction is scoped solely to `ammReserveActor`. -/
theorem ammReserveAuthorityPolicy_other_actors_unrestricted
    (P : AuthorityPolicy) (signer : ActorId) (action : Action)
    (h : signer ≠ ammReserveActor) :
    (P.intersect ammReserveAuthorityPolicy).authorized signer action ↔
      P.authorized signer action := by
  unfold AuthorityPolicy.intersect ammReserveAuthorityPolicy ammReserveActorAuthorized
  simp only [if_neg h, and_true]

/-- **Genesis-wiring guarantee: meta-actions are barred under the
    intersected policy.**  For ANY base deployment policy `P`,
    `P.intersect ammReserveAuthorityPolicy` rejects
    `ammReserveActor`-signed meta-actions. -/
theorem ammReserveAuthorityPolicy_intersect_rejects_meta
    (P : AuthorityPolicy) :
    ¬ (P.intersect ammReserveAuthorityPolicy).authorized
        ammReserveActor .revokeLocalPolicy ∧
    (∀ p, ¬ (P.intersect ammReserveAuthorityPolicy).authorized
              ammReserveActor (.declareLocalPolicy p)) := by
  refine ⟨?_, fun p => ?_⟩
  · intro ⟨_, hq⟩
    exact ammReserveAuthorityPolicy_rejects_meta.1 hq
  · intro ⟨_, hq⟩
    exact ammReserveAuthorityPolicy_rejects_meta.2 p hq

/-! ## GP.11.6 — Genesis ratification of the AMM-reserve discipline

Mirrors GP.7.4's `gasPoolGenesis` pattern.  The AMM-reserve discipline
is the *conjunction* of two genesis-time declarations:

  1. **The `LocalPolicy` half** — declare `ammReservePolicy` for
     `ammReserveActor` in the genesis `localPolicies` table.
  2. **The `AuthorityPolicy` half** — intersect
     `ammReserveAuthorityPolicy` into the deployment's base policy.

`ammReserveGenesis` bundles them so a deployment cannot wire one
without the other. -/

/-- The state half of the GP.11.6 genesis wiring: declare
    `ammReservePolicy` for `ammReserveActor` in `es`'s per-actor
    local-policy table, leaving every other field untouched. -/
def ammReserveGenesisState (es : ExtendedState) : ExtendedState :=
  { es with localPolicies :=
      es.localPolicies.declare ammReserveActor ammReservePolicy }

/-- The policy half of the GP.11.6 genesis wiring: narrow the
    deployment base policy `P` with `ammReserveAuthorityPolicy` via
    `intersect`. -/
def ammReserveGenesisPolicy (P : AuthorityPolicy) : AuthorityPolicy :=
  P.intersect ammReserveAuthorityPolicy

/-- The GP.11.6 genesis configuration: the genesis `ExtendedState`
    (with `ammReservePolicy` declared for `ammReserveActor`) PAIRED
    with the deployment `AuthorityPolicy` (narrowed by
    `ammReserveAuthorityPolicy`). -/
structure AmmReserveGenesis where
  /-- The genesis extended state with `ammReservePolicy` declared. -/
  state : ExtendedState
  /-- The deployment authority policy narrowed by
      `ammReserveAuthorityPolicy`. -/
  policy : AuthorityPolicy

/-- Construct the GP.11.6 genesis configuration from a base
    `ExtendedState` and a base deployment `AuthorityPolicy`.  Declares
    the reserve `LocalPolicy` AND intersects the reserve
    `AuthorityPolicy` — both halves, atomically. -/
def ammReserveGenesis (base : ExtendedState)
    (deploymentPolicy : AuthorityPolicy) : AmmReserveGenesis :=
  { state  := ammReserveGenesisState base
  , policy := ammReserveGenesisPolicy deploymentPolicy }

/-! ### State-half contract -/

/-- **The reserve `LocalPolicy` is declared at genesis.**  Looking up
    `ammReserveActor`'s declared policy in the genesis state returns
    exactly `ammReservePolicy`. -/
theorem ammReserveGenesisState_declares_policy (es : ExtendedState) :
    (ammReserveGenesisState es).localPolicies.lookup ammReserveActor =
      ammReservePolicy := by
  show (es.localPolicies.declare ammReserveActor ammReservePolicy).lookup ammReserveActor =
    ammReservePolicy
  exact LocalPolicies.lookup_declare_self es.localPolicies ammReserveActor ammReservePolicy

/-- **The genesis wiring touches no other actor's `LocalPolicy`.** -/
theorem ammReserveGenesisState_preserves_other_localPolicies
    (es : ExtendedState) (a : ActorId) (h : ammReserveActor ≠ a) :
    (ammReserveGenesisState es).localPolicies.lookup a =
      es.localPolicies.lookup a := by
  show (es.localPolicies.declare ammReserveActor ammReservePolicy).lookup a =
    es.localPolicies.lookup a
  exact LocalPolicies.lookup_declare_other es.localPolicies ammReserveActor a
    ammReservePolicy h

/-- **The genesis wiring is surgical: only `localPolicies` changes.** -/
theorem ammReserveGenesisState_preserves_kernel_substates
    (es : ExtendedState) :
    (ammReserveGenesisState es).base = es.base ∧
    (ammReserveGenesisState es).registry = es.registry ∧
    (ammReserveGenesisState es).nonces = es.nonces ∧
    (ammReserveGenesisState es).bridge = es.bridge ∧
    (ammReserveGenesisState es).epochBudgets = es.epochBudgets ∧
    (ammReserveGenesisState es).budgetPolicy = es.budgetPolicy :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

/-! ### Policy-half contract -/

/-- **GP.11.6 headline: meta-actions are barred under the genesis
    policy.**  Regardless of the base deployment policy `P`, the
    genesis-wired `AuthorityPolicy` rejects `ammReserveActor`-signed
    meta-actions. -/
theorem ammReserveGenesisPolicy_rejects_meta (P : AuthorityPolicy) :
    ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor .revokeLocalPolicy ∧
    (∀ p, ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
              (.declareLocalPolicy p)) := by
  unfold ammReserveGenesisPolicy
  exact ammReserveAuthorityPolicy_intersect_rejects_meta P

/-- **The genesis wiring narrows ONLY `ammReserveActor`.**  Every other
    signer's authority under the genesis policy is exactly the base
    deployment policy's. -/
theorem ammReserveGenesisPolicy_other_actors_unrestricted
    (P : AuthorityPolicy) (signer : ActorId) (action : Action)
    (h : signer ≠ ammReserveActor) :
    (ammReserveGenesisPolicy P).authorized signer action ↔
      P.authorized signer action := by
  unfold ammReserveGenesisPolicy
  exact ammReserveAuthorityPolicy_other_actors_unrestricted P signer action h

/-- **The genesis policy bars every non-`ammSwap` reserve action.** -/
theorem ammReserveGenesisPolicy_rejects_non_ammSwap
    (P : AuthorityPolicy) (action : Action) (h : Action.tag action ≠ 23) :
    ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor action := by
  unfold ammReserveGenesisPolicy
  intro hauth
  exact ammReserveAuthorityPolicy_rejects_non_ammSwap action h hauth.2

/-- **The legitimate `ammSwap` targeting the reserve is still admitted
    under the genesis policy** (given the base policy permits it). -/
theorem ammReserveGenesisPolicy_authorizes_ammSwap
    (P : AuthorityPolicy)
    (fr tr : ResourceId) (ai ao : Amount)
    (hP : P.authorized ammReserveActor (.ammSwap fr tr ai ao ammReserveActor)) :
    (ammReserveGenesisPolicy P).authorized ammReserveActor
      (.ammSwap fr tr ai ao ammReserveActor) := by
  unfold ammReserveGenesisPolicy
  exact ⟨hP, ammReserveAuthorityPolicy_authorizes_ammSwap fr tr ai ao⟩

/-- **Fund safety: the genesis policy bars an `ammSwap` targeting a
    different actor.**  A held `ammReserveActor` key may only sign swaps
    that mutate the RESERVE's own balances — a swap whose reserve-actor
    field `ra ≠ ammReserveActor` is unauthorised. -/
theorem ammReserveGenesisPolicy_rejects_non_reserve_target
    (P : AuthorityPolicy)
    (fr tr : ResourceId) (ai ao : Amount) (ra : ActorId)
    (h : ra ≠ ammReserveActor) :
    ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
        (.ammSwap fr tr ai ao ra) := by
  unfold ammReserveGenesisPolicy
  intro hauth
  exact ammReserveAuthorityPolicy_rejects_non_reserve_target
    fr tr ai ao ra h hauth.2

/-! ### Bundle wiring -/

/-- **The bundle wires both halves.** -/
theorem ammReserveGenesis_wires_both_halves
    (base : ExtendedState) (P : AuthorityPolicy) :
    (ammReserveGenesis base P).state = ammReserveGenesisState base ∧
    (ammReserveGenesis base P).policy = ammReserveGenesisPolicy P :=
  ⟨rfl, rfl⟩

/-- **The reserve actor cannot self-install (or replace) its policy —
    structural genesis is mandatory.**  Under the genesis policy,
    `ammReserveActor` is barred from signing `declareLocalPolicy p` for
    EVERY `p`. -/
theorem ammReserveGenesisPolicy_bars_self_declaration
    (P : AuthorityPolicy) (p : LocalPolicy) :
    ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
        (.declareLocalPolicy p) :=
  (ammReserveGenesisPolicy_rejects_meta P).2 p

/-! ### Composition with gasPoolGenesis

A deployment typically wires BOTH `gasPoolGenesis` and
`ammReserveGenesis`.  The two intersections compose cleanly because
they restrict DIFFERENT actors (`gasPoolActor ≠ ammReserveActor`,
proven by `ammReserveActor_ne_gasPoolActor`).  The theorem below
confirms that neither genesis hook interferes with the other. -/

/-- **The AMM-reserve genesis does not affect `gasPoolActor`'s
    authority.**  `ammReserveGenesisPolicy P` admits exactly the same
    actions for `gasPoolActor` as `P` does (the AMM restriction is
    scoped to `ammReserveActor` only). -/
theorem ammReserveGenesisPolicy_preserves_gasPool_authority
    (P : AuthorityPolicy) (action : Action) :
    (ammReserveGenesisPolicy P).authorized gasPoolActor action ↔
      P.authorized gasPoolActor action := by
  exact ammReserveAuthorityPolicy_other_actors_unrestricted P gasPoolActor action
    (Ne.symm ammReserveActor_ne_gasPoolActor)

/-- **The AMM-reserve genesis does not affect `gasPoolActor`'s declared
    `LocalPolicy`.**  The `localPolicies` table entry for
    `gasPoolActor` is unchanged by `ammReserveGenesisState`. -/
theorem ammReserveGenesisState_preserves_gasPool_localPolicy
    (es : ExtendedState) :
    (ammReserveGenesisState es).localPolicies.lookup gasPoolActor =
      es.localPolicies.lookup gasPoolActor := by
  exact ammReserveGenesisState_preserves_other_localPolicies es gasPoolActor
    ammReserveActor_ne_gasPoolActor

/-! ### CBE encoding prerequisites (GP.7.4 genesis-persistence pattern) -/

/-- **`ammReservePolicy` satisfies the CBE encoding bounds.**  The
    single-clause policy uses only `denyTags` with 23 entries (all
    values < 24 < 2^64), well within the §3.0 field limits.  This
    is the prerequisite for the round-trip theorem below. -/
theorem ammReservePolicy_fieldsBounded :
    Encoding.LocalPolicy.fieldsBounded ammReservePolicy := by
  unfold Encoding.LocalPolicy.fieldsBounded ammReservePolicy
  simp only [List.length_cons, List.length_nil, Nat.zero_add]
  refine ⟨by decide, ?_⟩
  simp only [List.all_cons, List.all_nil, Bool.and_true,
    decide_eq_true_eq,
    Encoding.LocalPolicyClause.fieldsBounded]
  refine ⟨by decide, ?_⟩
  apply List.all_eq_true.mpr
  intro n hn
  have hlt : n < 24 := by
    have := List.mem_filter.mp hn |>.1
    simpa using List.mem_range.mp this
  exact decide_eq_true (by omega)

/-- **CBE round-trip for `ammReservePolicy`.**  Encoding then
    decoding yields exactly the original policy with no remainder
    — the policy can be persisted and reconstructed losslessly. -/
theorem ammReservePolicy_roundtrip :
    Encodable.decode (T := LocalPolicy) (Encodable.encode ammReservePolicy) =
      .ok (ammReservePolicy, []) :=
  Encoding.localPolicy_roundtrip_empty ammReservePolicy ammReservePolicy_fieldsBounded

/-! ### Reverse composition: gasPoolGenesis preserves the AMM-reserve discipline

A deployment wiring BOTH disciplines sequentially (first AMM reserve, then gas
pool — or vice versa) does not interfere.  The gas-pool genesis restricts only
`gasPoolActor`, so `ammReserveActor`'s `LocalPolicy` and authority survive. -/

/-- **The gas-pool genesis state preserves `ammReserveActor`'s declared
    `LocalPolicy`.**  `gasPoolGenesisState` writes only `gasPoolActor`'s
    entry; `ammReserveActor`'s is untouched. -/
theorem gasPoolGenesisState_preserves_ammReserve_localPolicy
    (es : ExtendedState) (mEth mBold : Amount) :
    (gasPoolGenesisState es mEth mBold).localPolicies.lookup ammReserveActor =
      es.localPolicies.lookup ammReserveActor :=
  gasPoolGenesisState_preserves_other_localPolicies es mEth mBold ammReserveActor
    (Ne.symm ammReserveActor_ne_gasPoolActor)

/-- **The gas-pool genesis policy preserves `ammReserveActor`'s authority.**
    `gasPoolGenesisPolicy P` restricts only `gasPoolActor`; an
    `ammReserveActor`-signed action is authorised iff `P` authorises it. -/
theorem gasPoolGenesisPolicy_preserves_ammReserve_authority
    (P : AuthorityPolicy) (mEth mBold : Amount) (action : Action) :
    (gasPoolGenesisPolicy P mEth mBold).authorized ammReserveActor action ↔
      P.authorized ammReserveActor action :=
  gasPoolAuthorityPolicy_other_actors_unrestricted mEth mBold P ammReserveActor action
    ammReserveActor_ne_gasPoolActor

/-! ### Option-gated configuration (mirrors GP.7.4's `GasPoolConfig` pattern)

The AMM-reserve discipline has no per-deployment parameters (unlike the
gas-pool policy which carries two per-leg caps), but the genesis wiring
still benefits from an `Option`-gated builder so that the runtime can
branch on "this deployment enables the AMM" vs "no AMM".  The config
structure is intentionally empty (ready for future parameters such as
an AMM-specific outflow cap); the opt-in signal is `some ()` vs `none`. -/

/-- A deployment's opt-in AMM-reserve configuration.  Empty today because
    the policy is parameterless; the `Option` wrapper communicates the
    binary "enable / disable" decision to the genesis hooks. -/
structure AmmReserveConfig where
  deriving Repr, DecidableEq

/-- The state half, gated on an `Option AmmReserveConfig`: declare
    `ammReservePolicy` for `ammReserveActor` when the deployment opts in
    (`some _`), else leave `es` untouched (`none`). -/
def ammReserveGenesisStateOfConfig (es : ExtendedState) :
    Option AmmReserveConfig → ExtendedState
  | none   => es
  | some _ => ammReserveGenesisState es

/-- The policy half, gated on an `Option AmmReserveConfig`: intersect
    `ammReserveAuthorityPolicy` into `P` when the deployment opts in, else
    return `P` unchanged. -/
def ammReserveGenesisPolicyOfConfig (P : AuthorityPolicy) :
    Option AmmReserveConfig → AuthorityPolicy
  | none   => P
  | some _ => ammReserveGenesisPolicy P

/-- The bundled genesis, gated on an `Option AmmReserveConfig`.  `none`
    yields `⟨base, P⟩`; `some _` yields the fully-wired
    `ammReserveGenesis`. -/
def ammReserveGenesisOfConfig (base : ExtendedState) (P : AuthorityPolicy)
    (cfg : Option AmmReserveConfig) : AmmReserveGenesis :=
  { state  := ammReserveGenesisStateOfConfig base cfg
  , policy := ammReserveGenesisPolicyOfConfig P cfg }

/-- **Opt-out is a no-op on the state.**  A deployment that supplies no
    AMM-reserve config gets its base genesis verbatim. -/
@[simp] theorem ammReserveGenesisStateOfConfig_none (es : ExtendedState) :
    ammReserveGenesisStateOfConfig es none = es := rfl

/-- **Opt-out is a no-op on the policy.** -/
@[simp] theorem ammReserveGenesisPolicyOfConfig_none (P : AuthorityPolicy) :
    ammReserveGenesisPolicyOfConfig P none = P := rfl

/-- **Opt-in declares the reserve policy.**  Given a config, the genesis
    state declares `ammReservePolicy` for `ammReserveActor`. -/
theorem ammReserveGenesisStateOfConfig_some_declares_policy
    (es : ExtendedState) (cfg : AmmReserveConfig) :
    (ammReserveGenesisStateOfConfig es (some cfg)).localPolicies.lookup
        ammReserveActor =
      ammReservePolicy :=
  ammReserveGenesisState_declares_policy es

/-- **Opt-in bars reserve meta-actions.**  Given a config, the genesis
    policy bars `ammReserveActor` from `revokeLocalPolicy` /
    `declareLocalPolicy` (the LP.7 hole stays closed end-to-end). -/
theorem ammReserveGenesisPolicyOfConfig_some_rejects_meta
    (P : AuthorityPolicy) (cfg : AmmReserveConfig) :
    ¬ (ammReserveGenesisPolicyOfConfig P (some cfg)).authorized ammReserveActor
        .revokeLocalPolicy ∧
    (∀ p, ¬ (ammReserveGenesisPolicyOfConfig P (some cfg)).authorized ammReserveActor
              (.declareLocalPolicy p)) :=
  ammReserveGenesisPolicy_rejects_meta P

end Bridge
end LegalKernel

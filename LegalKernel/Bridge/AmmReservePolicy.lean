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
actor's (`ammReserveActor`, GP.11.5 / `ActorId 3`) outflow.  Under
the one-AMM L2-primary topology the reserve is the LIVE pool the
user-facing `Laws.reserveSwap` (frozen Action index 25) trades
against, funded by the deposit fee-split's seed leg.  Its balances
move ONLY as a counterparty: debited/credited by user-signed
`reserveSwap` actions (the user signs, never the reserve) and swept
by the bridge-signed `reclaimAmmReserves` (index 24) after the
disaster kill switch.  The reserve actor itself signs NOTHING.

`ammReservePolicy` enforces that discipline as a per-actor
`LocalPolicy` (Workstream LP) consulted by the admission layer
(`Authority/SignedAction.lean`'s `localPolicyPermits` conjunct)
whenever `ammReserveActor` signs an action.  It uses a single clause:

  1. `denyTags ammReserveDeniedTags` — deny EVERY Action constructor
     tag.  Reading the `denyTags` semantics in
     `Authority/LocalPolicySemantics.lean`, a clause `denyTags ts`
     *permits* an action iff its tag is NOT in `ts`; denying the whole
     tag range makes the reserve key inert.

(The retired index 23 — the excised L1-AMM mirror `ammSwap`, which
this list once carved out as the reserve's sole permitted tag — stays
in the denied range; a retired tag must never become signable.)

No `requireRecipientIn` or `capAmount` clauses are needed because the
policy is purely defensive: even if the AMM reserve actor's key were
somehow compromised, the actor could not be used to sign ANY action.
Fund recovery needs no reserve signature either — the bridge-signed
`reclaimAmmReserves` sweep moves the balance through the bridge's
authority.

**Deny-list maintenance contract (forcing function).**
`ammReserveDeniedTags` is `List.range 26` = `[0, 1, …, 25]` — the
whole current frozen tag set.  This range is a manually-maintained
constant: whenever a NEW Action constructor is appended at index N,
this constant must be bumped to `List.range (N+1)`.  The maintenance
is mechanically enforced by `Action.tag_lt_denyListBound` (already
defined in `GasPoolPolicy.lean`), whose exhaustive `cases action`
proof fails to elaborate the moment an Action constructor whose tag
is `≥ 26` is added; `ammReservePolicy_denies_all` consumes that bound
(via `mem_ammReserveDeniedTags`), so a forgotten range bump is a
build break rather than a silent reserve-outflow escalation.

**Two-layer policy discipline (mirrors GP.7.2's `gasPoolPolicy`).**
The `ammReservePolicy` (a `LocalPolicy`) is structurally unable to bar
meta-actions (`declareLocalPolicy` / `revokeLocalPolicy`) due to the
LP.7 exemption, and is sender-blind (cannot distinguish the signer from
the action's `sender` field).  The complementary
`ammReserveAuthorityPolicy` (an `AuthorityPolicy`) closes both gaps: it
bars `ammReserveActor` from signing ANY action, with no meta-action
exemption.  Both halves are wired at genesis via the
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
    EVERY constructor index.

    `List.range 26 = [0, 1, …, 25]` — the whole current frozen Action
    tag set, the retired index 23 included.  The reserve is a pure
    COUNTERPARTY: user-signed `reserveSwap` actions (25) trade against
    its balances and the bridge-signed `reclaimAmmReserves` (24)
    sweeps them, so no signature of its own is ever legitimate.  See
    the module docstring's maintenance contract: a new constructor at
    index ≥ 26 forces a bump here, caught at build time by
    `ammReservePolicy_denies_all`. -/
def ammReserveDeniedTags : List Nat := List.range 26

/-- The canonical `LocalPolicy` governing `ammReserveActor` outflow.

    A single clause: deny every Action tag.  The policy is a
    defence-in-depth measure: in production, the `ammReserveActor` has
    no externally-controllable key (it is a virtual actor whose
    balance moves only as the counterparty of user-signed
    `reserveSwap` actions and the bridge-signed reclaim sweep).  The
    policy prevents any action from being applied in the reserve
    actor's name, even under a hypothetical key-compromise
    scenario. -/
def ammReservePolicy : LocalPolicy :=
  { clauses := [ .denyTags ammReserveDeniedTags ] }

/-! ## Deny-list membership (the forcing-function lemma) -/

/-- Every Action's tag is a member of `ammReserveDeniedTags`.  Holds
    because each current Action tag is `< 26`
    (`Action.tag_lt_denyListBound`) and the deny-list is every value
    in `[0, 26)`. -/
theorem mem_ammReserveDeniedTags (action : Action) :
    Action.tag action ∈ ammReserveDeniedTags := by
  simp only [ammReserveDeniedTags, List.mem_range]
  exact Action.tag_lt_denyListBound action

/-! ## Core security theorem: nothing is permitted -/

/-- **The reserve key is inert.**  `ammReservePolicy` denies every
    action for `ammReserveActor` unconditionally.  This is the
    headline GP.11.6 guarantee under the one-AMM topology: the AMM
    reserve can never `transfer`, `mint`, `burn`, `withdraw`, or sign
    anything at all — its balances move only as a counterparty.

    The `denyTags` clause does the work: `ammReserveDeniedTags`
    contains every tag (`mem_ammReserveDeniedTags`), so every action
    fails that clause and hence the whole policy. -/
theorem ammReservePolicy_denies_all (action : Action) :
    ¬ ammReservePolicy.permits ammReserveActor action := by
  intro hp
  have hd := hp (.denyTags ammReserveDeniedTags) (by simp [ammReservePolicy])
  exact hd (mem_ammReserveDeniedTags action)

/-- **Complete characterisation of `ammReservePolicy`.**  No action is
    permitted by `ammReservePolicy` for `ammReserveActor`.  This is
    the single source-of-truth for the reserve policy's behaviour. -/
theorem ammReservePolicy_permits_iff (action : Action) :
    ammReservePolicy.permits ammReserveActor action ↔ False := by
  exact iff_false_intro (ammReservePolicy_denies_all action)

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
    `ammReservePolicy.permits` it — i.e. `a` is a meta-action, since
    the policy permits nothing.  This is the single source of truth
    for the admission layer's behaviour with respect to the AMM
    reserve. -/
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
latter.  So an `AuthorityPolicy` that withholds all authority from
`ammReserveActor` blocks the escape hatch.

`ammReserveAuthorityPolicy` is designed to be intersected with the
deployment's base policy:

  * For `signer = ammReserveActor`: authorise NOTHING — the same
    surface `ammReservePolicy` permits, but now also barring
    meta-actions (which the `LocalPolicy` left open).
  * For `signer ≠ ammReserveActor`: authorise everything (`True`), so
    the intersection is a no-op on every other actor. -/

/-- The authority predicate restricting `ammReserveActor`: it may sign
    NOTHING — every action, including the meta-actions the LP.7
    exemption would otherwise admit, is unauthorised.  Other signers
    are authorised unconditionally (the deployment's base policy
    governs them after intersection).

    The reserve needs no signing authority: user-signed `reserveSwap`
    actions move its balances as a counterparty, and the bridge-signed
    `reclaimAmmReserves` sweep recovers them after a disaster — so a
    hypothetically compromised reserve key can do nothing at all. -/
def ammReserveActorAuthorized : ActorId → Action → Prop :=
  fun signer _action =>
    if signer = ammReserveActor then False else True

/-- Decidability of `ammReserveActorAuthorized`. -/
instance ammReserveActorAuthorized_decidable
    (signer : ActorId) (action : Action) :
    Decidable (ammReserveActorAuthorized signer action) := by
  unfold ammReserveActorAuthorized
  by_cases h : signer = ammReserveActor
  · rw [if_pos h]; infer_instance
  · rw [if_neg h]; infer_instance

/-- **The complementary `AuthorityPolicy` (closes the meta-action
    hole).**  Intersect this with the deployment's base policy at
    genesis.  It bars `ammReserveActor` from signing anything and
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
              (.declareLocalPolicy p)) := by
  refine ⟨?_, fun p => ?_⟩ <;>
    · intro hauth
      simp [ammReserveAuthorityPolicy, ammReserveActorAuthorized] at hauth

/-- **The authority policy bars every action for `ammReserveActor`.**
    Strictly stronger than the `LocalPolicy`'s deny-list, since it
    also covers the meta-actions. -/
theorem ammReserveAuthorityPolicy_rejects_all (action : Action) :
    ¬ ammReserveAuthorityPolicy.authorized ammReserveActor action := by
  intro hauth
  simp [ammReserveAuthorityPolicy, ammReserveActorAuthorized] at hauth

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

/-- **The genesis policy bars every reserve-signed action.** -/
theorem ammReserveGenesisPolicy_rejects_all
    (P : AuthorityPolicy) (action : Action) :
    ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor action := by
  unfold ammReserveGenesisPolicy
  intro hauth
  exact ammReserveAuthorityPolicy_rejects_all action hauth.2

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
    single-clause policy uses only `denyTags` with 26 entries (all
    values < 26 < 2^64), well within the §3.0 field limits.  This
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
  have hlt : n < 26 := by
    simpa [ammReserveDeniedTags] using hn
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

/-! ## Workstream SB — the `reserveSwap` user/reserve binding

`Laws.reserveSwap` (frozen `Action` index 25) is the USER-facing L2
swap: the `user` field's balance is debited/credited, and the
`reserveActor` field names the counterparty whose reserves trade.
Both fields are ACTION DATA, so without a policy-layer pin a signer
could name (a) a VICTIM as `user` — moving someone else's balance —
or (b) a victim as `reserveActor` — trading against an arbitrary
actor's holdings instead of the canonical AMM reserve.

`reserveSwapUserBinding` closes both at the `AuthorityPolicy` layer
(the amendment-1.11 `gasPoolActorAuthorized` sender-binding
precedent): for EVERY signer, a `.reserveSwap` is authorised only
when `user = signer` AND `reserveActor = ammReserveActor`.  Every
non-`reserveSwap` action is unconstrained (`True`), so intersecting
this policy into a deployment's base policy is a no-op outside
tag 25.

This sits at the `AuthorityPolicy` conjunct of `AdmissibleWith`,
which has NO meta-action exemption and is consulted for every
signer — unlike a `LocalPolicy`, which gates only the DECLARING
actor's own signatures and so could never bind a field to the
signer. -/

/-- The authority predicate binding `reserveSwap`'s two actor fields:
    `user = signer` (a third party cannot move someone else's
    balance) and `reserveActor = ammReserveActor` (the counterparty
    is the canonical reserve, never a victim's holdings).  Every
    other action is authorised unconditionally — the deployment's
    base policy governs it after intersection. -/
def reserveSwapUserBinding : ActorId → Action → Prop :=
  fun signer action =>
    match action with
    | .reserveSwap _ _ user _ _ ra =>
        user = signer ∧ ra = ammReserveActor
    | _ => True

/-- Decidability of `reserveSwapUserBinding`. -/
instance reserveSwapUserBinding_decidable
    (signer : ActorId) (action : Action) :
    Decidable (reserveSwapUserBinding signer action) := by
  unfold reserveSwapUserBinding
  cases action <;> infer_instance

/-- **The `reserveSwap` binding as an `AuthorityPolicy`.**  Intersect
    this with the deployment's base policy at genesis (alongside
    `ammReserveAuthorityPolicy` / `gasPoolAuthorityPolicy`). -/
def reserveSwapBindingPolicy : AuthorityPolicy where
  authorized := reserveSwapUserBinding
  decAuth    := fun _ _ => inferInstance

/-- **A third party cannot name someone else as the swap's `user`.**
    A `.reserveSwap` whose `user` field differs from the signer is
    unauthorised under the binding — the swap's debit/credit legs can
    only ever move the SIGNER's own balances. -/
theorem reserveSwapBindingPolicy_rejects_third_party_user
    (signer : ActorId) (fr tr : ResourceId) (user : ActorId)
    (amountIn minAmountOut : Amount) (ra : ActorId)
    (h : user ≠ signer) :
    ¬ reserveSwapBindingPolicy.authorized signer
        (.reserveSwap fr tr user amountIn minAmountOut ra) :=
  fun hauth => h hauth.1

/-- **The swap's counterparty is pinned to the canonical reserve.**
    A `.reserveSwap` naming any `reserveActor ≠ ammReserveActor` is
    unauthorised — a signer cannot elect an arbitrary actor's
    balances as the pool it trades against. -/
theorem reserveSwapBindingPolicy_rejects_non_reserve_counterparty
    (signer : ActorId) (fr tr : ResourceId) (user : ActorId)
    (amountIn minAmountOut : Amount) (ra : ActorId)
    (h : ra ≠ ammReserveActor) :
    ¬ reserveSwapBindingPolicy.authorized signer
        (.reserveSwap fr tr user amountIn minAmountOut ra) :=
  fun hauth => h hauth.2

/-- **The self-signed canonical swap is authorised.**  The binding
    admits exactly the legitimate shape: the signer as `user`, the
    canonical reserve as counterparty. -/
theorem reserveSwapBindingPolicy_authorizes_self_swap
    (signer : ActorId) (fr tr : ResourceId)
    (amountIn minAmountOut : Amount) :
    reserveSwapBindingPolicy.authorized signer
      (.reserveSwap fr tr signer amountIn minAmountOut ammReserveActor) :=
  ⟨rfl, rfl⟩

/-- **Positive extraction: an authorised swap is self-targeted at the
    canonical reserve.**  The form downstream accounting arguments
    consume. -/
theorem reserveSwapBindingPolicy_authorized_shape
    (signer : ActorId) (fr tr : ResourceId) (user : ActorId)
    (amountIn minAmountOut : Amount) (ra : ActorId)
    (hp : reserveSwapBindingPolicy.authorized signer
            (.reserveSwap fr tr user amountIn minAmountOut ra)) :
    user = signer ∧ ra = ammReserveActor :=
  hp

/-- **The binding is a no-op outside tag 25.**  For any
    non-`reserveSwap` action, intersecting `reserveSwapBindingPolicy`
    into a base policy `P` leaves the authorisation exactly `P`'s. -/
theorem reserveSwapBindingPolicy_other_actions_unrestricted
    (P : AuthorityPolicy) (signer : ActorId) (action : Action)
    (h : ∀ fr tr user amountIn minAmountOut ra,
      action ≠ .reserveSwap fr tr user amountIn minAmountOut ra) :
    (P.intersect reserveSwapBindingPolicy).authorized signer action ↔
      P.authorized signer action := by
  unfold AuthorityPolicy.intersect reserveSwapBindingPolicy
    reserveSwapUserBinding
  cases hact : action with
  | reserveSwap fr tr user amountIn minAmountOut ra =>
      exact absurd hact (h fr tr user amountIn minAmountOut ra)
  | _ => simp

/-- **The binding survives intersection.**  Under
    `P.intersect reserveSwapBindingPolicy`, a third-party-user swap is
    rejected regardless of what `P` says — the deployment's base
    policy cannot re-open the hole. -/
theorem reserveSwapBindingPolicy_intersect_rejects_third_party
    (P : AuthorityPolicy) (signer : ActorId) (fr tr : ResourceId)
    (user : ActorId) (amountIn minAmountOut : Amount) (ra : ActorId)
    (h : user ≠ signer) :
    ¬ (P.intersect reserveSwapBindingPolicy).authorized signer
        (.reserveSwap fr tr user amountIn minAmountOut ra) :=
  fun hauth =>
    reserveSwapBindingPolicy_rejects_third_party_user signer fr tr user
      amountIn minAmountOut ra h hauth.2

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

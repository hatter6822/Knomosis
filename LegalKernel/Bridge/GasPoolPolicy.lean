-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.GasPoolPolicy — Workstream GP.7.2.

Declares the canonical `LocalPolicy` that governs the gas-pool
actor's (`gasPoolActor`, GP.7.1 / `ActorId 1`) outflow.  The pool
accumulates deposit fee-split revenue and per-actor budget top-up
payments at `ResourceId 0` (ETH) and `ResourceId 1` (BOLD); its
*only* legitimate outflow is a capped `transfer` to the sequencer
(`sequencerActor`, GP.7.1 / `ActorId 2`) so the sequencer can
reimburse itself for L1 publishing gas.

`gasPoolPolicy` enforces that discipline as a per-actor
`LocalPolicy` (Workstream LP) consulted by the admission layer
(`Authority/SignedAction.lean`'s `localPolicyPermits` conjunct)
whenever `gasPoolActor` signs an action.  It combines five
conjunctive clauses:

  1. `denyTags gasPoolDeniedTags` — deny every Action constructor
     tag EXCEPT `transfer` (tag 0).  Reading the `denyTags`
     semantics in `Authority/LocalPolicySemantics.lean`, a clause
     `denyTags ts` *permits* an action iff its tag is NOT in `ts`;
     so to allow only `transfer` we deny every other tag.  This
     clause is resource-agnostic — it gates ALL non-transfer
     outflow from the pool regardless of resource.
  2. `requireRecipientIn 0 [sequencerActor]` — a `transfer` over
     resource 0 (the ETH leg) must be sent to `sequencerActor`.
  3. `capAmount 0 maxDrainPerActionEth` — the per-action ETH-leg
     transfer amount is capped.
  4. `requireRecipientIn 1 [sequencerActor]` — the same recipient
     restriction for resource 1 (the BOLD leg).
  5. `capAmount 1 maxDrainPerActionBold` — the per-action BOLD-leg
     transfer amount cap.  The cap may differ from the ETH leg:
     operators typically calibrate so the USD-denominated cap is
     similar across legs (a BOLD claim of 10 000 BOLD ≈ $10 000;
     an ETH claim of 1 ETH ≈ $3 000).

The two legs are mathematically independent: the resource-keyed
`requireRecipientIn` / `capAmount` clauses are vacuous on an action
over a non-matching resource (the `r' ≠ r` left disjunct), so the
ETH-leg constraints never block a legitimate BOLD-leg transfer and
vice versa (`gasPoolPolicy_eth_bold_independent`).

The *per-epoch* drain bound — the pool's balance cannot fall by
more than `trace.length × maxDrainPerAction` across any contiguous
admitted trace — is NOT a single-clause property.  It is an
inductive accounting argument over the admitted-trace structure,
established by GP.7.3 (`LegalKernel/Bridge/PoolDrainBound.lean`).
This module ships only the per-action policy and its
characterisation theorems, which GP.7.3 consumes.

**Deny-list maintenance contract (forcing function).**
`gasPoolDeniedTags` is `(List.range 23).filter (· ≠ 0)` =
`[1, 2, …, 22]` — every Action tag except `transfer`, covering the
current frozen set (0..21) plus one reserved slot for the
GP.11 `ammSwap` (index 22), which the pool actor must likewise be
forbidden from signing.  This range is a manually-maintained
constant: whenever a NEW Action constructor is appended at index N,
this constant (and the GP.11 `ammReservePolicy`) must be bumped to
`List.range (N+1)`.  The maintenance is mechanically enforced by
`Action.tag_lt_denyListBound`, whose exhaustive `cases action` proof
fails to elaborate the moment an Action constructor whose tag is
`≥ 23` is added; `gasPoolPolicy_denies_all_non_transfer` consumes
that bound (via `mem_gasPoolDeniedTags_of_tag_ne_zero`), so a
forgotten range bump is a build break rather than a silent
pool-outflow escalation.

This module is **not** part of the kernel TCB.  A bug here would
weaken the pool-drain discipline but cannot violate any kernel
invariant: the kernel's `apply_admissible` rejects any action that
fails the supplied policy predicate, and a too-permissive
`gasPoolPolicy` can only ever ADMIT a pool transfer the kernel then
applies under its ordinary conservation guarantees.
-/

import LegalKernel.Bridge.BridgeActor
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.LocalPolicy

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority
open LegalKernel.Encoding (Encodable)

/-! ## The deny-list and the canonical policy -/

/-- The Action tags the gas-pool actor is forbidden from signing:
    every constructor index EXCEPT `transfer` (tag 0).

    `(List.range 23).filter (· ≠ 0) = [1, 2, …, 22]` — the current
    frozen Action set spans indices 0..21, and index 22 reserves the
    GP.11 `ammSwap` slot (the pool actor must never swap its
    reserves), so denying through 22 pre-secures that slot.  See the
    module docstring's maintenance contract: a new constructor at
    index ≥ 23 forces a bump here, caught at build time by
    `gasPoolPolicy_denies_all_non_transfer`. -/
def gasPoolDeniedTags : List Nat := (List.range 23).filter (· ≠ 0)

/-- The canonical `LocalPolicy` governing `gasPoolActor` outflow.

    Parameterised by the per-leg per-action caps
    `maxDrainPerActionEth` (resource 0) and `maxDrainPerActionBold`
    (resource 1).  Combines five clauses conjunctively (see the
    module docstring): deny every non-`transfer` tag, and on each of
    the two pool resources require the recipient be `sequencerActor`
    and the amount be at most the leg's cap.

    Exact reach (`gasPoolPolicy_permits_transfer_iff`): a
    `gasPoolActor`-signed action passes this `LocalPolicy` iff it is a
    `transfer` AND, for whichever of resources `0` / `1` it is over,
    the recipient is `sequencerActor` and the amount is within that
    leg's cap.  Two boundaries are deliberate, NOT hidden: (a) a
    transfer over a resource `≥ 2` is unconstrained by the per-leg
    clauses (`gasPoolPolicy_permits_transfer_off_gas_legs`) — off-leg
    safety rests on a SEPARATE pool-balance invariant (the pool holds
    no balance outside `{0, 1}`; the GP.7.3 track), not on this
    policy; and (b) the LP.7 meta-action exemption means this
    `LocalPolicy` cannot bar `gasPoolActor` from policy-management
    actions (`gasPoolPolicy_admission_permits_meta_actions`) — that
    hole is closed by the complementary `gasPoolAuthorityPolicy` in
    this module, which a deployment intersects into its base policy. -/
def gasPoolPolicy
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) : LocalPolicy :=
  { clauses :=
      [ .denyTags gasPoolDeniedTags
      , .requireRecipientIn 0 [sequencerActor]
      , .capAmount 0 maxDrainPerActionEth
      , .requireRecipientIn 1 [sequencerActor]
      , .capAmount 1 maxDrainPerActionBold ] }

/-! ## Deny-list membership (the forcing-function lemma)

The single load-bearing arithmetic fact: every Action whose tag is
non-zero lies in `gasPoolDeniedTags`.  The supporting
`Action.tag_lt_denyListBound` exhausts the Action inductive — it is
the build-time forcing function described in the module docstring,
elaborating exactly while every Action tag is `< 23`. -/

/-- Every current Action's tag is strictly below the gas-pool
    deny-list bound (`23`).  Proven by exhaustive `cases` on the
    inductive — this is the forcing function: appending an Action
    constructor whose tag is `≥ 23` (i.e. a 24th constructor without
    a matching `gasPoolDeniedTags` bump) breaks this proof, so the
    deny-list can never silently fall behind the Action set.  `simp`
    reduces each branch's `.tag` to a literal and discharges the
    `literal < 23` comparison via the `Nat` comparison simproc. -/
theorem Action.tag_lt_denyListBound (action : Action) :
    Action.tag action < 23 := by
  cases action <;> simp [Action.tag]

/-- Every non-`transfer` Action's tag is a member of
    `gasPoolDeniedTags`.  Holds because each current Action tag is
    `< 23` (`Action.tag_lt_denyListBound`) and the deny-list is every
    value in `[0, 23)` except `0`. -/
theorem mem_gasPoolDeniedTags_of_tag_ne_zero
    (action : Action) (h : Action.tag action ≠ 0) :
    Action.tag action ∈ gasPoolDeniedTags := by
  simp only [gasPoolDeniedTags, List.mem_filter, List.mem_range, decide_eq_true_eq]
  exact ⟨Action.tag_lt_denyListBound action, h⟩

/-! ## Core security theorem: only `transfer` is permitted -/

/-- **Pool outflow is `transfer`-only.**  For any action whose tag is
    not `0` (i.e. every Action constructor except `transfer`),
    `gasPoolPolicy` denies it for `gasPoolActor` regardless of the
    per-leg caps.  This is the headline GP.7.2 guarantee: the gas
    pool can never `mint`, `burn`, `withdraw`, top up budgets, or
    sign any non-transfer action — its sole capability is a capped
    `transfer` to the sequencer.

    The `denyTags` clause does the work: `gasPoolDeniedTags` contains
    every non-zero tag (`mem_gasPoolDeniedTags_of_tag_ne_zero`), so a
    non-transfer action fails that clause and hence the whole
    conjunctive policy. -/
theorem gasPoolPolicy_denies_all_non_transfer
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (action : Action) (h : Action.tag action ≠ 0) :
    ¬ (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor action := by
  intro hp
  have hd := hp (.denyTags gasPoolDeniedTags) (by simp [gasPoolPolicy])
  exact hd (mem_gasPoolDeniedTags_of_tag_ne_zero action h)

/-! ## Per-leg recipient restriction

A pool `transfer` over either resource must target `sequencerActor`.
The two theorems below are the `requireRecipientIn` halves of the
policy, one per leg.  `sender` is left general (the policy never
inspects the sender field — in practice it is `gasPoolActor`
itself, but the clause semantics don't depend on it). -/

/-- **ETH-leg recipient restriction.**  A `gasPoolActor`-signed
    `transfer` over resource 0 to any recipient other than
    `sequencerActor` is denied (it fails the
    `requireRecipientIn 0 [sequencerActor]` clause).  Mitigates
    attack-tree item 5: a malicious sequencer cannot route ETH-leg
    pool funds to an arbitrary address. -/
theorem gasPoolPolicy_requires_sequencer_recipient_eth
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender receiver : ActorId) (amount : Amount)
    (h : receiver ≠ sequencerActor) :
    ¬ (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer 0 sender receiver amount) := by
  intro hp
  have hr := hp (.requireRecipientIn 0 [sequencerActor]) (by simp [gasPoolPolicy])
  rw [LocalPolicyClause.requireRecipientIn_permits_transfer] at hr
  rcases hr with hne | hmem
  · exact hne rfl
  · exact h (by simpa using hmem)

/-- **BOLD-leg recipient restriction.**  The resource-1 mirror of
    `gasPoolPolicy_requires_sequencer_recipient_eth`: a pool
    `transfer` over resource 1 to any recipient other than
    `sequencerActor` is denied. -/
theorem gasPoolPolicy_requires_sequencer_recipient_bold
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender receiver : ActorId) (amount : Amount)
    (h : receiver ≠ sequencerActor) :
    ¬ (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer 1 sender receiver amount) := by
  intro hp
  have hr := hp (.requireRecipientIn 1 [sequencerActor]) (by simp [gasPoolPolicy])
  rw [LocalPolicyClause.requireRecipientIn_permits_transfer] at hr
  rcases hr with hne | hmem
  · exact hne rfl
  · exact h (by simpa using hmem)

/-! ## Per-leg amount cap

A pool `transfer` over either resource is bounded by that leg's
per-action cap.  These are the `capAmount` halves of the policy,
the per-action ingredient the GP.7.3 inductive drain bound sums
over a trace. -/

/-- **ETH-leg per-action cap.**  A `gasPoolActor`-signed `transfer`
    over resource 0 whose amount exceeds `maxDrainPerActionEth` is
    denied (it fails the `capAmount 0 maxDrainPerActionEth` clause).
    Mitigates attack-tree item 4: the per-action ETH drain is
    capped. -/
theorem gasPoolPolicy_caps_per_action_eth
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender receiver : ActorId) (amount : Amount)
    (h : ¬ amount ≤ maxDrainPerActionEth) :
    ¬ (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer 0 sender receiver amount) := by
  intro hp
  have hc := hp (.capAmount 0 maxDrainPerActionEth) (by simp [gasPoolPolicy])
  rw [LocalPolicyClause.capAmount_permits_transfer] at hc
  rcases hc with hne | hle
  · exact hne rfl
  · exact h hle

/-- **BOLD-leg per-action cap.**  The resource-1 mirror of
    `gasPoolPolicy_caps_per_action_eth`: a pool `transfer` over
    resource 1 whose amount exceeds `maxDrainPerActionBold` is
    denied.  The BOLD cap is an independent parameter, so a
    deployment can calibrate the two legs for USD parity. -/
theorem gasPoolPolicy_caps_per_action_bold
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender receiver : ActorId) (amount : Amount)
    (h : ¬ amount ≤ maxDrainPerActionBold) :
    ¬ (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer 1 sender receiver amount) := by
  intro hp
  have hc := hp (.capAmount 1 maxDrainPerActionBold) (by simp [gasPoolPolicy])
  rw [LocalPolicyClause.capAmount_permits_transfer] at hc
  rcases hc with hne | hle
  · exact hne rfl
  · exact h hle

/-! ## Per-leg amount extraction (positive direction, for GP.7.3)

The positive contrapositives of the cap theorems: a *permitted*
pool transfer over a given leg has its amount within that leg's
cap.  GP.7.3's inductive drain bound consumes these directly — each
admitted pool-`transfer` step contributes at most the leg cap to the
total drain. -/

/-- If `gasPoolPolicy` permits a pool `transfer` over resource 0,
    its amount is within the ETH-leg cap.  The positive form of
    `gasPoolPolicy_caps_per_action_eth`, suited to summing per-step
    bounds in the GP.7.3 drain argument. -/
theorem gasPoolPolicy_permits_transfer_eth_amount_le
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender receiver : ActorId) (amount : Amount)
    (hp : (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
            gasPoolActor (.transfer 0 sender receiver amount)) :
    amount ≤ maxDrainPerActionEth := by
  have hc := hp (.capAmount 0 maxDrainPerActionEth) (by simp [gasPoolPolicy])
  rw [LocalPolicyClause.capAmount_permits_transfer] at hc
  rcases hc with hne | hle
  · exact absurd rfl hne
  · exact hle

/-- If `gasPoolPolicy` permits a pool `transfer` over resource 1,
    its amount is within the BOLD-leg cap.  The positive form of
    `gasPoolPolicy_caps_per_action_bold`. -/
theorem gasPoolPolicy_permits_transfer_bold_amount_le
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender receiver : ActorId) (amount : Amount)
    (hp : (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
            gasPoolActor (.transfer 1 sender receiver amount)) :
    amount ≤ maxDrainPerActionBold := by
  have hc := hp (.capAmount 1 maxDrainPerActionBold) (by simp [gasPoolPolicy])
  rw [LocalPolicyClause.capAmount_permits_transfer] at hc
  rcases hc with hne | hle
  · exact absurd rfl hne
  · exact hle

/-! ## Leg independence

The per-resource clauses do not cross-contaminate: an ETH-leg
transfer satisfies both BOLD clauses vacuously (resource 0 ≠ 1), and
a BOLD-leg transfer satisfies both ETH clauses vacuously (resource
1 ≠ 0).  This is why the two legs can carry independent caps without
one leg's constraints blocking the other's legitimate drains. -/

/-- **Leg independence.**  A `transfer` over resource 0 passes both
    resource-1 (BOLD) clauses vacuously, and a `transfer` over
    resource 1 passes both resource-0 (ETH) clauses vacuously — for
    any sender / receiver / amount.  The four conjuncts witness that
    the per-leg `requireRecipientIn` / `capAmount` clauses are
    resource-keyed: each is automatically satisfied on a transfer
    over the *other* resource via the `r' ≠ r` left disjunct. -/
theorem gasPoolPolicy_eth_bold_independent
    (sender receiver : ActorId) (amount : Amount)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount) :
    (LocalPolicyClause.requireRecipientIn 1 [sequencerActor]).permits
        gasPoolActor (.transfer 0 sender receiver amount) ∧
    (LocalPolicyClause.capAmount 1 maxDrainPerActionBold).permits
        gasPoolActor (.transfer 0 sender receiver amount) ∧
    (LocalPolicyClause.requireRecipientIn 0 [sequencerActor]).permits
        gasPoolActor (.transfer 1 sender receiver amount) ∧
    (LocalPolicyClause.capAmount 0 maxDrainPerActionEth).permits
        gasPoolActor (.transfer 1 sender receiver amount) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · rw [LocalPolicyClause.requireRecipientIn_permits_transfer]; exact Or.inl (by decide)
  · rw [LocalPolicyClause.capAmount_permits_transfer]; exact Or.inl (by decide)
  · rw [LocalPolicyClause.requireRecipientIn_permits_transfer]; exact Or.inl (by decide)
  · rw [LocalPolicyClause.capAmount_permits_transfer]; exact Or.inl (by decide)

/-! ## Happy path: the sequencer claim is admitted

The positive companion to the deny/cap theorems: a pool `transfer`
to `sequencerActor` within the leg cap passes the whole policy.
This is the legitimate sequencer-reimbursement drain, and the
witness GP.7.4's example deployment and the GP.7.3 base case build
on. -/

/-- `0 ∉ gasPoolDeniedTags`: the `transfer` tag survives the
    deny-list (the deny-list is every value in `[0, 23)` except
    `0`).  Pinned as a named lemma so the happy-path proof's
    `denyTags` branch is a one-liner. -/
theorem zero_not_mem_gasPoolDeniedTags : (0 : Nat) ∉ gasPoolDeniedTags := by
  simp [gasPoolDeniedTags]

/-- **ETH-leg sequencer claim admitted.**  A `gasPoolActor`-signed
    `transfer` over resource 0 to `sequencerActor` whose amount is
    within `maxDrainPerActionEth` passes `gasPoolPolicy` — the
    legitimate pool-drain path is admitted, not just the illegitimate
    ones denied. -/
theorem gasPoolPolicy_permits_sequencer_transfer_eth
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender : ActorId) (amount : Amount)
    (h : amount ≤ maxDrainPerActionEth) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer 0 sender sequencerActor amount) := by
  intro c hc
  simp only [gasPoolPolicy, List.mem_cons, List.not_mem_nil, or_false] at hc
  rcases hc with rfl | rfl | rfl | rfl | rfl
  · exact zero_not_mem_gasPoolDeniedTags
  · rw [LocalPolicyClause.requireRecipientIn_permits_transfer]
    exact Or.inr List.mem_cons_self
  · rw [LocalPolicyClause.capAmount_permits_transfer]; exact Or.inr h
  · rw [LocalPolicyClause.requireRecipientIn_permits_transfer]; exact Or.inl (by decide)
  · rw [LocalPolicyClause.capAmount_permits_transfer]; exact Or.inl (by decide)

/-- **BOLD-leg sequencer claim admitted.**  The resource-1 mirror of
    `gasPoolPolicy_permits_sequencer_transfer_eth`: a pool `transfer`
    over resource 1 to `sequencerActor` within `maxDrainPerActionBold`
    passes `gasPoolPolicy`. -/
theorem gasPoolPolicy_permits_sequencer_transfer_bold
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (sender : ActorId) (amount : Amount)
    (h : amount ≤ maxDrainPerActionBold) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer 1 sender sequencerActor amount) := by
  intro c hc
  simp only [gasPoolPolicy, List.mem_cons, List.not_mem_nil, or_false] at hc
  rcases hc with rfl | rfl | rfl | rfl | rfl
  · exact zero_not_mem_gasPoolDeniedTags
  · rw [LocalPolicyClause.requireRecipientIn_permits_transfer]; exact Or.inl (by decide)
  · rw [LocalPolicyClause.capAmount_permits_transfer]; exact Or.inl (by decide)
  · rw [LocalPolicyClause.requireRecipientIn_permits_transfer]
    exact Or.inr List.mem_cons_self
  · rw [LocalPolicyClause.capAmount_permits_transfer]; exact Or.inr h

/-! ## Complete characterisation of the permitted set (`permits_iff`)

The per-clause theorems above pin individual `(action, verdict)`
implications.  `gasPoolPolicy_permits_transfer_iff` below is the
single source of truth, in the spirit of GP.7.0's
`bridgeAuthorizedAction_eq_true_iff`: it states EXACTLY which
`gasPoolActor`-signed actions `gasPoolPolicy` permits, with no
implication left implicit.

The right-hand side makes the deliberate scope of the policy
visible — including the two boundaries my per-clause theorems alone
do not surface:

  * **Non-transfer denial** (the `tag = 0` conjunct), and
  * the per-leg recipient + cap conditions for resources `0` / `1`,
    **but no constraint at all on resource `≥ 2`** (the third
    disjunct branch `r ∉ {0, 1}`).

That last branch is load-bearing for honesty: `gasPoolPolicy` does
NOT, by itself, forbid a `transfer` over some resource `r ≥ 2` to an
arbitrary recipient for an arbitrary amount.  The pool's outflow
discipline therefore rests on a SEPARATE invariant — that the pool
actor only ever holds a balance at resources `0` (ETH) and `1`
(BOLD) — which the deposit / top-up machinery establishes and which
`gasPoolPolicy_permits_transfer_off_gas_legs` documents explicitly
rather than hiding behind prose.  See that theorem's docstring. -/

/-- **Complete characterisation of the permitted transfer set.**  For
    a `gasPoolActor`-signed `transfer r sender receiver amount`,
    `gasPoolPolicy` permits it iff BOTH per-leg conditions hold:

      * resource `0` (ETH): `r ≠ 0` OR (`receiver = sequencerActor`
        AND `amount ≤ maxDrainPerActionEth`); AND
      * resource `1` (BOLD): `r ≠ 1` OR (`receiver = sequencerActor`
        AND `amount ≤ maxDrainPerActionBold`).

    Note what this exposes: when `r ∉ {0, 1}` BOTH disjuncts hold via
    their left branch, so the policy permits the transfer
    **unconditionally** — any recipient, any amount.  The `transfer`
    tag itself always survives the `denyTags` clause (tag `0 ∉`
    deny-list), so the deny clause contributes nothing here.  This is
    the precise, honest statement of the policy's reach over a
    transfer; the companion `gasPoolPolicy_denies_all_non_transfer`
    covers every non-transfer action. -/
theorem gasPoolPolicy_permits_transfer_iff
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer r sender receiver amount) ↔
      (r ≠ 0 ∨ (receiver = sequencerActor ∧ amount ≤ maxDrainPerActionEth)) ∧
      (r ≠ 1 ∨ (receiver = sequencerActor ∧ amount ≤ maxDrainPerActionBold)) := by
  constructor
  · -- Forward: a permitting policy yields both per-leg conditions.
    intro hp
    have hReqE := hp (.requireRecipientIn 0 [sequencerActor]) (by simp [gasPoolPolicy])
    have hCapE := hp (.capAmount 0 maxDrainPerActionEth) (by simp [gasPoolPolicy])
    have hReqB := hp (.requireRecipientIn 1 [sequencerActor]) (by simp [gasPoolPolicy])
    have hCapB := hp (.capAmount 1 maxDrainPerActionBold) (by simp [gasPoolPolicy])
    rw [LocalPolicyClause.requireRecipientIn_permits_transfer] at hReqE hReqB
    rw [LocalPolicyClause.capAmount_permits_transfer] at hCapE hCapB
    refine ⟨?_, ?_⟩
    · -- ETH leg: combine the recipient and cap disjunctions on `r = 0`.
      rcases hReqE with hr | hmem
      · exact Or.inl hr
      · rcases hCapE with hr | hle
        · exact Or.inl hr
        · exact Or.inr ⟨by simpa using hmem, hle⟩
    · -- BOLD leg: symmetric on `r = 1`.
      rcases hReqB with hr | hmem
      · exact Or.inl hr
      · rcases hCapB with hr | hle
        · exact Or.inl hr
        · exact Or.inr ⟨by simpa using hmem, hle⟩
  · -- Backward: both per-leg conditions imply every clause permits.
    rintro ⟨hE, hB⟩ c hc
    simp only [gasPoolPolicy, List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl | rfl | rfl | rfl
    · -- denyTags: the transfer tag (0) is not in the deny-list.
      exact zero_not_mem_gasPoolDeniedTags
    · -- requireRecipientIn 0: from the ETH condition.
      rw [LocalPolicyClause.requireRecipientIn_permits_transfer]
      rcases hE with hr | ⟨hrcv, _⟩
      · exact Or.inl hr
      · exact Or.inr (by simp [hrcv])
    · -- capAmount 0: from the ETH condition.
      rw [LocalPolicyClause.capAmount_permits_transfer]
      rcases hE with hr | ⟨_, hle⟩
      · exact Or.inl hr
      · exact Or.inr hle
    · -- requireRecipientIn 1: from the BOLD condition.
      rw [LocalPolicyClause.requireRecipientIn_permits_transfer]
      rcases hB with hr | ⟨hrcv, _⟩
      · exact Or.inl hr
      · exact Or.inr (by simp [hrcv])
    · -- capAmount 1: from the BOLD condition.
      rw [LocalPolicyClause.capAmount_permits_transfer]
      rcases hB with hr | ⟨_, hle⟩
      · exact Or.inl hr
      · exact Or.inr hle

/-! ## The resource-`≥ 2` boundary (honest scope of the policy)

`gasPoolPolicy` constrains pool outflow only on resources `0` (ETH)
and `1` (BOLD) — the two currencies the gas pool actually holds.  A
`transfer` over any OTHER resource is unconstrained by the per-leg
clauses.  The two theorems below state this explicitly: a transfer
over `r ≥ 2` is permitted by `gasPoolPolicy` for ANY recipient and
amount.

This is NOT a soundness hole in the policy itself; it is a
boundary that the policy's *deployment context* discharges.  The
pool's outflow discipline ("only capped transfers to the sequencer")
is the conjunction of:

  1. `gasPoolPolicy` (this module), which caps the `{0, 1}` legs and
     forbids every non-transfer action; AND
  2. a *pool-balance invariant* — `getBalance es gasPoolActor r = 0`
     for every `r ∉ {0, 1}` across all reachable states — which the
     deposit (`depositWithFee`, crediting only the chosen resource ∈
     {0, 1}) and top-up (`topUpActionBudget{,For}`, crediting only
     the gas resource) machinery establishes, since the kernel's
     conservation laws mean the pool can hold a positive balance at
     `r` only if something credited it there.

A transfer permitted by clause (1) over `r ≥ 2` therefore moves a
balance that invariant (2) guarantees is `0` — a no-op under the
kernel's `transfer` precondition (`amount ≤ balance = 0` forces
`amount = 0`).  The inductive form of invariant (2) over a reachable
trace is the GP.7.3 drain-bound track (it is exactly the
"pool only credited at {0,1}" half of the reconciliation argument);
this module states the per-action boundary the inductive proof
rests on, and does not hide it. -/

/-- **Resource-`≥ 2` boundary (the policy is silent off the two gas
    legs).**  For any resource `r` that is neither `0` (ETH) nor `1`
    (BOLD), `gasPoolPolicy` permits a `gasPoolActor`-signed `transfer`
    over `r` to ANY recipient for ANY amount.  This is the honest
    converse of the per-leg theorems: the policy does not — and
    cannot, with the resource-keyed `LocalPolicyClause` vocabulary —
    constrain resources it carries no clause for.  Deployment safety
    on these resources rests on the pool-balance invariant documented
    in the section header, not on `gasPoolPolicy`. -/
theorem gasPoolPolicy_permits_transfer_off_gas_legs
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (h0 : r ≠ 0) (h1 : r ≠ 1) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer r sender receiver amount) := by
  rw [gasPoolPolicy_permits_transfer_iff]
  exact ⟨Or.inl h0, Or.inl h1⟩

/-! ## Admission-layer reach + the meta-action boundary (GP.7.2 / LP.7)

The theorems above characterise the bare `LocalPolicy.permits`
predicate.  The predicate the kernel ACTUALLY consults at admission
is `Authority.localPolicyPermits`, which is

  `isMetaPolicyAction action = true ∨ (lookup signer).permits …`.

The left disjunct is the LP.7 *meta-action exemption*: an actor can
ALWAYS sign `declareLocalPolicy` / `revokeLocalPolicy`, regardless of
its declared policy — the structural lockout-prevention guarantee
(`localPolicy_meta_action_independent`).  This is a deliberate and
load-bearing feature of the local-policy layer (without it an actor
could brick itself), but it has a direct consequence for the gas
pool that MUST be stated, not glossed:

  **`gasPoolPolicy` alone does NOT prevent `gasPoolActor` from
  signing `declareLocalPolicy` / `revokeLocalPolicy`.**  Those two
  actions are admitted by the meta-action exemption even when
  `gasPoolActor`'s declared policy is `gasPoolPolicy`.  In
  particular, a `gasPoolActor` whose key signs
  `revokeLocalPolicy` (or `declareLocalPolicy LocalPolicy.empty`)
  removes the `gasPoolPolicy` restriction on itself.

Closing that escape hatch is therefore NOT in scope for a
`LocalPolicy`: it requires a complementary deployment-level
`AuthorityPolicy` that withholds `declareLocalPolicy` /
`revokeLocalPolicy` authority from `gasPoolActor` (the gas-pool key
is held by the operator/sequencer for signing the capped sequencer
claim; it has no legitimate need to manage local policies).  The
genesis-ratification WU (GP.7.4) is where that `AuthorityPolicy`
intersection is wired and proven; GP.7.2 documents the requirement
here so it cannot be forgotten.

`gasPoolPolicy_admission_permits_iff` below makes the exemption
explicit at the admission level, and
`gasPoolPolicy_admission_denies_non_transfer_non_meta` states the
exact guarantee `gasPoolPolicy` DOES provide at admission: every
non-transfer, non-meta action is denied. -/

/-- **Admission-level characterisation.**  When `gasPoolActor`'s
    declared policy is exactly `gasPoolPolicy`, the kernel's
    admission conjunct `localPolicyPermits` permits an action iff it
    is a meta-action (`declareLocalPolicy` / `revokeLocalPolicy`,
    admitted by the LP.7 exemption) OR `gasPoolPolicy` itself permits
    it.  Spells out the meta-action escape hatch so it is impossible
    to mistake `gasPoolPolicy`'s admission-level reach for its bare
    `.permits` reach. -/
theorem gasPoolPolicy_admission_permits_iff
    (es : ExtendedState) (action : Action)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (hpol : es.localPolicies.lookup gasPoolActor =
            gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold) :
    Authority.localPolicyPermits es gasPoolActor action ↔
      (Authority.isMetaPolicyAction action = true ∨
        (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
          gasPoolActor action) := by
  unfold Authority.localPolicyPermits
  rw [hpol]

/-- **The admission-level guarantee `gasPoolPolicy` genuinely
    provides.**  When `gasPoolActor`'s declared policy is
    `gasPoolPolicy`, the kernel's admission conjunct denies every
    action that is BOTH non-transfer (`tag ≠ 0`) AND non-meta.  This
    is the honest, admission-level form of
    `gasPoolPolicy_denies_all_non_transfer`: the `tag ≠ 0` hypothesis
    excludes the permitted `transfer` capability, and the explicit
    non-meta hypotheses exclude the two actions the LP.7 exemption
    admits regardless of policy.  The remaining gap — barring
    `gasPoolActor` from the meta-actions themselves — is closed by a
    complementary `AuthorityPolicy` at genesis (GP.7.4), not by this
    `LocalPolicy`. -/
theorem gasPoolPolicy_admission_denies_non_transfer_non_meta
    (es : ExtendedState) (action : Action)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (hpol : es.localPolicies.lookup gasPoolActor =
            gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold)
    (htag : Action.tag action ≠ 0)
    (hmeta : Authority.isMetaPolicyAction action = false) :
    ¬ Authority.localPolicyPermits es gasPoolActor action := by
  rw [gasPoolPolicy_admission_permits_iff es action
        maxDrainPerActionEth maxDrainPerActionBold hpol]
  rintro (hm | hp)
  · rw [hmeta] at hm; exact Bool.noConfusion hm
  · exact gasPoolPolicy_denies_all_non_transfer
      maxDrainPerActionEth maxDrainPerActionBold action htag hp

/-- **The meta-action escape hatch is real (the boundary, proven).**
    Even when `gasPoolActor`'s declared policy is `gasPoolPolicy`, the
    kernel's admission conjunct PERMITS `revokeLocalPolicy` and every
    `declareLocalPolicy p` — the LP.7 meta-action exemption fires
    regardless of the declared policy.  So `gasPoolActor` can remove
    its own `gasPoolPolicy` restriction (revoke, or declare a weaker
    policy) unless a complementary `AuthorityPolicy` withholds
    meta-action authority from it.  This theorem proves the hole
    exists rather than describing it in prose — it is the formal
    justification for the GP.7.4 `AuthorityPolicy` requirement. -/
theorem gasPoolPolicy_admission_permits_meta_actions
    (es : ExtendedState)
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (_hpol : es.localPolicies.lookup gasPoolActor =
            gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold) :
    Authority.localPolicyPermits es gasPoolActor .revokeLocalPolicy ∧
    (∀ p, Authority.localPolicyPermits es gasPoolActor (.declareLocalPolicy p)) := by
  refine ⟨Or.inl rfl, fun p => Or.inl rfl⟩

/-! ## Sender blindness of the `LocalPolicy` (a real gap, closed elsewhere)

`gasPoolPolicy`'s clauses key off the action's RESOURCE, RECIPIENT,
and AMOUNT — never its `sender` field.  So the `LocalPolicy` permits a
`gasPoolActor`-signed `transfer 0 victim sequencerActor amount`
(sender ≠ gasPoolActor) exactly as it permits the canonical
`transfer 0 gasPoolActor sequencerActor amount`.  This is inherent to
the `LocalPolicyClause` vocabulary, which has no sender-binding clause.

**This is NOT harmless, and must not be mistaken for harmless.**  The
kernel `transfer` law debits the action's `sender` field, and
`AdmissibleWith` verifies only `st.signer`'s signature (never
`signer = sender`).  So a `gasPoolActor`-signed transfer whose `sender`
is a victim debits the VICTIM's balance — a held pool key could drain
an arbitrary actor's funds to the sequencer.  The `LocalPolicy`
genuinely cannot prevent this (no clause vocabulary for the sender);
the fix lives at the `AuthorityPolicy` layer, where
`gasPoolActorAuthorized` binds `sender = gasPoolActor` on both gas legs
(`gasPoolAuthorityPolicy_rejects_non_pool_sender`).  The theorem below
therefore records a *fact about the `LocalPolicy` in isolation* (its
verdict ignores the sender) — explicitly so a reader does NOT conclude
`gasPoolPolicy` alone is sufficient; the genesis wiring MUST intersect
`gasPoolAuthorityPolicy` to obtain sender-safety. -/

/-- **`LocalPolicy` sender blindness (isolated fact, not a safety
    guarantee).**  `gasPoolPolicy`'s verdict on a transfer does not
    depend on the `sender` field: if it permits a transfer with one
    sender it permits the same transfer (same resource / recipient /
    amount) with any other sender.  This documents that the
    `LocalPolicy` CANNOT pin the sender — fund-safety against
    victim-balance drains comes from the complementary
    `gasPoolAuthorityPolicy` (`_rejects_non_pool_sender`), NOT from this
    policy.  Stated so the blindness is impossible to overlook. -/
theorem gasPoolPolicy_transfer_sender_independent
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (r : ResourceId) (sender sender' receiver : ActorId) (amount : Amount)
    (hp : (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
            gasPoolActor (.transfer r sender receiver amount)) :
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold).permits
        gasPoolActor (.transfer r sender' receiver amount) := by
  rw [gasPoolPolicy_permits_transfer_iff] at hp ⊢
  exact hp

/-! ## Canonical-encoding boundedness (GP.7.4 genesis prerequisite)

For GP.7.4 to declare `gasPoolPolicy` at genesis (a
`declareLocalPolicy` whose payload must round-trip through the LP.2
CBE codec and pass the §3.0 DoS bounds), the policy must satisfy
`LocalPolicy.fieldsBounded`.  `gasPoolPolicy` has 5 clauses (≤ 64),
two singleton recipient lists (≤ 64), and two `capAmount` clauses
whose bound is `< 2^64`.  The theorem below discharges
`fieldsBounded` exactly when both caps are below `2^64` — the
realistic regime (a cap is a `UInt64`-range wei/BOLD amount).  This
is the prerequisite the genesis declaration's encode/round-trip
rests on. -/

/-- **Canonical boundedness.**  `gasPoolPolicy` satisfies
    `LocalPolicy.fieldsBounded` whenever both per-leg caps are below
    `2^64` (`256 ^ 8`).  The clause count (5) and the singleton
    recipient lists are unconditionally within the §3.0 caps; the
    only data-dependent obligation is the `capAmount` bound, which
    holds for any cap in `UInt64` range — the realistic regime for a
    wei / BOLD-denominated per-action cap. -/
theorem gasPoolPolicy_fieldsBounded
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (hEth : maxDrainPerActionEth < 256 ^ 8)
    (hBold : maxDrainPerActionBold < 256 ^ 8) :
    Encoding.LocalPolicy.fieldsBounded
      (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold) := by
  -- `fieldsBounded` is a conjunction: clause-count ≤ 64, and every
  -- clause's own `fieldsBounded` holds.  Unfold the policy to its
  -- concrete 5-clause list so the count and the per-clause `.all`
  -- reduce.
  unfold Encoding.LocalPolicy.fieldsBounded gasPoolPolicy
  refine ⟨?_, ?_⟩
  · -- Clause count: the literal 5-clause list has `length = 5 ≤ 64`.
    -- Reduce `.length` to the literal `5` (independent of the cap
    -- values) before deciding, so no free variable reaches `decide`.
    show List.length _ ≤ LocalPolicy.MAX_CLAUSES_PER_POLICY
    simp only [List.length_cons, List.length_nil]
    decide
  · -- The `.all` over the 5 concrete clauses is a `&&`-chain of
    -- per-clause `decide (fieldsBounded cᵢ)`.  Split the chain into a
    -- `∧` of `decide … = true` facts, then turn each back into its
    -- underlying `Prop` via `decide_eq_true_eq`, and unfold the
    -- per-clause `fieldsBounded`.
    simp only [List.all_cons, List.all_nil, Bool.and_true,
      Bool.and_eq_true, decide_eq_true_eq,
      Encoding.LocalPolicyClause.fieldsBounded]
    -- Goal: (denyTags bound) ∧ (req₀ len) ∧ (cap₀) ∧ (req₁ len) ∧ (cap₁).
    refine ⟨⟨by decide, ?_⟩, by decide, hEth, by decide, hBold⟩
    -- denyTags: every tag in `(List.range 23).filter (· ≠ 0)` is < 2^64.
    apply List.all_eq_true.mpr
    intro n hn
    have hlt : n < 23 := by
      have := List.mem_filter.mp hn |>.1
      simpa using List.mem_range.mp this
    exact decide_eq_true (by omega)

/-- **CBE round-trip.**  `gasPoolPolicy` round-trips through the LP.2
    canonical encoder under the same `< 2^64` cap hypotheses: decoding
    `Encodable.encode gasPoolPolicy` reproduces the policy with an
    empty suffix.  This is the concrete genesis-declaration
    prerequisite (GP.7.4 will declare the policy via a
    `declareLocalPolicy` whose payload is exactly these bytes). -/
theorem gasPoolPolicy_roundtrip
    (maxDrainPerActionEth maxDrainPerActionBold : Amount)
    (hEth : maxDrainPerActionEth < 256 ^ 8)
    (hBold : maxDrainPerActionBold < 256 ^ 8) :
    Encodable.decode (T := LocalPolicy)
        (Encodable.encode
          (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold)) =
      .ok (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold, []) :=
  Encoding.localPolicy_roundtrip_empty
    (gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold)
    (gasPoolPolicy_fieldsBounded maxDrainPerActionEth maxDrainPerActionBold hEth hBold)

/-! Note on the round-trip statement above: `Encodable.decode` here is
`LegalKernel.Encoding.Encodable.decode` (opened at the top of the
module) and its `Except`-typed result's success constructor is `.ok`,
matching the LP.2 `localPolicy_roundtrip_empty` lemma's conclusion
verbatim. -/

/-! ## Closing the meta-action hole: the complementary `AuthorityPolicy`

`gasPoolPolicy` is a `LocalPolicy`, and the LP.7 meta-action exemption
means a `LocalPolicy` structurally CANNOT bind `gasPoolActor`'s
authority to sign `declareLocalPolicy` / `revokeLocalPolicy` (proven:
`gasPoolPolicy_admission_permits_meta_actions`).  Left there, a
`gasPoolActor` key could revoke its own `gasPoolPolicy` and then drain
the pool freely.

The fix lives at the OTHER admissibility conjunct.  `AdmissibleWith`
is a conjunction of an `AuthorityPolicy.authorized` check AND the
meta-exempt `localPolicyPermits` check; the meta-action exemption
relaxes ONLY the latter.  So an `AuthorityPolicy` that withholds
meta-action authority from `gasPoolActor` blocks the escape hatch —
the authority conjunct has no exemption.

`gasPoolAuthorityPolicy` is that policy, designed to be intersected
with the deployment's base policy
(`deploymentPolicy.intersect gasPoolAuthorityPolicy`):

  * For `signer = gasPoolActor`: authorise EXACTLY a capped `transfer`
    to `sequencerActor` on a gas leg (resource `0` / `1`) — the same
    surface `gasPoolPolicy` permits, but now also barring meta-actions
    AND the resource-`≥ 2` transfers the `LocalPolicy` left open
    (closing both holes at the authority layer).
  * For `signer ≠ gasPoolActor`: authorise everything (`True`), so the
    intersection is a no-op on every other actor — the deployment's
    base policy is the sole authority for non-pool actors.

Intersecting (rather than unioning) is the correct combinator: an
action is admissible under `intersect P Q` iff BOTH authorise it, so
the gas-pool restriction can only ever NARROW the deployment policy,
never widen it. -/

/-- The authority predicate restricting `gasPoolActor`: it may sign
    EXACTLY a capped `transfer` whose `sender` is `gasPoolActor`
    itself, to `sequencerActor`, on resource `0` (ETH, cap `mEth`) or
    resource `1` (BOLD, cap `mBold`); every other `gasPoolActor` action
    — including the meta-actions the LP.7 exemption would otherwise
    admit, transfers on any other resource or to any other recipient,
    AND transfers whose `sender` is some OTHER actor — is unauthorised.
    Other signers are authorised unconditionally (the deployment's base
    policy governs them after intersection).

    **The `sender = gasPoolActor` conjunct is load-bearing for
    fund-safety.**  The kernel `transfer` law debits the action's
    `sender` field, and `AdmissibleWith` verifies only `st.signer`'s
    signature (never `signer = sender`).  Without binding the sender
    here, a held `gasPoolActor` key could sign
    `.transfer r victim sequencerActor amount` and drain an ARBITRARY
    actor's balance to the sequencer (the signature is `gasPoolActor`'s
    own, the policy ignored `sender`, and the law debits `victim`).
    The companion `LocalPolicy` (`gasPoolPolicy`) structurally cannot
    bind the sender — its `LocalPolicyClause` vocabulary keys only on
    resource / recipient / amount — so this `AuthorityPolicy` is the
    one place the sender can be pinned, and it MUST. -/
def gasPoolActorAuthorized (mEth mBold : Amount) : ActorId → Action → Prop :=
  fun signer action =>
    if signer = gasPoolActor then
      match action with
      | .transfer r sender receiver amount =>
          (r = 0 ∧ sender = gasPoolActor ∧ receiver = sequencerActor ∧ amount ≤ mEth) ∨
          (r = 1 ∧ sender = gasPoolActor ∧ receiver = sequencerActor ∧ amount ≤ mBold)
      | _ => False
    else True

/-- Decidability of `gasPoolActorAuthorized` (each branch is a finite
    conjunction / disjunction of decidable comparisons). -/
instance gasPoolActorAuthorized_decidable (mEth mBold : Amount)
    (signer : ActorId) (action : Action) :
    Decidable (gasPoolActorAuthorized mEth mBold signer action) := by
  unfold gasPoolActorAuthorized
  by_cases h : signer = gasPoolActor
  · rw [if_pos h]; cases action <;> infer_instance
  · rw [if_neg h]; infer_instance

/-- **The complementary `AuthorityPolicy` (closes the meta-action
    hole).**  Intersect this with the deployment's base policy at
    genesis (`deploymentPolicy.intersect gasPoolAuthorityPolicy`).  It
    restricts `gasPoolActor` to a capped sequencer transfer and leaves
    every other actor unconstrained.  Unlike `gasPoolPolicy` (a
    `LocalPolicy`, subject to the LP.7 meta-action exemption), this
    sits at the `AuthorityPolicy` conjunct of `AdmissibleWith`, which
    has NO meta-action exemption — so it genuinely bars `gasPoolActor`
    from `declareLocalPolicy` / `revokeLocalPolicy`. -/
def gasPoolAuthorityPolicy (mEth mBold : Amount) : AuthorityPolicy where
  authorized := gasPoolActorAuthorized mEth mBold
  decAuth    := fun _ _ => inferInstance

/-- **The authority policy bars `gasPoolActor` meta-actions.**  Closes
    the hole `gasPoolPolicy_admission_permits_meta_actions` exposed:
    `gasPoolAuthorityPolicy` does NOT authorise `gasPoolActor` to sign
    `revokeLocalPolicy` or any `declareLocalPolicy`.  Intersected into
    the deployment policy, this removes the escape hatch by which a
    pool key could wipe its own `gasPoolPolicy`. -/
theorem gasPoolAuthorityPolicy_rejects_meta
    (mEth mBold : Amount) :
    ¬ (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor .revokeLocalPolicy ∧
    (∀ p, ¬ (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor
              (.declareLocalPolicy p)) :=
  -- `signer = gasPoolActor` (`rfl`) takes the `then` branch; both
  -- meta constructors hit the `_ => False` arm, so `authorized` is
  -- definitionally `False` and the negation is `id`/`fun h => h`.
  ⟨id, fun _ => id⟩

/-- **The authority policy bars every non-transfer `gasPoolActor`
    action.**  Exhaustively: any action whose tag is not `0` is
    unauthorised for `gasPoolActor` under `gasPoolAuthorityPolicy`
    (the `match` has `False` on every non-`transfer` arm).  The
    authority-layer analogue of `gasPoolPolicy_denies_all_non_transfer`
    — and strictly stronger, since it also covers the meta-actions. -/
theorem gasPoolAuthorityPolicy_rejects_non_transfer
    (mEth mBold : Amount) (action : Action) (h : Action.tag action ≠ 0) :
    ¬ (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor action := by
  intro hauth
  -- `signer = gasPoolActor` takes the `then` branch.  Every non-transfer
  -- constructor hits the `_ => False` arm (so `hauth : False`); the lone
  -- `transfer` arm has tag 0, excluded by `h`.
  cases action <;> first | exact absurd rfl h | exact hauth

/-- **The authority policy authorises the legitimate capped sequencer
    claim** — ETH leg.  `gasPoolActor` may sign a `transfer` over
    resource `0` *from its own balance* (`sender = gasPoolActor`) to
    `sequencerActor` within `mEth`.  The `sender` is fixed to
    `gasPoolActor`: the legitimate drain moves the POOL's funds, and
    the policy now refuses to authorise a transfer of any OTHER actor's
    balance (the fund-safety fix). -/
theorem gasPoolAuthorityPolicy_authorizes_sequencer_eth
    (mEth mBold : Amount) (amount : Amount)
    (h : amount ≤ mEth) :
    (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor
      (.transfer 0 gasPoolActor sequencerActor amount) :=
  -- `signer = gasPoolActor` (`rfl`) takes the `then` branch; the
  -- literal `transfer 0 gasPoolActor sequencerActor` matches the ETH
  -- disjunct definitionally (resource, sender, recipient all `rfl`).
  Or.inl ⟨rfl, rfl, rfl, h⟩

/-- **The authority policy authorises the legitimate capped sequencer
    claim** — BOLD leg.  The resource-`1` mirror of
    `gasPoolAuthorityPolicy_authorizes_sequencer_eth`; `sender` is
    likewise fixed to `gasPoolActor`. -/
theorem gasPoolAuthorityPolicy_authorizes_sequencer_bold
    (mEth mBold : Amount) (amount : Amount)
    (h : amount ≤ mBold) :
    (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor
      (.transfer 1 gasPoolActor sequencerActor amount) :=
  Or.inr ⟨rfl, rfl, rfl, h⟩

/-- **The authority policy bars the resource-`≥ 2` transfers the
    `LocalPolicy` left open.**  Closes gap-2 at the authority layer:
    a `gasPoolActor` `transfer` over any resource other than `0` / `1`
    is unauthorised regardless of recipient / amount — so the
    intersected policy does NOT rely on the pool-balance invariant for
    off-leg resources (it forbids them outright). -/
theorem gasPoolAuthorityPolicy_rejects_off_gas_legs
    (mEth mBold : Amount) (r : ResourceId) (sender receiver : ActorId)
    (amount : Amount) (h0 : r ≠ 0) (h1 : r ≠ 1) :
    ¬ (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor
        (.transfer r sender receiver amount) := by
  -- `signer = gasPoolActor` takes the `then` branch; the `transfer`
  -- arm is the disjunction, whose both disjuncts fix `r = 0` / `r = 1`.
  intro hauth
  rcases (show _ ∨ _ from hauth) with ⟨hr, _, _, _⟩ | ⟨hr, _, _, _⟩
  · exact h0 hr
  · exact h1 hr

/-- **The authority policy bars a `gasPoolActor` transfer to any
    non-sequencer recipient.**  The authority-layer analogue of the
    `requireRecipientIn` clauses, on both gas legs at once. -/
theorem gasPoolAuthorityPolicy_rejects_non_sequencer
    (mEth mBold : Amount) (r : ResourceId) (sender receiver : ActorId)
    (amount : Amount) (h : receiver ≠ sequencerActor) :
    ¬ (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor
        (.transfer r sender receiver amount) := by
  intro hauth
  rcases (show _ ∨ _ from hauth) with ⟨_, _, hrcv, _⟩ | ⟨_, _, hrcv, _⟩ <;> exact h hrcv

/-- **The authority policy bars a `gasPoolActor`-signed transfer whose
    `sender` is some OTHER actor.**  This is the fund-safety theorem
    (PR #106 review): the kernel `transfer` law debits the action's
    `sender`, and `AdmissibleWith` checks only `st.signer`'s signature,
    so without this restriction a held `gasPoolActor` key could move an
    arbitrary victim's balance to the sequencer.  `gasPoolAuthorityPolicy`
    authorises a `gasPoolActor`-signed transfer ONLY when its `sender`
    is `gasPoolActor` itself — i.e. the pool can only ever move its OWN
    funds.  A transfer whose `sender ≠ gasPoolActor` is rejected on both
    legs (and, via the resource / recipient theorems, off-leg and to
    non-sequencers too). -/
theorem gasPoolAuthorityPolicy_rejects_non_pool_sender
    (mEth mBold : Amount) (r : ResourceId) (sender receiver : ActorId)
    (amount : Amount) (h : sender ≠ gasPoolActor) :
    ¬ (gasPoolAuthorityPolicy mEth mBold).authorized gasPoolActor
        (.transfer r sender receiver amount) := by
  intro hauth
  rcases (show _ ∨ _ from hauth) with ⟨_, hsnd, _, _⟩ | ⟨_, hsnd, _, _⟩ <;> exact h hsnd

/-- **The intersection is a no-op on non-pool actors.**  For any
    `signer ≠ gasPoolActor`, intersecting `gasPoolAuthorityPolicy`
    into a base policy `P` leaves that signer's authority exactly `P`'s
    — the restriction is scoped solely to `gasPoolActor`.  This is what
    makes `P.intersect (gasPoolAuthorityPolicy …)` the correct genesis
    wiring: it narrows the pool actor and touches nothing else. -/
theorem gasPoolAuthorityPolicy_other_actors_unrestricted
    (mEth mBold : Amount) (P : AuthorityPolicy)
    (signer : ActorId) (action : Action) (h : signer ≠ gasPoolActor) :
    (P.intersect (gasPoolAuthorityPolicy mEth mBold)).authorized signer action ↔
      P.authorized signer action := by
  unfold AuthorityPolicy.intersect gasPoolAuthorityPolicy gasPoolActorAuthorized
  simp only [if_neg h, and_true]

/-- **Genesis-wiring guarantee: meta-actions are barred under the
    intersected policy.**  For ANY base deployment policy `P`,
    `P.intersect gasPoolAuthorityPolicy` rejects `gasPoolActor`-signed
    `revokeLocalPolicy` / `declareLocalPolicy`.  This is the
    end-to-end statement GP.7.4 ratifies: regardless of what the
    deployment authorises, the gas-pool key cannot manage local
    policies, so it cannot wipe its own `gasPoolPolicy`. -/
theorem gasPoolAuthorityPolicy_intersect_rejects_meta
    (mEth mBold : Amount) (P : AuthorityPolicy) :
    ¬ (P.intersect (gasPoolAuthorityPolicy mEth mBold)).authorized
        gasPoolActor .revokeLocalPolicy ∧
    (∀ p, ¬ (P.intersect (gasPoolAuthorityPolicy mEth mBold)).authorized
              gasPoolActor (.declareLocalPolicy p)) := by
  refine ⟨?_, fun p => ?_⟩
  · intro ⟨_, hq⟩
    exact (gasPoolAuthorityPolicy_rejects_meta mEth mBold).1 hq
  · intro ⟨_, hq⟩
    exact (gasPoolAuthorityPolicy_rejects_meta mEth mBold).2 p hq

end Bridge
end LegalKernel

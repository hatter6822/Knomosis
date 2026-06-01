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
`gasPoolPolicy_denies_all_non_transfer`, whose `cases action` proof
fails to elaborate the moment an Action constructor whose tag is
`≥ 23` is added — turning a forgotten range bump into a build break
rather than a silent pool-outflow escalation.

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

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

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

    A `gasPoolActor`-signed action passes this policy iff it is a
    `transfer` AND, for whichever of resources 0 / 1 it is over, the
    recipient is `sequencerActor` and the amount is within that
    leg's cap (`gasPoolPolicy_permits_transfer_iff`).  A transfer
    over any other resource is unconstrained by the per-leg clauses,
    but the pool holds no such resource, so it can only ever move a
    zero balance. -/
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

end Bridge
end LegalKernel

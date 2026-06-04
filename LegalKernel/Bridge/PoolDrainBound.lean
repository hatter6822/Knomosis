-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.PoolDrainBound — Workstream GP.7.3 (+ GP.7.5 core).

Proves the **per-epoch pool-drain bound** is a kernel invariant given
the canonical gas-pool authority discipline (GP.7.2): across any
contiguous trace of `n` admitted `SignedAction`s, the gas-pool actor's
balance at a gas leg (`ResourceId 0` = ETH, `ResourceId 1` = BOLD)
cannot have decreased by more than `n × legCap`.

The bound is proven **per-resource** (`pool_drain_bounded_by_action_count_per_resource`),
with the ETH and BOLD legs as specialisations, and the two legs are
shown to be independent accounting domains
(`per_resource_pool_independence`).

## Why the bound rests on the AuthorityPolicy, not the LocalPolicy

The GP.7.2 audit established that the bare `LocalPolicy` (`gasPoolPolicy`)
is insufficient on its own: it is *sender-blind* (cannot distinguish a
pool-draining `transfer 0 gasPoolActor …` from a victim-draining one —
the kernel `transfer` law debits the action's `sender`, not the signer)
and subject to the *LP.7 meta-action exemption* (cannot keep itself in
force across a trace).  GP.7.2 closed both holes with the complementary
`gasPoolAuthorityPolicy` (intersected into the deployment policy at
genesis, GP.7.4).  The drain bound's per-step controlling facts are
therefore stated in terms of that authority discipline.

## Two ways to drive a trace

  * `PoolBoundedTrace` — the idiomatic inductive trace relation (the
    type-safe analogue of `applyTrace … = some es'`, mirroring the
    kernel's `Reachable`), carrying the two per-step facts.
  * `applyTrace` — the literal executable `Option`-valued fold the plan
    sketched.  `applyTrace_drain_bounded_per_resource` proves the bound
    directly over it (and `applyTrace_yields_poolBoundedTrace` bridges
    the two).

## The external (non-pool-signer) obligation

The plan's case "(a) not signed by `gasPoolActor` ⇒ no decrease" is the
deployment's `sender = signer` discipline — NOT vacuous (under
`AuthorityPolicy.unrestricted` an arbitrary actor could drain the pool).
It is discharged *exhaustively* over every `Action` constructor by
`pool_nondecreasing_of_does_not_debit`: the decidable predicate
`Action.doesNotDebitPoolAt` captures exactly when a step cannot lower the
pool's balance at a leg (credit-only / no-op actions always qualify;
`topUp*` qualify when the signer is not the pool; `transfer` / `burn` /
`withdraw` qualify when their source field is not the pool), and a
non-pool signer's step discharges it automatically under a self-source
deployment discipline.

## A note on the arithmetic helpers

`omega` cannot atomise `Amount`-typed (`= Nat`) terms — the same
limitation `Laws.Transfer`'s `transfer_arithmetic` works around — so the
linear algebra is discharged through small `Nat`-parameter helper lemmas
applied to the `Amount`-valued balances.  The public bound theorems are
stated in the plan's `≥` orientation (definitionally the `≤` form the
proofs use).

This module is **not** part of the kernel TCB.
-/

import LegalKernel.Bridge.BridgeActor
import LegalKernel.Bridge.GasPoolPolicy
import LegalKernel.Bridge.Admissible
import LegalKernel.Authority.SignedAction
import LegalKernel.Laws.Transfer

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## `Nat`-arithmetic helpers

`omega` does not surface `Amount`-typed (`= Nat`) atoms, so the linear
algebra of the drain bound is discharged here over explicit `Nat`
parameters and applied to the `Amount` balances at the call sites (the
`Laws.Transfer.transfer_arithmetic` pattern). -/

/-- A debit of `amount ≤ bal` capped at `amount ≤ cap` leaves at least
    `bal − cap` behind: `bal ≤ (bal − amount) + cap`.  The per-step
    leg drain inequality, over `Nat`. -/
private theorem drain_eth_step_arith
    (bal amount cap : Nat) (h1 : amount ≤ bal) (h2 : amount ≤ cap) :
    bal ≤ bal - amount + cap := by omega

/-- Compose a per-step drain with the running trace bound: from
    `a ≤ b + x` and `b ≤ c + y` and `total = x + y`, conclude
    `a ≤ c + total`.  The induction step of the trace bound, over
    `Nat`. -/
private theorem trace_drain_arith
    (a b c x y total : Nat)
    (h1 : a ≤ b + x) (h2 : b ≤ c + y) (h3 : total = x + y) :
    a ≤ c + total := by omega

/-- Restate an additive bound `a ≤ b + c` as the floored lower bound
    `a − c ≤ b`.  Turns the drain bound into a surviving-balance floor,
    over `Nat`. -/
private theorem lower_bound_drain_arith
    (a b c : Nat) (h : a ≤ b + c) : a - c ≤ b := by omega

/-! ## Per-leg cap selector -/

/-- The per-action drain cap for resource `r`: `maxDrainPerActionEth`
    for the ETH leg (`r = 0`), `maxDrainPerActionBold` otherwise.  Only
    the two gas legs `{0, 1}` are meaningful; the `else` branch is never
    reached by an authorised pool transfer (which is on `0` or `1`). -/
def legCap (mEth mBold : Amount) (r : ResourceId) : Amount :=
  if r = 0 then mEth else mBold

/-- `legCap` on the ETH leg is the ETH cap. -/
@[simp] theorem legCap_zero (mEth mBold : Amount) : legCap mEth mBold 0 = mEth := rfl

/-- `legCap` on the BOLD leg is the BOLD cap. -/
@[simp] theorem legCap_one (mEth mBold : Amount) : legCap mEth mBold 1 = mBold := by
  simp [legCap]

/-! ## Generic non-decrease infrastructure

These resource/actor-generic facts feed both the per-step drain bound
(`gasPoolActor`-signed steps) and the exhaustive external discharge. -/

/-- If a transition's `apply_impl` does not decrease the `(r, a)` cell,
    then neither does its `step_impl` (the precondition-gated step is
    either the apply, or a no-op when the precondition fails). -/
theorem step_impl_nondecreasing_of_apply_nondecreasing
    (s : State) (t : Transition) (r : ResourceId) (a : ActorId)
    (happly : getBalance s r a ≤ getBalance (t.apply_impl s) r a) :
    getBalance s r a ≤ getBalance (step_impl s t) r a := by
  unfold step_impl
  by_cases hpre : t.pre s
  · rw [if_pos hpre]; exact happly
  · rw [if_neg hpre]; exact Nat.le_refl _

/-- Crediting `(rWrite, to)` by `δ` does not decrease the `(rRead, a)`
    cell: either the credited cell is the read cell (balance rises by
    `δ`) or it is a different cell (balance unchanged). -/
theorem getBalance_credit_nondecreasing
    (s : State) (rWrite rRead : ResourceId) (to a : ActorId) (δ : Amount) :
    getBalance s rRead a ≤
      getBalance (setBalance s rWrite to (getBalance s rWrite to + δ)) rRead a := by
  by_cases hcell : rWrite = rRead ∧ to = a
  · obtain ⟨h1, h2⟩ := hcell; subst h1; subst h2
    rw [getBalance_setBalance_same]; exact Nat.le_add_right _ _
  · rw [getBalance_setBalance_other s rWrite rRead to a _ ?_]
    · exact Nat.le_refl _
    · by_cases h1 : rWrite = rRead
      · exact Or.inr (fun h2 => hcell ⟨h1, h2⟩)
      · exact Or.inl h1

/-- A left fold of per-actor self-credits (`setBalance s' r kv.1
    (newVal s' kv)` with `newVal ≥` the prior balance) does not decrease
    any `(rRead, a)` cell.  This is the per-actor monotonicity the
    `distributeOthers` / `proportionalDilute` fold-of-credits laws need
    (their `IsMonotonic` instances are `TotalSupply`-level, not
    per-actor). -/
theorem getBalance_foldl_credit_nondecreasing
    (r rRead : ResourceId) (a : ActorId)
    (newVal : State → ActorId × Amount → Amount)
    (hcredit : ∀ (s' : State) (kv : ActorId × Amount),
      getBalance s' r kv.1 ≤ newVal s' kv)
    (xs : List (ActorId × Amount)) (s : State) :
    getBalance s rRead a ≤
      getBalance (xs.foldl (fun s' kv => setBalance s' r kv.1 (newVal s' kv)) s) rRead a := by
  induction xs generalizing s with
  | nil => exact Nat.le_refl _
  | cons x xs ih =>
      refine Nat.le_trans ?_ (ih (setBalance s r x.1 (newVal s x)))
      by_cases hcell : rRead = r ∧ a = x.1
      · obtain ⟨h1, h2⟩ := hcell; subst h1; subst h2
        rw [getBalance_setBalance_same]; exact hcredit s x
      · rw [getBalance_setBalance_other s r rRead x.1 a (newVal s x) ?_]
        · exact Nat.le_refl _
        · by_cases h1 : rRead = r
          · exact Or.inr (fun h2 => hcell ⟨h1, h2.symm⟩)
          · exact Or.inl (fun h2 => h1 h2.symm)

/-! ## Decomposing the gas-pool authority restriction -/

/-- An action authorised for `gasPoolActor` by `gasPoolActorAuthorized`
    is a `transfer` from `gasPoolActor` to `sequencerActor`, capped per
    leg: either resource `0` with amount `≤ mEth`, or resource `1` with
    amount `≤ mBold`. -/
theorem gasPoolActorAuthorized_gasPool_imp_transfer
    (mEth mBold : Amount) (action : Action)
    (h : gasPoolActorAuthorized mEth mBold gasPoolActor action) :
    ∃ r sender receiver amount, action = .transfer r sender receiver amount ∧
      ((r = 0 ∧ sender = gasPoolActor ∧ receiver = sequencerActor ∧ amount ≤ mEth) ∨
       (r = 1 ∧ sender = gasPoolActor ∧ receiver = sequencerActor ∧ amount ≤ mBold)) := by
  simp only [gasPoolActorAuthorized, if_pos] at h
  cases action
  case transfer r sender receiver amount =>
    exact ⟨r, sender, receiver, amount, rfl, h⟩
  all_goals exact (h : False).elim

/-! ## Pool-transfer leg arithmetic

A `gasPoolActor → sequencerActor` transfer over resource `r` debits the
pool by `amount` on leg `r` and leaves every other leg untouched.  These
two facts are the per-leg ingredients of the drain bound and the two-leg
independence theorems. -/

/-- A pool transfer over resource `r` reads back as a debit on the SAME
    leg: the pool's leg-`r` balance falls by exactly `amount` (the credit
    lands on `sequencerActor ≠ gasPoolActor`). -/
theorem getBalance_pool_transfer_self_leg
    (s : State) (r : ResourceId) (amount : Amount) :
    getBalance ((Laws.transfer r gasPoolActor sequencerActor amount).apply_impl s)
        r gasPoolActor = getBalance s r gasPoolActor - amount := by
  simp only [Laws.transfer]
  rw [getBalance_setBalance_other _ r r sequencerActor gasPoolActor _
        (Or.inr sequencerActor_ne_gasPoolActor)]
  rw [getBalance_setBalance_same]

/-- A pool transfer over resource `r` leaves every OTHER leg `rRead ≠ r`
    of the pool untouched (per-resource locality).  This is the engine of
    the two-leg independence theorems. -/
theorem getBalance_pool_transfer_other_leg
    (s : State) (r rRead : ResourceId) (amount : Amount) (hne : r ≠ rRead) :
    getBalance ((Laws.transfer r gasPoolActor sequencerActor amount).apply_impl s)
        rRead gasPoolActor = getBalance s rRead gasPoolActor := by
  simp only [Laws.transfer]
  rw [getBalance_setBalance_other _ r rRead sequencerActor gasPoolActor _ (Or.inl hne)]
  rw [getBalance_setBalance_other _ r rRead gasPoolActor gasPoolActor _ (Or.inl hne)]

/-! ## The per-step drain bound (per-resource)

A single admitted `gasPoolActor`-signed step decreases the pool's
balance at any leg `rLeg` by at most `legCap mEth mBold rLeg`.  Either
the authorised transfer is on `rLeg` (debit `≤` that leg's cap) or on the
other leg (no change to `rLeg`). -/

/-- **Per-step drain bound (any leg).**  For an admitted step signed by
    `gasPoolActor` whose action is authorised by `gasPoolActorAuthorized`,
    the pre-state pool balance at leg `rLeg` is at most the post-state
    balance plus `legCap mEth mBold rLeg`. -/
theorem pool_signed_step_drain_le
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount) (rLeg : ResourceId)
    (h : AdmissibleWith verify P d es st)
    (hsigner : st.signer = gasPoolActor)
    (hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action) :
    getBalance es.base rLeg gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base rLeg gasPoolActor
        + legCap mEth mBold rLeg := by
  have hpre : (Action.compile st.action).transition.pre es.base := h.2.2.2.1
  obtain ⟨r, sender, receiver, amount, hst, hdisj⟩ :=
    gasPoolActorAuthorized_gasPool_imp_transfer mEth mBold st.action hauth
  rw [apply_admissible_with_base, hst, hsigner]
  rw [hst] at hpre
  have hpreT : (Laws.transfer r sender receiver amount).pre es.base := hpre
  show getBalance es.base rLeg gasPoolActor ≤
    getBalance (step_impl es.base (Laws.transfer r sender receiver amount)) rLeg gasPoolActor
      + legCap mEth mBold rLeg
  unfold step_impl
  rw [if_pos hpreT]
  -- Resolve the authorised transfer's sender / receiver.
  have hsr : sender = gasPoolActor ∧ receiver = sequencerActor := by
    rcases hdisj with ⟨_, hs, hr, _⟩ | ⟨_, hs, hr, _⟩ <;> exact ⟨hs, hr⟩
  obtain ⟨hs, hrcv⟩ := hsr; subst hs; subst hrcv
  by_cases hrr : rLeg = r
  · -- bounding the same leg the transfer drains
    subst hrr
    rw [getBalance_pool_transfer_self_leg es.base rLeg amount]
    have hbal : amount ≤ getBalance es.base rLeg gasPoolActor := hpreT.1
    have hcap : amount ≤ legCap mEth mBold rLeg := by
      rcases hdisj with ⟨hr0, _, _, ha⟩ | ⟨hr1, _, _, ha⟩
      · rw [hr0]; simpa using ha
      · rw [hr1]; simpa using ha
    exact drain_eth_step_arith _ amount (legCap mEth mBold rLeg) hbal hcap
  · -- bounding the other leg: the pool's `rLeg` balance is untouched
    rw [getBalance_pool_transfer_other_leg es.base r rLeg amount (fun he => hrr he.symm)]
    exact Nat.le_add_right _ _

/-- **Per-step ETH-leg drain bound.**  The `rLeg = 0` specialisation of
    `pool_signed_step_drain_le`. -/
theorem pool_signed_step_drain_le_eth
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount)
    (h : AdmissibleWith verify P d es st)
    (hsigner : st.signer = gasPoolActor)
    (hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action) :
    getBalance es.base 0 gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base 0 gasPoolActor + mEth := by
  have := pool_signed_step_drain_le verify P d es st mEth mBold 0 h hsigner hauth
  simpa using this

/-- **Per-step BOLD-leg drain bound.**  The `rLeg = 1` specialisation of
    `pool_signed_step_drain_le`. -/
theorem pool_signed_step_drain_le_bold
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount)
    (h : AdmissibleWith verify P d es st)
    (hsigner : st.signer = gasPoolActor)
    (hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action) :
    getBalance es.base 1 gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base 1 gasPoolActor + mBold := by
  have := pool_signed_step_drain_le verify P d es st mEth mBold 1 h hsigner hauth
  simpa using this

/-! ## Two-leg independence (GP.7.5 core)

The two gas legs are independent accounting domains: a pool transfer on
one leg leaves the other leg's pool balance EXACTLY unchanged.  These
follow from the per-resource locality of `transfer`. -/

/-- **ETH leg independent of BOLD actions.**  A pool transfer over the
    BOLD leg (`resource 1`) leaves the pool's ETH-leg (`resource 0`)
    balance unchanged. -/
theorem pool_balance_eth_leg_independent_of_bold_actions
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (amount : Amount)
    (h : AdmissibleWith verify P d es st)
    (hsigner : st.signer = gasPoolActor)
    (hst : st.action = .transfer 1 gasPoolActor sequencerActor amount)
    (hpre : (Laws.transfer 1 gasPoolActor sequencerActor amount).pre es.base) :
    getBalance (apply_admissible_with verify P d es st h).base 0 gasPoolActor =
      getBalance es.base 0 gasPoolActor := by
  rw [apply_admissible_with_base, hst, hsigner]
  show getBalance (step_impl es.base (Laws.transfer 1 gasPoolActor sequencerActor amount))
        0 gasPoolActor = getBalance es.base 0 gasPoolActor
  unfold step_impl
  rw [if_pos hpre]
  exact getBalance_pool_transfer_other_leg es.base 1 0 amount (by decide)

/-- **BOLD leg independent of ETH actions.**  A pool transfer over the
    ETH leg (`resource 0`) leaves the pool's BOLD-leg (`resource 1`)
    balance unchanged. -/
theorem pool_balance_bold_leg_independent_of_eth_actions
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (amount : Amount)
    (h : AdmissibleWith verify P d es st)
    (hsigner : st.signer = gasPoolActor)
    (hst : st.action = .transfer 0 gasPoolActor sequencerActor amount)
    (hpre : (Laws.transfer 0 gasPoolActor sequencerActor amount).pre es.base) :
    getBalance (apply_admissible_with verify P d es st h).base 1 gasPoolActor =
      getBalance es.base 1 gasPoolActor := by
  rw [apply_admissible_with_base, hst, hsigner]
  show getBalance (step_impl es.base (Laws.transfer 0 gasPoolActor sequencerActor amount))
        1 gasPoolActor = getBalance es.base 1 gasPoolActor
  unfold step_impl
  rw [if_pos hpre]
  exact getBalance_pool_transfer_other_leg es.base 0 1 amount (by decide)

/-- **Per-resource pool independence (combined).**  The two gas legs are
    separate accounting domains: an authorised pool transfer on one leg
    leaves the pool's balance on the other leg exactly unchanged.  Stated
    over the raw transfer law (the kernel effect both admitted-step forms
    reduce to), parameterised by the leg the transfer is over. -/
theorem per_resource_pool_independence
    (rTransfer rOther : ResourceId) (s : State) (amount : Amount)
    (hne : rTransfer ≠ rOther) :
    getBalance ((Laws.transfer rTransfer gasPoolActor sequencerActor amount).apply_impl s)
        rOther gasPoolActor = getBalance s rOther gasPoolActor :=
  getBalance_pool_transfer_other_leg s rTransfer rOther amount hne

/-! ## The external (non-pool-signer) discharge — exhaustive

`Action.doesNotDebitPoolAt rLeg signer` is the decidable structural
condition under which a kernel step CANNOT lower `gasPoolActor`'s
balance at leg `rLeg`: credit-only / no-op actions always qualify, the
signer-bound `topUp*` actions qualify when the signer is not the pool,
and the source-bound `transfer` / `burn` / `withdraw` qualify when their
source field is not the pool.  `pool_nondecreasing_of_does_not_debit`
proves the non-decrease over EVERY `Action` constructor, so a
deployment's `hext` obligation is fully dischargeable. -/

/-- The decidable structural condition under which an action's kernel
    step cannot decrease `gasPoolActor`'s balance at leg `rLeg`.  The
    five debit-bearing constructors carve out the dangerous case (a debit
    on leg `rLeg` whose source is the pool); every other constructor is
    credit-only or a no-op and qualifies unconditionally (`_ => True`). -/
def Action.doesNotDebitPoolAt (rLeg : ResourceId) (signer : ActorId) : Action → Prop
  | .transfer r sender _ _          => r ≠ rLeg ∨ sender ≠ gasPoolActor
  | .burn r fromActor _             => r ≠ rLeg ∨ fromActor ≠ gasPoolActor
  | .withdraw r sender _ _          => r ≠ rLeg ∨ sender ≠ gasPoolActor
  | .topUpActionBudget gr _ _ _     => gr ≠ rLeg ∨ signer ≠ gasPoolActor
  | .topUpActionBudgetFor _ gr _ _ _ => gr ≠ rLeg ∨ signer ≠ gasPoolActor
  -- GP.9.1: a refund DEBITS its `poolActor` field (the pool, when
  -- `poolActor = gasPoolActor`).  It misses the pool's `rLeg` slot
  -- exactly when the resource differs OR the named pool actor is not
  -- `gasPoolActor`.  (When it DOES debit the pool it is a legitimate
  -- pool outflow handled by the bound's debit path, not this external-
  -- non-interference classifier.)
  | .claimBudgetRefund gr _ _ pa    => gr ≠ rLeg ∨ pa ≠ gasPoolActor
  | _                               => True

/-- `Action.doesNotDebitPoolAt` is decidable (each branch is a decidable
    disjunction of decidable equalities, or `True`). -/
instance Action.doesNotDebitPoolAt_decidable
    (rLeg : ResourceId) (signer : ActorId) (action : Action) :
    Decidable (Action.doesNotDebitPoolAt rLeg signer action) := by
  unfold Action.doesNotDebitPoolAt
  cases action <;> infer_instance

/-- **Exhaustive external non-interference.**  An admitted step whose
    action satisfies `doesNotDebitPoolAt rLeg st.signer` leaves
    `gasPoolActor`'s balance at leg `rLeg` non-decreasing.

    Proven by reducing the precondition-gated step to its `apply_impl`
    (`step_impl_nondecreasing_of_apply_nondecreasing`) and exhausting the
    22 `Action` constructors: credit-only laws use
    `getBalance_credit_nondecreasing`, the fold-of-credit laws use
    `getBalance_foldl_credit_nondecreasing`, the no-op laws are the
    identity, and the five debit-bearing laws use the
    `doesNotDebitPoolAt` hypothesis to show their debit misses the pool's
    leg-`rLeg` cell. -/
theorem pool_nondecreasing_of_does_not_debit
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (rLeg : ResourceId)
    (h : AdmissibleWith verify P d es st)
    (hsafe : Action.doesNotDebitPoolAt rLeg st.signer st.action) :
    getBalance es.base rLeg gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base rLeg gasPoolActor := by
  rw [apply_admissible_with_base]
  apply step_impl_nondecreasing_of_apply_nondecreasing
  -- Revert the safety hypothesis so `cases` substitutes the action into
  -- both it and the goal; re-introduce (reduced) per branch.
  revert hsafe
  cases st.action with
  | transfer r sender receiver amount =>
      intro hsafe; simp only [Action.doesNotDebitPoolAt] at hsafe
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.transfer r sender receiver amount).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.transfer]
      refine Nat.le_trans (Nat.le_of_eq ?_)
        (getBalance_credit_nondecreasing _ r rLeg receiver gasPoolActor amount)
      exact (getBalance_setBalance_other es.base r rLeg sender gasPoolActor _ hsafe).symm
  | mint r to amount =>
      intro _
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.mint r to amount).apply_impl es.base) rLeg gasPoolActor
      exact getBalance_credit_nondecreasing es.base r rLeg to gasPoolActor amount
  | reward r to amount =>
      intro _
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.reward r to amount).apply_impl es.base) rLeg gasPoolActor
      exact getBalance_credit_nondecreasing es.base r rLeg to gasPoolActor amount
  | deposit r recipient amount depositId =>
      intro _
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.deposit r recipient amount depositId).apply_impl es.base)
          rLeg gasPoolActor
      exact getBalance_credit_nondecreasing es.base r rLeg recipient gasPoolActor amount
  | depositWithFee r recipient poolActor userAmount poolAmount budgetGrant depositId =>
      intro _
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.depositWithFee r recipient poolActor userAmount poolAmount
          budgetGrant depositId).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.depositWithFee]
      refine Nat.le_trans
        (getBalance_credit_nondecreasing es.base r rLeg recipient gasPoolActor userAmount) ?_
      exact getBalance_credit_nondecreasing _ r rLeg poolActor gasPoolActor poolAmount
  | distributeOthers r excluded amount =>
      intro _
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.distributeOthers r excluded amount).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.distributeOthers]
      apply getBalance_foldl_credit_nondecreasing
      intro _ _; exact Nat.le_add_right _ _
  | proportionalDilute r excluded totalReward =>
      intro _
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.proportionalDilute r excluded totalReward).apply_impl es.base)
          rLeg gasPoolActor
      simp only [Laws.proportionalDilute]
      apply getBalance_foldl_credit_nondecreasing
      intro _ _; exact Nat.le_add_right _ _
  | burn r fromActor amount =>
      intro hsafe; simp only [Action.doesNotDebitPoolAt] at hsafe
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.burn r fromActor amount).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.burn]
      exact Nat.le_of_eq (getBalance_setBalance_other es.base r rLeg fromActor gasPoolActor _ hsafe).symm
  | withdraw r sender amount recipientL1 =>
      intro hsafe; simp only [Action.doesNotDebitPoolAt] at hsafe
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.withdraw r sender amount recipientL1).apply_impl es.base)
          rLeg gasPoolActor
      simp only [Laws.withdraw]
      exact Nat.le_of_eq (getBalance_setBalance_other es.base r rLeg sender gasPoolActor _ hsafe).symm
  | topUpActionBudget gasResource gasAmount budgetIncrement poolActor =>
      intro hsafe; simp only [Action.doesNotDebitPoolAt] at hsafe
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.topUpActionBudget st.signer gasResource gasAmount budgetIncrement
          poolActor).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.topUpActionBudget]
      refine Nat.le_trans (Nat.le_of_eq ?_)
        (getBalance_credit_nondecreasing _ gasResource rLeg poolActor gasPoolActor gasAmount)
      exact (getBalance_setBalance_other es.base gasResource rLeg st.signer gasPoolActor _
        hsafe).symm
  | topUpActionBudgetFor recipient gasResource gasAmount budgetIncrement poolActor =>
      intro hsafe; simp only [Action.doesNotDebitPoolAt] at hsafe
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.topUpActionBudgetFor recipient st.signer gasResource gasAmount
          budgetIncrement poolActor).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.topUpActionBudgetFor]
      refine Nat.le_trans (Nat.le_of_eq ?_)
        (getBalance_credit_nondecreasing _ gasResource rLeg poolActor gasPoolActor gasAmount)
      exact (getBalance_setBalance_other es.base gasResource rLeg st.signer gasPoolActor _
        hsafe).symm
  | claimBudgetRefund gasResource budgetUnits weiPerBudgetUnit poolActor =>
      -- GP.9.1: a refund DEBITS `poolActor` and CREDITS the claimant
      -- (`st.signer`).  Mirror of `topUpActionBudget` with the debit /
      -- credit roles swapped: the outer (credit) write at `st.signer`
      -- is non-decreasing for the pool; the inner (debit) write at
      -- `poolActor` misses `gasPoolActor`'s `rLeg` slot under `hsafe`
      -- (`gasResource ≠ rLeg ∨ poolActor ≠ gasPoolActor`).
      intro hsafe; simp only [Action.doesNotDebitPoolAt] at hsafe
      show getBalance es.base rLeg gasPoolActor ≤
        getBalance ((Laws.claimBudgetRefund st.signer poolActor gasResource
          (budgetUnits * weiPerBudgetUnit)).apply_impl es.base) rLeg gasPoolActor
      simp only [Laws.claimBudgetRefund]
      refine Nat.le_trans (Nat.le_of_eq ?_)
        (getBalance_credit_nondecreasing _ gasResource rLeg st.signer gasPoolActor
          (budgetUnits * weiPerBudgetUnit))
      exact (getBalance_setBalance_other es.base gasResource rLeg poolActor gasPoolActor _
        hsafe).symm
  | freezeResource r            => intro _; exact Nat.le_refl _
  | replaceKey actor key        => intro _; exact Nat.le_refl _
  | dispute disp                => intro _; exact Nat.le_refl _
  | disputeWithdraw id          => intro _; exact Nat.le_refl _
  | verdict v                   => intro _; exact Nat.le_refl _
  | rollback id                 => intro _; exact Nat.le_refl _
  | registerIdentity actor key  => intro _; exact Nat.le_refl _
  | declareLocalPolicy p        => intro _; exact Nat.le_refl _
  | revokeLocalPolicy           => intro _; exact Nat.le_refl _
  | faultProofChallenge a b c e => intro _; exact Nat.le_refl _
  | faultProofResolution a b c e => intro _; exact Nat.le_refl _

/-- **External transfers do not drain the pool** (corollary of the
    exhaustive discharge, at the ETH leg).  An admitted `transfer` with
    `sender ≠ gasPoolActor` leaves the pool's resource-0 balance
    non-decreasing — the dominant honest external action shape. -/
theorem transfer_other_sender_pool_nondecreasing
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction)
    (h : AdmissibleWith verify P d es st)
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
    (hst : st.action = .transfer r sender receiver amount)
    (hsender : sender ≠ gasPoolActor) :
    getBalance es.base 0 gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base 0 gasPoolActor := by
  apply pool_nondecreasing_of_does_not_debit verify P d es st 0 h
  rw [hst]; exact Or.inr hsender

/-! ## The combined per-step bound -/

/-- **Per-step drain bound (combined, any leg).**  A single admitted step
    decreases `gasPoolActor`'s balance at leg `rLeg` by at most
    `legCap mEth mBold rLeg`, given the two controlling facts. -/
theorem pool_step_drain_le
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount) (rLeg : ResourceId)
    (h : AdmissibleWith verify P d es st)
    (hpool : st.signer = gasPoolActor →
        gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
    (hext : st.signer ≠ gasPoolActor →
        getBalance es.base rLeg gasPoolActor ≤
          getBalance (apply_admissible_with verify P d es st h).base rLeg gasPoolActor) :
    getBalance es.base rLeg gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base rLeg gasPoolActor
        + legCap mEth mBold rLeg := by
  by_cases hs : st.signer = gasPoolActor
  · exact pool_signed_step_drain_le verify P d es st mEth mBold rLeg h hs (hpool hs)
  · exact Nat.le_trans (hext hs) (Nat.le_add_right _ _)

/-! ## Lift onto the literal production runtime entry

The per-step facts above are stated over `apply_admissible_with` — the
canonical balance-affecting step.  The runtime (`processSignedActionWith`)
and the dispute pipeline actually apply via the budget-gated bridge entry
`apply_bridge_admissible_with_budget`, which (on success) returns the same
state with only `epochBudgets` overwritten and the bridge ledger updated —
neither of which touches an actor's `.base` balance beyond the kernel
step.  The lemmas below lift the per-step drain bound onto that literal
entry, matching the GP.4.2 accounting theorems' production-faithfulness
standard. -/

/-- On a successful budget-gated bridge step, the post-state's kernel
    `base` equals the `apply_admissible_with` base — the budget gate and
    bridge-ledger update leave the balances the kernel step produced.
    Chains `apply_bridge_admissible_with_budget_base_bridge_eq` with
    `apply_bridge_admissible_with_base_agrees`. -/
theorem apply_bridge_admissible_with_budget_base_eq_apply
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat) (h : BridgeAdmissibleWith verify P d es st)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es') :
    es'.base = (apply_admissible_with verify P d es st h.toAdmissibleWith).base := by
  rw [(apply_bridge_admissible_with_budget_base_bridge_eq verify P d es st idx h hsuc).1]
  exact apply_bridge_admissible_with_base_agrees verify P d es st idx h

/-- **Per-step drain bound over the production runtime entry.**  A
    successful budget-gated bridge step signed by `gasPoolActor` and
    authorised by `gasPoolActorAuthorized` drains the pool's leg-`rLeg`
    balance by at most `legCap` — the same bound, now over the literal
    `apply_bridge_admissible_with_budget` the runtime executes. -/
theorem pool_signed_step_drain_le_budget
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount) (rLeg : ResourceId) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es')
    (hsigner : st.signer = gasPoolActor)
    (hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action) :
    getBalance es.base rLeg gasPoolActor ≤
      getBalance es'.base rLeg gasPoolActor + legCap mEth mBold rLeg := by
  rw [apply_bridge_admissible_with_budget_base_eq_apply verify P d es st idx h hsuc]
  exact pool_signed_step_drain_le verify P d es st mEth mBold rLeg h.toAdmissibleWith hsigner hauth

/-- **External non-interference over the production runtime entry.**  A
    successful budget-gated bridge step whose action satisfies
    `doesNotDebitPoolAt` leaves the pool's leg-`rLeg` balance
    non-decreasing — the exhaustive external discharge, now over the
    runtime entry. -/
theorem pool_nondecreasing_of_does_not_debit_budget
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (rLeg : ResourceId) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es')
    (hsafe : Action.doesNotDebitPoolAt rLeg st.signer st.action) :
    getBalance es.base rLeg gasPoolActor ≤ getBalance es'.base rLeg gasPoolActor := by
  rw [apply_bridge_admissible_with_budget_base_eq_apply verify P d es st idx h hsuc]
  exact pool_nondecreasing_of_does_not_debit verify P d es st rLeg h.toAdmissibleWith hsafe

/-! ## The gas-pool admitted-step trace (inductive form)

`PoolBoundedTrace … rLeg …` is the type-safe analogue of the plan's
`applyTrace es trace = some es'`: an inductive relation closing `es0`
under a contiguous sequence of admitted steps respecting the gas-pool
discipline at leg `rLeg`, indexed by the trace length. -/

/-- A trace of `n` admitted `SignedAction`s from `es0`, each respecting
    the gas-pool drain discipline at leg `rLeg`. -/
inductive PoolBoundedTrace (mEth mBold : Amount) (rLeg : ResourceId)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState) :
    Nat → ExtendedState → Prop where
  /-- The empty trace: `es0` reaches itself in zero steps. -/
  | refl : PoolBoundedTrace mEth mBold rLeg verify P d es0 0 es0
  /-- Extend a length-`n` trace by one admitted step respecting the
      discipline: a `gasPoolActor`-signed step is authorised by
      `gasPoolActorAuthorized`; a non-pool step does not decrease the
      pool's leg-`rLeg` balance (the deployment's sender discipline). -/
  | step {n : Nat} {es : ExtendedState} (st : SignedAction)
      (hprev : PoolBoundedTrace mEth mBold rLeg verify P d es0 n es)
      (hadm : AdmissibleWith verify P d es st)
      (hpool : st.signer = gasPoolActor →
          gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
      (hext : st.signer ≠ gasPoolActor →
          getBalance es.base rLeg gasPoolActor ≤
            getBalance (apply_admissible_with verify P d es st hadm).base rLeg gasPoolActor) :
      PoolBoundedTrace mEth mBold rLeg verify P d es0 (n + 1)
        (apply_admissible_with verify P d es st hadm)

/-- **Prepend a first step to a trace.**  If a single admitted step from
    `es0` respects the discipline, it can be glued to the FRONT of a
    trace starting at the post-step state.  (The `step` constructor
    extends at the END; this is the dual, proven by induction on the
    tail trace.)  Used to bridge the left-folding `applyTrace` to the
    inductive relation. -/
theorem PoolBoundedTrace.headStep
    {mEth mBold : Amount} {rLeg : ResourceId}
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} (es0 : ExtendedState) (st : SignedAction)
    (hadm : AdmissibleWith verify P d es0 st)
    (hpool : st.signer = gasPoolActor →
        gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
    (hext : st.signer ≠ gasPoolActor →
        getBalance es0.base rLeg gasPoolActor ≤
          getBalance (apply_admissible_with verify P d es0 st hadm).base rLeg gasPoolActor)
    {n : Nat} {es' : ExtendedState}
    (hrest : PoolBoundedTrace mEth mBold rLeg verify P d
      (apply_admissible_with verify P d es0 st hadm) n es') :
    PoolBoundedTrace mEth mBold rLeg verify P d es0 (n + 1) es' := by
  induction hrest with
  | refl => exact PoolBoundedTrace.step st PoolBoundedTrace.refl hadm hpool hext
  | step st' _hprev' hadm' hpool' hext' ih =>
      exact PoolBoundedTrace.step st' ih hadm' hpool' hext'

/-! ## The headline drain bound and its corollaries (per-resource) -/

/-- **GP.7.3 / GP.7.5 headline: the per-resource pool drain bound.**
    Across any contiguous trace of `n` admitted `SignedAction`s
    respecting the gas-pool discipline at leg `rLeg`, `gasPoolActor`'s
    leg-`rLeg` balance cannot have decreased by more than
    `n × legCap mEth mBold rLeg` (the ETH cap on resource `0`, the BOLD
    cap on resource `1`). -/
theorem pool_drain_bounded_by_action_count_per_resource
    (mEth mBold : Amount) (rLeg : ResourceId)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold rLeg verify P d es0 n es') :
    getBalance es'.base rLeg gasPoolActor + n * legCap mEth mBold rLeg ≥
      getBalance es0.base rLeg gasPoolActor := by
  show getBalance es0.base rLeg gasPoolActor ≤
    getBalance es'.base rLeg gasPoolActor + n * legCap mEth mBold rLeg
  induction h with
  | refl => simp
  | step st _hprev hadm hpool hext ih =>
      rename_i n es
      have hstep := pool_step_drain_le _ P d es st mEth mBold rLeg hadm hpool hext
      exact trace_drain_arith _ _ _ (n * legCap mEth mBold rLeg) (legCap mEth mBold rLeg)
        ((n + 1) * legCap mEth mBold rLeg) ih hstep (Nat.succ_mul n (legCap mEth mBold rLeg))

/-- **GP.7.3 ETH-leg headline.**  The `rLeg = 0` specialisation: the
    gas-pool ETH balance cannot fall by more than `n × mEth`. -/
theorem pool_drain_bounded_by_action_count
    (mEth mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold 0 verify P d es0 n es') :
    getBalance es'.base 0 gasPoolActor + n * mEth ≥
      getBalance es0.base 0 gasPoolActor := by
  have hb := pool_drain_bounded_by_action_count_per_resource mEth mBold 0 verify P d es0 n es' h
  simpa using hb

/-- **GP.7.5 BOLD-leg headline.**  The `rLeg = 1` specialisation: the
    gas-pool BOLD balance cannot fall by more than `n × mBold`. -/
theorem pool_drain_bounded_by_action_count_bold
    (mEth mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold 1 verify P d es0 n es') :
    getBalance es'.base 1 gasPoolActor + n * mBold ≥
      getBalance es0.base 1 gasPoolActor := by
  have hb := pool_drain_bounded_by_action_count_per_resource mEth mBold 1 verify P d es0 n es' h
  simpa using hb

/-- **Surviving-balance floor (per-resource).**  After the trace, the
    pool's leg-`rLeg` balance is at least its starting balance minus
    `n × legCap` (`Nat` subtraction floors at `0`). -/
theorem pool_balance_lower_bound_via_trace_per_resource
    (mEth mBold : Amount) (rLeg : ResourceId)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold rLeg verify P d es0 n es') :
    getBalance es'.base rLeg gasPoolActor ≥
      getBalance es0.base rLeg gasPoolActor - n * legCap mEth mBold rLeg := by
  show getBalance es0.base rLeg gasPoolActor - n * legCap mEth mBold rLeg ≤
    getBalance es'.base rLeg gasPoolActor
  have hb := pool_drain_bounded_by_action_count_per_resource mEth mBold rLeg verify P d es0 n es' h
  exact lower_bound_drain_arith _ _ _ hb

/-- **Surviving-balance floor (ETH leg).**  The `rLeg = 0` specialisation
    of `pool_balance_lower_bound_via_trace_per_resource`. -/
theorem pool_balance_lower_bound_via_trace
    (mEth mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold 0 verify P d es0 n es') :
    getBalance es'.base 0 gasPoolActor ≥
      getBalance es0.base 0 gasPoolActor - n * mEth := by
  have hb := pool_balance_lower_bound_via_trace_per_resource mEth mBold 0 verify P d es0 n es' h
  simpa using hb

/-- **Zero-cap boundary (ETH leg).**  With `maxDrainPerActionEth = 0`,
    the gas-pool ETH balance is non-decreasing across any admitted trace
    — the degenerate cap forbids every ETH-leg drain. -/
theorem pool_cannot_drain_when_cap_zero
    (mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace 0 mBold 0 verify P d es0 n es') :
    getBalance es'.base 0 gasPoolActor ≥ getBalance es0.base 0 gasPoolActor := by
  show getBalance es0.base 0 gasPoolActor ≤ getBalance es'.base 0 gasPoolActor
  have hb := pool_drain_bounded_by_action_count 0 mBold verify P d es0 n es' h
  rw [Nat.mul_zero, Nat.add_zero] at hb
  exact hb

/-! ## Connector: the genesis-wiring policy discharges the pool-signed fact -/

/-- Under the genesis-wiring policy `P₀.intersect (gasPoolAuthorityPolicy
    mEth mBold)`, an admitted `gasPoolActor`-signed step is authorised by
    `gasPoolActorAuthorized` — discharging the drain bound's `hpool`
    hypothesis from the deployment policy itself. -/
theorem gasPoolActorAuthorized_of_admissible_intersect
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P₀ : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount)
    (h : AdmissibleWith verify (P₀.intersect (gasPoolAuthorityPolicy mEth mBold)) d es st)
    (hs : st.signer = gasPoolActor) :
    gasPoolActorAuthorized mEth mBold gasPoolActor st.action := by
  obtain ⟨_, hg⟩ := h.1
  rw [hs] at hg
  exact hg

/-! ## The executable trace fold (`applyTrace`)

The literal `Option`-valued fold the plan sketched.  Each step checks
admissibility (`AdmissibleWith` is decidable + computable via
`Authority.instDecidableAdmissibleWith`) and applies; a single
inadmissible step aborts the whole trace with `none`.
`applyTrace_drain_bounded_per_resource` proves the drain bound directly
over it, and `applyTrace_yields_poolBoundedTrace` bridges it to the
inductive relation. -/

/-- Fold a list of signed actions through the admission gate from `es`,
    aborting with `none` on the first inadmissible action. -/
def applyTrace (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) :
    ExtendedState → List SignedAction → Option ExtendedState
  | es, []        => some es
  | es, st :: rest =>
      if h : AdmissibleWith verify P d es st then
        applyTrace verify P d (apply_admissible_with verify P d es st h) rest
      else
        none

/-- **GP.7.3 drain bound over the executable fold.**  Given the
    deployment's pool-control (`hpool`) and sender-discipline (`hext`)
    guarantees, a successful `applyTrace` over `trace` satisfies the
    leg-`rLeg` drain bound: the pool's balance cannot have fallen by more
    than `trace.length × legCap`.  Proven directly by induction on the
    trace (no detour through the relation). -/
theorem applyTrace_drain_bounded_per_resource
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (mEth mBold : Amount) (rLeg : ResourceId)
    (hpool : ∀ (es : ExtendedState) (st : SignedAction),
        AdmissibleWith verify P d es st → st.signer = gasPoolActor →
        gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
    (hext : ∀ (es : ExtendedState) (st : SignedAction) (h : AdmissibleWith verify P d es st),
        st.signer ≠ gasPoolActor →
        getBalance es.base rLeg gasPoolActor ≤
          getBalance (apply_admissible_with verify P d es st h).base rLeg gasPoolActor)
    (es0 es' : ExtendedState) (trace : List SignedAction)
    (htr : applyTrace verify P d es0 trace = some es') :
    getBalance es'.base rLeg gasPoolActor + trace.length * legCap mEth mBold rLeg ≥
      getBalance es0.base rLeg gasPoolActor := by
  show getBalance es0.base rLeg gasPoolActor ≤
    getBalance es'.base rLeg gasPoolActor + trace.length * legCap mEth mBold rLeg
  induction trace generalizing es0 with
  | nil =>
      simp only [applyTrace, Option.some.injEq] at htr
      subst htr; simp
  | cons st rest ih =>
      simp only [applyTrace] at htr
      split at htr
      · rename_i hadm
        have hstep := pool_step_drain_le verify P d es0 st mEth mBold rLeg hadm
          (hpool es0 st hadm) (hext es0 st hadm)
        have hih := ih (apply_admissible_with verify P d es0 st hadm) htr
        simp only [List.length_cons]
        exact trace_drain_arith _ _ _ (legCap mEth mBold rLeg) (rest.length * legCap mEth mBold rLeg)
          ((rest.length + 1) * legCap mEth mBold rLeg) hstep hih
          (by rw [Nat.succ_mul]; exact Nat.add_comm _ _)
      · exact absurd htr (by simp)

/-- **Bridge: a successful `applyTrace` yields a `PoolBoundedTrace`.**
    Under the same controlling guarantees, the executable fold and the
    inductive relation agree — the relation's `n` is `trace.length`. -/
theorem applyTrace_yields_poolBoundedTrace
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (mEth mBold : Amount) (rLeg : ResourceId)
    (hpool : ∀ (es : ExtendedState) (st : SignedAction),
        AdmissibleWith verify P d es st → st.signer = gasPoolActor →
        gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
    (hext : ∀ (es : ExtendedState) (st : SignedAction) (h : AdmissibleWith verify P d es st),
        st.signer ≠ gasPoolActor →
        getBalance es.base rLeg gasPoolActor ≤
          getBalance (apply_admissible_with verify P d es st h).base rLeg gasPoolActor)
    (es0 es' : ExtendedState) (trace : List SignedAction)
    (htr : applyTrace verify P d es0 trace = some es') :
    PoolBoundedTrace mEth mBold rLeg verify P d es0 trace.length es' := by
  induction trace generalizing es0 with
  | nil =>
      simp only [applyTrace, Option.some.injEq] at htr
      subst htr; exact PoolBoundedTrace.refl
  | cons st rest ih =>
      simp only [applyTrace] at htr
      split at htr
      · rename_i hadm
        have hrest := ih (apply_admissible_with verify P d es0 st hadm) htr
        simp only [List.length_cons]
        exact PoolBoundedTrace.headStep es0 st hadm (hpool es0 st hadm) (hext es0 st hadm) hrest
      · exact absurd htr (by simp)

end Bridge
end LegalKernel

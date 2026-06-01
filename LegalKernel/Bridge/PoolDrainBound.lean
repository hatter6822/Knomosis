-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.PoolDrainBound — Workstream GP.7.3.

Proves the **per-epoch pool-drain bound** is a kernel invariant given
the canonical gas-pool authority discipline (GP.7.2): across any
contiguous trace of `n` admitted `SignedAction`s, the gas-pool actor's
balance at `ResourceId 0` (the ETH leg) cannot have decreased by more
than `n × maxDrainPerActionEth`.

## Why the bound rests on the AuthorityPolicy, not the LocalPolicy

The naïve inductive argument (Genesis-Plan sketch) splits each admitted
step into "(a) not signed by `gasPoolActor` → no decrease" and "(b)
signed by `gasPoolActor` and passes `gasPoolPolicy` → drain ≤ cap".
Both halves need care to be *true*, and the GP.7.2 audit already
surfaced exactly why the bare `LocalPolicy` (`gasPoolPolicy`) is
insufficient:

  * **Sender blindness.**  `gasPoolPolicy`'s clauses key off the
    action's resource / recipient / amount, never its `sender`.  The
    kernel `transfer` law debits the action's `sender`, and
    `AdmissibleWith` verifies only `st.signer`'s signature.  So a
    `gasPoolActor`-signed transfer whose `sender` is some victim would
    NOT drain the pool, while a non-`gasPoolActor`-signed transfer
    whose `sender` is `gasPoolActor` WOULD — outside the reach of
    `gasPoolPolicy` (which governs only the *signer*'s actions).
  * **The meta-action hole.**  The LP.7 exemption lets `gasPoolActor`
    sign `revokeLocalPolicy` regardless of its declared policy, so a
    `LocalPolicy` cannot keep itself in force across a trace
    (`gasPoolPolicy_admission_permits_meta_actions`).

GP.7.2 closed both holes with the complementary `gasPoolAuthorityPolicy`
(intersected into the deployment policy at genesis, GP.7.4).  This
module therefore states the drain bound's controlling hypotheses in
terms of that authority discipline:

  * for a `gasPoolActor`-signed step, the action is authorised by
    `gasPoolAuthorityPolicy` — i.e. it is a capped `transfer` whose
    `sender` is `gasPoolActor` itself, to `sequencerActor`, on a gas
    leg.  The ETH-leg cap bounds the per-step drain; the BOLD leg does
    not touch resource 0 at all (`pool_signed_step_drain_le_eth`); and
  * for a non-`gasPoolActor`-signed step, the pool's resource-0 balance
    does not decrease.  This is the deployment's `sender = signer`
    discipline — a real obligation, NOT vacuously true under
    `AuthorityPolicy.unrestricted`.  It is dischargeable: the dominant
    case (a transfer signed by another actor on its OWN balance) is
    proven non-draining by `transfer_other_sender_pool_nondecreasing`.

The two per-step facts are bundled into the inductive
`PoolBoundedTrace` relation (the type-safe analogue of the plan's
`applyTrace es trace = some es'`, indexed by the trace length `n`); the
headline `pool_drain_bounded_by_action_count` is then a clean induction
summing the per-step caps, and `pool_balance_lower_bound_via_trace`
restates it as a floor on the surviving balance.  The
`maxDrainPerActionEth = 0` boundary (`pool_cannot_drain_when_cap_zero`)
says a zero-cap pool cannot drain its ETH leg at all.

## A note on the arithmetic helpers

`omega` cannot atomise `Amount`-typed (`= Nat`) terms directly — the
same limitation `Laws.Transfer`'s `transfer_arithmetic` works around.
The per-step / trace algebra is therefore discharged through small
`Nat`-parameter helper lemmas (`drain_eth_step_arith`,
`trace_drain_arith`, `lower_bound_drain_arith`) applied to the
`Amount`-valued balances, and the public theorems are stated in the
plan's `≥` orientation (definitionally the `≤` form the proofs use).

This module is **not** part of the kernel TCB.  Like `GasPoolPolicy`, a
bug here would weaken the pool-drain accounting discipline but cannot
violate any kernel invariant: every step is still an ordinary admitted
kernel transition under the conservation guarantees.
-/

import LegalKernel.Bridge.BridgeActor
import LegalKernel.Bridge.GasPoolPolicy
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
    ETH-leg drain inequality, over `Nat`. -/
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

/-! ## Post-state base reduction

`apply_admissible_with` threads the kernel step through three
field-only record updates (nonce / registry / local-policy), none of
which touch `.base`, so the post-state's kernel `base` is exactly the
`step_impl` of the signer-aware transition. -/

/-- The post-application kernel `base` equals the `step_impl` of the
    signer-aware compiled transition.  Holds definitionally: the nonce
    / registry / local-policy updates `apply_admissible_with` performs
    are record updates that leave `.base` untouched. -/
theorem apply_admissible_with_base
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (h : AdmissibleWith verify P d es st) :
    (apply_admissible_with verify P d es st h).base =
      step_impl es.base (Action.toTransition st.action st.signer) := rfl

/-! ## Decomposing the gas-pool authority restriction

`gasPoolAuthorityPolicy` authorises a `gasPoolActor`-signed action iff
it is a capped `transfer` from `gasPoolActor` to `sequencerActor` on a
gas leg.  The lemma below extracts that shape from the abstract
`gasPoolActorAuthorized` predicate so the per-step proof can compute
the balance effect. -/

/-- An action authorised for `gasPoolActor` by `gasPoolActorAuthorized`
    is a `transfer` from `gasPoolActor` to `sequencerActor`, capped per
    leg: either resource `0` with amount `≤ mEth`, or resource `1` with
    amount `≤ mBold`.  Proven by reducing the `if signer = gasPoolActor`
    guard (true via `rfl`) and exhausting the `Action` inductive — every
    non-`transfer` constructor hits the policy's `_ => False` arm. -/
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

/-! ## The per-step drain bound (the mathematical heart)

A single admitted `gasPoolActor`-signed step decreases the pool's
resource-0 balance by at most `mEth`.  Either the authorised transfer
is on the ETH leg (debit `amount ≤ mEth`) or on the BOLD leg (resource
0 untouched).  Stated in the `≤` orientation (`pre ≤ post + mEth`) so
the `Nat` arithmetic helpers apply directly. -/

/-- **Per-step ETH-leg drain bound.**  For an admitted step signed by
    `gasPoolActor` whose action is authorised by `gasPoolActorAuthorized`
    (the GP.7.2 authority discipline), the pre-state gas-pool balance at
    resource `0` is at most the post-state balance plus `mEth` — i.e. the
    step drained the ETH leg by at most `mEth`.

    Proof: the authority witness forces the action to be a capped
    `transfer` from `gasPoolActor` to `sequencerActor`.  On the ETH leg
    (`r = 0`) the pool is debited by `amount`, with `amount ≤ mEth` (the
    cap) and `amount ≤ balance` (the transfer precondition), so the
    post-balance is `balance − amount` and `balance ≤ (balance − amount)
    + mEth`.  On the BOLD leg (`r = 1`) the resource-0 balance is
    untouched (the writes are at resource 1), so the drain is `0`. -/
theorem pool_signed_step_drain_le_eth
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount)
    (h : AdmissibleWith verify P d es st)
    (hsigner : st.signer = gasPoolActor)
    (hauth : gasPoolActorAuthorized mEth mBold gasPoolActor st.action) :
    getBalance es.base 0 gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base 0 gasPoolActor + mEth := by
  -- The compiled-transition precondition (admission conjunct 5).
  have hpre : (Action.compile st.action).transition.pre es.base := h.2.2.2.1
  -- Decompose the authority restriction into a capped pool transfer.
  obtain ⟨r, sender, receiver, amount, hst, hdisj⟩ :=
    gasPoolActorAuthorized_gasPool_imp_transfer mEth mBold st.action hauth
  -- Reduce the post-state base; specialise the action + signer.
  rw [apply_admissible_with_base, hst, hsigner]
  rw [hst] at hpre
  have hpreT : (Laws.transfer r sender receiver amount).pre es.base := hpre
  -- `toTransition` of a transfer is the transfer law; collapse the step.
  show getBalance es.base 0 gasPoolActor ≤
        getBalance (step_impl es.base (Laws.transfer r sender receiver amount)) 0 gasPoolActor
          + mEth
  unfold step_impl
  rw [if_pos hpreT]
  rcases hdisj with ⟨hr, hsnd, hrcv, hamt⟩ | ⟨hr, hsnd, hrcv, _hamt⟩
  · -- ETH leg (r = 0): the pool is debited by `amount ≤ mEth`.
    subst hr; subst hsnd; subst hrcv
    have hbal : amount ≤ getBalance es.base 0 gasPoolActor := hpreT.1
    have hpost :
        getBalance ((Laws.transfer 0 gasPoolActor sequencerActor amount).apply_impl es.base)
            0 gasPoolActor = getBalance es.base 0 gasPoolActor - amount := by
      simp only [Laws.transfer]
      rw [getBalance_setBalance_other _ 0 0 sequencerActor gasPoolActor _
            (Or.inr sequencerActor_ne_gasPoolActor)]
      rw [getBalance_setBalance_same]
    rw [hpost]
    exact drain_eth_step_arith (getBalance es.base 0 gasPoolActor) amount mEth hbal hamt
  · -- BOLD leg (r = 1): resource-0 balance is untouched (locality).
    subst hr; subst hsnd; subst hrcv
    have hpost :
        getBalance ((Laws.transfer 1 gasPoolActor sequencerActor amount).apply_impl es.base)
            0 gasPoolActor = getBalance es.base 0 gasPoolActor := by
      simp only [Laws.transfer]
      rw [getBalance_setBalance_other _ 1 0 sequencerActor gasPoolActor _
            (Or.inl (by decide))]
      rw [getBalance_setBalance_other _ 1 0 gasPoolActor gasPoolActor _
            (Or.inl (by decide))]
    rw [hpost]
    exact Nat.le_add_right _ _

/-! ## The external (non-pool-signer) discharge

The plan's case (a) — "not signed by `gasPoolActor` ⇒ no decrease" — is
the deployment's `sender = signer` discipline.  It is NOT vacuous (under
`AuthorityPolicy.unrestricted` an arbitrary actor could sign
`transfer 0 gasPoolActor receiver amount` and drain the pool).  The
dominant honest case — a transfer signed by another actor on its OWN
balance (`sender ≠ gasPoolActor`) — is proven non-draining here: such a
transfer debits a non-pool actor and at most CREDITS the pool. -/

/-- **External transfers do not drain the pool.**  An admitted step
    whose action is a `transfer` with `sender ≠ gasPoolActor` leaves the
    gas-pool actor's resource-0 balance non-decreasing: the debit lands
    on a non-pool actor, and the credit can only raise the pool's balance
    (when it targets the pool on the ETH leg) or leave it unchanged.

    This discharges the non-`gasPoolActor`-signer obligation of the
    drain bound for the dominant honest action shape (a self-sender
    transfer by another actor), demonstrating the obligation is real and
    dischargeable rather than vacuous. -/
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
  have hpre : (Action.compile st.action).transition.pre es.base := h.2.2.2.1
  rw [apply_admissible_with_base, hst]
  rw [hst] at hpre
  have hpreT : (Laws.transfer r sender receiver amount).pre es.base := hpre
  show getBalance es.base 0 gasPoolActor ≤
        getBalance (step_impl es.base (Laws.transfer r sender receiver amount)) 0 gasPoolActor
  unfold step_impl
  rw [if_pos hpreT]
  by_cases hcase : r = 0 ∧ receiver = gasPoolActor
  · -- The credit targets the pool on the ETH leg: balance rises by `amount`.
    obtain ⟨hr0, hrcvP⟩ := hcase
    subst hr0; subst hrcvP
    have hpost :
        getBalance ((Laws.transfer 0 sender gasPoolActor amount).apply_impl es.base)
            0 gasPoolActor = getBalance es.base 0 gasPoolActor + amount := by
      simp only [Laws.transfer]
      rw [getBalance_setBalance_same]
      rw [getBalance_setBalance_other _ 0 0 sender gasPoolActor _ (Or.inr hsender)]
    rw [hpost]
    exact Nat.le_add_right _ _
  · -- The credit misses the pool's resource-0 cell: balance unchanged.
    have hne : r ≠ 0 ∨ receiver ≠ gasPoolActor := by
      by_cases hr0 : r = 0
      · exact Or.inr (fun hrcv => hcase ⟨hr0, hrcv⟩)
      · exact Or.inl hr0
    have hpost :
        getBalance ((Laws.transfer r sender receiver amount).apply_impl es.base)
            0 gasPoolActor = getBalance es.base 0 gasPoolActor := by
      simp only [Laws.transfer]
      rw [getBalance_setBalance_other _ r 0 receiver gasPoolActor _ hne]
      rw [getBalance_setBalance_other _ r 0 sender gasPoolActor _ (Or.inr hsender)]
    rw [hpost]
    exact Nat.le_refl _

/-! ## The combined per-step bound

Bundles the pool-signed cap and the external non-decreasing fact into
the single per-step inequality the trace induction consumes. -/

/-- **Per-step drain bound (combined).**  A single admitted step
    decreases the gas-pool actor's resource-0 balance by at most `mEth`,
    given the two controlling facts: a `gasPoolActor`-signed step is
    authorised by `gasPoolActorAuthorized` (so the cap applies), and a
    non-pool-signed step does not decrease the pool's balance (the
    deployment's sender discipline). -/
theorem pool_step_drain_le_eth
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (mEth mBold : Amount)
    (h : AdmissibleWith verify P d es st)
    (hpool : st.signer = gasPoolActor →
        gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
    (hext : st.signer ≠ gasPoolActor →
        getBalance es.base 0 gasPoolActor ≤
          getBalance (apply_admissible_with verify P d es st h).base 0 gasPoolActor) :
    getBalance es.base 0 gasPoolActor ≤
      getBalance (apply_admissible_with verify P d es st h).base 0 gasPoolActor + mEth := by
  by_cases hs : st.signer = gasPoolActor
  · exact pool_signed_step_drain_le_eth verify P d es st mEth mBold h hs (hpool hs)
  · exact Nat.le_trans (hext hs) (Nat.le_add_right _ _)

/-! ## The gas-pool admitted-step trace

`PoolBoundedTrace` is the type-safe analogue of the plan's
`applyTrace es trace = some es'`: an inductive relation that closes
`es0` under a contiguous sequence of admitted `SignedAction`s, indexed
by the trace length `n`.  Each `step` carries the two controlling facts
that make the drain bound hold (pool-signed authorisation; external
non-interference) — exactly the conjuncts a genesis deployment wiring
`P.intersect (gasPoolAuthorityPolicy mEth mBold)` discharges. -/

/-- A trace of `n` admitted `SignedAction`s from `es0`, each respecting
    the gas-pool drain discipline.  Indexed by the trace length so the
    drain bound can scale with the number of steps. -/
inductive PoolBoundedTrace (mEth mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState) :
    Nat → ExtendedState → Prop where
  /-- The empty trace: `es0` reaches itself in zero steps. -/
  | refl : PoolBoundedTrace mEth mBold verify P d es0 0 es0
  /-- Extend a length-`n` trace by one admitted step that respects the
      drain discipline: if it is `gasPoolActor`-signed it is authorised
      by `gasPoolActorAuthorized` (cap applies); if not, it does not
      decrease the pool's resource-0 balance (sender discipline). -/
  | step {n : Nat} {es : ExtendedState} (st : SignedAction)
      (hprev : PoolBoundedTrace mEth mBold verify P d es0 n es)
      (hadm : AdmissibleWith verify P d es st)
      (hpool : st.signer = gasPoolActor →
          gasPoolActorAuthorized mEth mBold gasPoolActor st.action)
      (hext : st.signer ≠ gasPoolActor →
          getBalance es.base 0 gasPoolActor ≤
            getBalance (apply_admissible_with verify P d es st hadm).base 0 gasPoolActor) :
      PoolBoundedTrace mEth mBold verify P d es0 (n + 1)
        (apply_admissible_with verify P d es st hadm)

/-! ## The headline drain bound and its corollaries -/

/-- **GP.7.3 headline: the pool drain bound is a trace invariant.**
    Across any contiguous trace of `n` admitted `SignedAction`s
    respecting the gas-pool discipline, the gas-pool actor's resource-0
    balance cannot have decreased by more than `n × mEth`.

    Proof: induction on the trace.  The empty trace decreases nothing
    (`0 ≤ 0 × mEth`).  Each step drains by at most `mEth`
    (`pool_step_drain_le_eth`); summing across the trace gives the
    `n × mEth` bound (`(n+1) × mEth = n × mEth + mEth`). -/
theorem pool_drain_bounded_by_action_count
    (mEth mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold verify P d es0 n es') :
    getBalance es'.base 0 gasPoolActor + n * mEth ≥
      getBalance es0.base 0 gasPoolActor := by
  show getBalance es0.base 0 gasPoolActor ≤ getBalance es'.base 0 gasPoolActor + n * mEth
  induction h with
  | refl => simp
  | step st _hprev hadm hpool hext ih =>
      rename_i n es
      have hstep := pool_step_drain_le_eth _ P d es st mEth mBold hadm hpool hext
      exact trace_drain_arith _ _ _ (n * mEth) mEth ((n + 1) * mEth) ih hstep
        (Nat.succ_mul n mEth)

/-- **GP.7.3 corollary: a lower bound on the surviving pool balance.**
    The gas-pool actor's resource-0 balance after the trace is at least
    its starting balance minus `n × mEth` (`Nat` subtraction floors at
    `0`, so this is exactly the plan's `max 0 (start − n × mEth)`). -/
theorem pool_balance_lower_bound_via_trace
    (mEth mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace mEth mBold verify P d es0 n es') :
    getBalance es'.base 0 gasPoolActor ≥
      getBalance es0.base 0 gasPoolActor - n * mEth := by
  show getBalance es0.base 0 gasPoolActor - n * mEth ≤ getBalance es'.base 0 gasPoolActor
  have hb := pool_drain_bounded_by_action_count mEth mBold verify P d es0 n es' h
  exact lower_bound_drain_arith (getBalance es0.base 0 gasPoolActor)
    (getBalance es'.base 0 gasPoolActor) (n * mEth) hb

/-- **GP.7.3 boundary: a zero-cap pool cannot drain its ETH leg.**  With
    `maxDrainPerActionEth = 0`, the gas-pool actor's resource-0 balance
    is non-decreasing across any admitted trace — the degenerate cap
    forbids every ETH-leg drain (a positive amount exceeds the cap;
    a zero amount fails the transfer precondition). -/
theorem pool_cannot_drain_when_cap_zero
    (mBold : Amount)
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es0 : ExtendedState)
    (n : Nat) (es' : ExtendedState)
    (h : PoolBoundedTrace 0 mBold verify P d es0 n es') :
    getBalance es'.base 0 gasPoolActor ≥ getBalance es0.base 0 gasPoolActor := by
  show getBalance es0.base 0 gasPoolActor ≤ getBalance es'.base 0 gasPoolActor
  have hb := pool_drain_bounded_by_action_count 0 mBold verify P d es0 n es' h
  rw [Nat.mul_zero, Nat.add_zero] at hb
  exact hb

/-! ## Connector: the genesis-wiring policy discharges the pool-signed fact

When a deployment intersects `gasPoolAuthorityPolicy mEth mBold` into
its base policy (the GP.7.4 genesis wiring), every admitted
`gasPoolActor`-signed step's authority conjunct yields the
`gasPoolActorAuthorized` fact the drain bound's `hpool` hypothesis
needs — for free, with no extra obligation. -/

/-- Under the genesis-wiring policy `P₀.intersect (gasPoolAuthorityPolicy
    mEth mBold)`, an admitted `gasPoolActor`-signed step is authorised by
    `gasPoolActorAuthorized` — the `hpool` hypothesis of the drain bound
    is discharged by the deployment policy itself.  Extracted from the
    `AdmissibleWith` authority conjunct (the right component of the
    intersection). -/
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

end Bridge
end LegalKernel

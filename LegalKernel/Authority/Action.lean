/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Authority.Action — the §4.13 Action layer.

Phase 3 WU 3.1 and WU 3.2.  Defines the deployment's `Action`
inductive (a first-order data form: one constructor per law, each
carrying only scalars and identifiers), the `CompiledAction`
wrapper that pairs each kernel `Transition` with the originating
`Action`, the `Action.compile` function that produces the wrapper,
and the `Action.compile_injective` headline lemma.

**Structural injectivity design.**  The Genesis-Plan §4.13 sketch
returned `Transition` directly from `Action.compile`.  In Canon's
Phase-3 implementation we instead return `CompiledAction`, a thin
wrapper that carries the originating `Action` alongside the kernel
`Transition`.  This makes `Action.compile_injective` a *one-line
structural proof* (`congrArg CompiledAction.source`) rather than a
hairy case-by-case discrimination — and it sidesteps the genuine
non-injectivity at the bare-`Transition` level (two `freezeResource`
constructors with different `r` values produce the same kernel
`Transition`, by design of Phase-2's no-op-marker freeze law; and
two vacuous actions like `transfer r s s 0` and `mint r s 0` have
extensionally equal compiled bodies).

The wrapper adds zero TCB surface: the kernel still operates on
plain `Transition` values.  Authority-layer callers project out the
transition via `(Action.compile a).transition`; the `source` field
lives outside the kernel and exists purely to make compile injective
on the nose.

The `Action` type is the boundary between the kernel's *operational*
representation (functions in `Transition`, which cannot be
canonically serialised) and the deployment's *external*
representation (CBOR bytes that can be signed, logged, and replayed).
Everything that crosses a network, a disk, or a signature lives in
`Action`-space; everything that crosses the kernel's executable path
lives in `Transition`-space (Genesis Plan §4.13).

This module is **not** part of the trusted computing base.  It is
deployment-facing infrastructure: a bug here can produce a wrong
`Transition` from an `Action`, but cannot violate any kernel
invariant (the kernel's proofs all bottom out at `Transition` and
its `decPre` field, regardless of how the `Transition` was built).

Coverage map:

  * WU 3.1 — `Action` inductive enumerating the deployed laws;
              `CompiledAction` wrapper; `Action.compile` mapping each
              constructor to a `CompiledAction`.
  * WU 3.2 — `Action.compile_injective`: a one-line structural proof
              via `congrArg CompiledAction.source`.

The `Action` constructors mirror the four Phase-2 laws verbatim, plus
a Phase-3 `replaceKey` constructor for WU 3.10 (registered under the
`replaceKey` action, applied via the authority layer).  Adding a new
law to a deployment requires:

  1. A new `Action` constructor here (with fields matching the law's
     scalar parameters).
  2. A new branch in `Action.compileTransition`.
  3. A new `IsConservative` instance (or an explicit non-conservation
     witness, like `mint_not_conservative`).
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Burn
import LegalKernel.Laws.Freeze
import LegalKernel.Laws.Reward
import LegalKernel.Laws.DistributeOthers
import LegalKernel.Laws.ProportionalDilute
import LegalKernel.Laws.Deposit
import LegalKernel.Laws.Withdraw
import LegalKernel.Authority.Crypto
import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.State
import LegalKernel.Disputes.Types

namespace LegalKernel
namespace Authority

open LegalKernel.Disputes

/-! ## The `Action` inductive (§4.13 / WU 3.1) -/

/-- The set of actions a deployment recognises.  One constructor per
    law, each carrying only first-order data (scalars and IDs).

    Phase 3 ships five constructors mirroring the four Phase-2 laws
    (`transfer`, `mint`, `burn`, `freezeResource`) plus the Phase-3
    `replaceKey` action (WU 3.10) that re-points an `ActorId` to a new
    `PublicKey`.  The Phase-4-prelude positive-incentive WU adds three
    more (`reward`, `distributeOthers`, `proportionalDilute`).  Adding
    a constructor here is a deployment-level decision: the kernel
    never refers to `Action`; only the authority module does.

    **Constructor-ordering policy (append-only).**  Constructors are
    listed in the historical order in which they were introduced:

    * Phase 0 / Phase 2 (balance-mutating, kernel `State.balances`):
      `transfer`, `mint`, `burn`, `freezeResource`.
    * Phase 3 (registry-mutating, authority-level `KeyRegistry`,
      applied via `applyActionToRegistry` in `apply_admissible`):
      `replaceKey`.
    * Phase-4 prelude (positive-incentive balance-mutating, all
      classified `IsMonotonic`): `reward`, `distributeOthers`,
      `proportionalDilute`.

    **Indices are stable: every new constructor is appended at the
    end.**  This is the contract that Phase 4's CBOR encoder will
    rely on (constructors are encoded by their inductive index).
    Re-grouping constructors by what they touch — even when it would
    yield a tidier listing — is forbidden once a constructor has
    landed, because re-grouping would silently reassign indices and
    break any deployed serialised data.  Future additions must
    likewise append at the end.

    `DecidableEq` is needed so that `Action` can be hashed, signed, and
    compared at the runtime layer (Phase 5).  `Repr` is needed for the
    test suite's failure messages. -/
inductive Action
  /-- Move `amount` units of `r` from `sender` to `receiver`. -/
  | transfer (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
  /-- Mint `amount` units of `r` into `to`'s balance. -/
  | mint (r : ResourceId) (to : ActorId) (amount : Amount)
  /-- Burn `amount` units of `r` from `fromActor`'s balance. -/
  | burn (r : ResourceId) (fromActor : ActorId) (amount : Amount)
  /-- Mark `r` as frozen (no-op at the kernel level; deployment commitment). -/
  | freezeResource (r : ResourceId)
  /-- Re-point `actor`'s identity to `newKey`, signed by the *old* key.
      Kernel-level effect is identity on `State`; the authority-level
      effect (registry update) happens in `apply_admissible`. -/
  | replaceKey (actor : ActorId) (newKey : PublicKey)
  /-- Reward `to` with `amount` units of `r` (positive-incentive
      analogue of `mint`; classified as `IsMonotonic`).  Distinct from
      `mint` at the Action layer so that authority policies can grant
      "may reward" permission independently from "may mint". -/
  | reward (r : ResourceId) (to : ActorId) (amount : Amount)
  /-- Distribute `amount` to every actor in `r`'s `BalanceMap` except
      `excluded`.  Empty/excluded-only resources are no-ops.
      Substitute for "fining `excluded` by the equivalent of `amount *
      k`" without removing tokens from `excluded`. -/
  | distributeOthers (r : ResourceId) (excluded : ActorId) (amount : Amount)
  /-- Proportionally dilute `excluded` by minting `totalReward * v_k /
      sumOthers` (Nat floor; dust discarded) to each non-excluded
      actor `k`.  The strongest analogue of "burning `excluded`'s
      balance share" available without removing tokens. -/
  | proportionalDilute (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
  /-- File a dispute against a prior log entry (Phase 6 §8.4).  The
      dispute carries the challenger's claim plus the standard nonce
      + signature replay-protection envelope.  Kernel-level effect is
      the identity on `State`; the dispute pipeline (`fileDispute`,
      `checkEvidence`) reads the dispute's data from the log without
      mutating state. -/
  | dispute (d : Dispute)
  /-- Withdraw a previously-filed dispute by referencing its log
      index (Phase 6 §8.4 / WU 6.11).  Idempotent: filing
      `disputeWithdraw idx` against an already-decided or already-
      withdrawn dispute is a no-op at the kernel level (the
      withdrawal is recorded in the log but takes no effect on the
      already-closed dispute). -/
  | disputeWithdraw (idx : Disputes.LogIndex)
  /-- Apply a quorum-signed verdict (Phase 6 §8.4 / WU 6.9).  The
      verdict references the dispute log entry's index; if upheld,
      the runtime layer's `applyVerdict` function performs the
      rollback computation by replaying `log[0..idx-1]`.  Kernel-
      level effect is identity on `State`; the rollback semantics
      live in the runtime layer. -/
  | verdict (v : Verdict)
  /-- A rollback marker recording that the runtime restored state
      to the replay-target of `log[0..targetIdx-1]` after an upheld
      verdict (Phase 6 §8.4 / WU 6.10).  Appended to the log AFTER
      the runtime layer's `applyVerdict` performs the actual state
      replacement.  Kernel-level effect on `State` is identity; the
      runtime layer maintains a separate `rolledBackTo : Option
      LogIndex` field so subsequent replay produces the correct
      state.  The action exists primarily for audit-trail
      readability (a log scanner can detect rollback points without
      replaying the whole log). -/
  | rollback (targetIdx : Disputes.LogIndex)
  /-- Register a new identity (Workstream B §6.3 / Ethereum
      integration).  Authoritative analogue of `replaceKey` for
      *first-time* identity registrations: `replaceKey` is signed
      by the *old* key (so requires an existing registration);
      `registerIdentity` is signed by the deployment's bridge
      actor and inserts the new `(actor, pk)` mapping into the
      `KeyRegistry`.

      The kernel-level effect is identity on `State` (compiled to
      `Laws.freezeResource 0`); the authority-level effect is
      registry insertion via `applyActionToRegistry`.  The "first-
      time only" invariant (registry-empty-for-actor precondition)
      is enforced by the bridge runtime (Workstream B.2: the
      `AddressBook` only generates `registerIdentity` for fresh
      Ethereum addresses) and by deployment-configured
      `AuthorityPolicy` predicates that reject `registerIdentity`
      for already-registered actors.  The full type-level
      first-time-only theorem is reserved for Workstream C.4. -/
  | registerIdentity (actor : ActorId) (pk : PublicKey)
  /-- Bridge deposit (Workstream C.4 / §7.4) at frozen index 13.
      Credits `amount` units of resource `r` to `recipient` on L2,
      marking the L1 `depositId` as consumed.

      Kernel-level effect: `Laws.deposit`-shaped balance increment.
      Bridge-level effect: `BridgeState.consumed` is updated via
      `applyActionToBridgeState` (Workstream C.0).  The `depositId`
      uniqueness check lives at the bridge-admissibility layer
      (`BridgeAdmissibleWith`); the kernel-level precondition is
      trivial. -/
  | deposit (r : ResourceId) (recipient : ActorId)
            (amount : Amount) (depositId : Bridge.DepositId)
  /-- Bridge withdrawal (Workstream C.4 / §7.4) at frozen index 14.
      Debits `amount` units of resource `r` from `sender`'s balance
      and schedules an L1 redemption to `recipientL1`.

      Kernel-level effect: `Laws.withdraw`-shaped balance decrement
      (gated by sufficient-balance precondition).  Bridge-level
      effect: `BridgeState.pending` gains a `PendingWithdrawal`
      entry at `BridgeState.nextWdId`, and `nextWdId` is bumped,
      via `applyActionToBridgeState`. -/
  | withdraw (r : ResourceId) (sender : ActorId)
             (amount : Amount) (recipientL1 : Bridge.EthAddress)
  deriving Repr, DecidableEq

/-! ## Compilation to kernel `Transition`s (§4.13 / WU 3.1) -/

/-- The raw transition compiler: maps each `Action` constructor to
    the corresponding kernel `Transition`.  Cases:

    * `transfer`            → `Laws.transfer`
    * `mint`                → `Laws.mint`
    * `burn`                → `Laws.burn`
    * `freezeResource`      → `Laws.freezeResource`
    * `replaceKey`          → `Laws.freezeResource 0`  (kernel-level no-op;
                               the authority-level effect happens in
                               `apply_admissible`).
    * `reward`              → `Laws.reward`             (positive-incentive credit)
    * `distributeOthers`    → `Laws.distributeOthers`   (uniform reward)
    * `proportionalDilute`  → `Laws.proportionalDilute` (proportional reward)

    This function is *not injective* on its own — the `freezeResource`
    constructor was deliberately designed in Phase 2 to ignore its
    `r` parameter (so `Laws.freezeResource r₁ = Laws.freezeResource r₂`
    for all `r₁`, `r₂`).  Callers that need injectivity must use the
    `Action.compile`/`CompiledAction` wrapper below, which carries the
    originating `Action` as a separate `source` field. -/
def Action.compileTransition : Action → Transition
  | .transfer r s r' a            => Laws.transfer r s r' a
  | .mint r to a                  => Laws.mint r to a
  | .burn r fr a                  => Laws.burn r fr a
  | .freezeResource r             => Laws.freezeResource r
  | .replaceKey _ _               => Laws.freezeResource 0
  | .reward r to a                => Laws.reward r to a
  | .distributeOthers r e a       => Laws.distributeOthers r e a
  | .proportionalDilute r e tr    => Laws.proportionalDilute r e tr
  -- Phase-6 dispute-pipeline actions: kernel-level no-ops.  The
  -- authority-level / runtime-level effects (recording the dispute,
  -- closing the dispute, applying the verdict, performing the
  -- rollback) all happen outside `apply_admissible`, in the dispute
  -- pipeline modules under `LegalKernel/Disputes/`.
  | .dispute _                    => Laws.freezeResource 0
  | .disputeWithdraw _             => Laws.freezeResource 0
  | .verdict _                    => Laws.freezeResource 0
  | .rollback _                   => Laws.freezeResource 0
  -- Workstream B: identity registration.  Kernel-level no-op; the
  -- registry mutation happens in `applyActionToRegistry` inside
  -- `apply_admissible`.  Mirrors `replaceKey`'s compile semantics.
  | .registerIdentity _ _         => Laws.freezeResource 0
  -- Workstream C: bridge actions.  Compile to the corresponding
  -- balance-mutating laws.  The bridge-level effects (`consumed`
  -- map insertion, `pending` map insertion + `nextWdId` bump) are
  -- handled separately by `applyActionToBridgeState` inside
  -- `apply_bridge_admissible_with`.
  | .deposit r recipient amount d   => Laws.deposit  r recipient amount d
  | .withdraw r sender amount rcp   => Laws.withdraw r sender amount rcp

/-! ## The `CompiledAction` wrapper -/

/-- An `Action` paired with its kernel `Transition`.  Carrying the
    originating `Action` in the `source` field is what makes
    `Action.compile_injective` a one-line structural proof: distinct
    actions necessarily have distinct `source` projections.

    The `transition` field is what the kernel actually executes; the
    `source` field exists purely for the structural-identification
    invariant.  At extraction time (Phase 5), the `source` field is
    erased; only `transition` carries runtime weight. -/
structure CompiledAction where
  /-- The originating `Action`.  Trivially distinguishes distinct
      compiled actions: `(a₁ : CompiledAction) = (a₂ : CompiledAction)`
      forces `a₁.source = a₂.source`. -/
  source     : Action
  /-- The kernel `Transition` that the source compiles to.  This is
      what `apply_admissible` actually executes against `State`. -/
  transition : Transition

/-- The deployment-supplied compilation function: produces the
    `(source, transition)` pair for each action.  Phase-3 callers
    typically project out `transition` immediately for kernel-level
    work, while injectivity proofs read off the `source` field.

    The kernel never executes this function; it is supplied per
    deployment and audited as part of the law set. -/
def Action.compile (a : Action) : CompiledAction where
  source     := a
  transition := Action.compileTransition a

/-! ## Compilation injectivity (§4.13 / WU 3.2)

The redesigned `Action.compile : Action → CompiledAction` makes
injectivity a one-line structural fact.  The `source` field of
`CompiledAction` is a faithful copy of the input `Action`, so two
equal compiled actions necessarily have equal sources.

This sidesteps the Phase-2 design choice to make `Laws.freezeResource`
ignore its `r` parameter (which broke injectivity at the bare
`Transition` level), and the corresponding Phase-3 design choice to
compile `replaceKey` actions to the same identity `Transition` (the
authority-level effect happens in `apply_admissible`, not in the
compiled `Transition`).  Both choices remain in place — they are
load-bearing for the kernel's invariant proofs — and the
`CompiledAction` wrapper recovers the injectivity property at the
authority layer where it actually matters.

**Why this is sufficient for security.**  The signature is computed
over the canonical encoding of `(action, signer, nonce)` (Genesis
Plan §8.2 condition 3); admissibility's `authorized` predicate also
operates on `Action` values.  So distinct actions are distinguishable
at every authority-layer check, regardless of whether their compiled
transitions happen to coincide.  The `compile_injective` theorem
provides a *type-level* sanity check on top of these runtime
distinctions. -/

/-- §4.13 / WU 3.2: structural injectivity of `Action.compile`.
    The proof is a single `congrArg` on the `source` projection of
    `CompiledAction`.  No discrimination lemmas are needed — the
    `source` field IS the originating action, so equal compiled
    actions trivially have equal sources. -/
theorem Action.compile_injective : Function.Injective Action.compile :=
  fun _ _ h => congrArg CompiledAction.source h

/-- A direct-form companion to `compile_injective`, useful at call
    sites that work with explicit equalities rather than the
    `Function.Injective` wrapper.  Same one-line proof. -/
theorem Action.compile_eq_iff (a₁ a₂ : Action) :
    Action.compile a₁ = Action.compile a₂ ↔ a₁ = a₂ :=
  ⟨fun h => Action.compile_injective h, fun h => h ▸ rfl⟩

/-- The contrapositive form: distinct actions necessarily produce
    distinct compiled actions.  Useful for security-relevant call
    sites that want to reason "two distinct signed actions cannot
    share a compiled transition path" symbolically. -/
theorem Action.compile_ne_of_ne (a₁ a₂ : Action) (h : a₁ ≠ a₂) :
    Action.compile a₁ ≠ Action.compile a₂ :=
  fun heq => h (Action.compile_injective heq)

/-! ## Convenience accessors -/

/-- Project the kernel `Transition` out of a compiled action.  Most
    Phase-3 / Phase-5 call sites will use this rather than reading
    `.transition` directly. -/
@[inline] def CompiledAction.kernelTransition (ca : CompiledAction) : Transition :=
  ca.transition

/-- The kernel-level precondition of an action's compiled transition,
    evaluated at a given state. -/
@[inline] def Action.pre (a : Action) (s : State) : Prop :=
  (Action.compileTransition a).pre s

/-- Decidability of `Action.pre`, lifted from the underlying
    `Transition.decPre` field. -/
instance Action.decPre (a : Action) (s : State) : Decidable (Action.pre a s) :=
  (Action.compileTransition a).decPre s

/-- The kernel-level state transformer for an action.  Wraps the
    underlying `Transition.apply_impl`. -/
@[inline] def Action.apply_impl (a : Action) (s : State) : State :=
  (Action.compileTransition a).apply_impl s

/-! ## Sanity smoke checks (`example`s)

The `example` declarations below are compile-time-only: if the
`compile`/`source` agreement breaks (e.g. someone refactors
`Action.compile` to drop the `source` field), elaboration fails and
the build catches the regression. -/

example (r : ResourceId) (s r' : ActorId) (am : Amount) :
    (Action.compile (.transfer r s r' am)).source = .transfer r s r' am := rfl

example (r : ResourceId) (to : ActorId) (am : Amount) :
    (Action.compile (.mint r to am)).source = .mint r to am := rfl

example (r : ResourceId) (fr : ActorId) (am : Amount) :
    (Action.compile (.burn r fr am)).source = .burn r fr am := rfl

example (r : ResourceId) :
    (Action.compile (.freezeResource r)).source = .freezeResource r := rfl

example (actor : ActorId) (newKey : PublicKey) :
    (Action.compile (.replaceKey actor newKey)).source = .replaceKey actor newKey := rfl

example (r : ResourceId) (to : ActorId) (am : Amount) :
    (Action.compile (.reward r to am)).source = .reward r to am := rfl

example (r : ResourceId) (e : ActorId) (am : Amount) :
    (Action.compile (.distributeOthers r e am)).source =
      .distributeOthers r e am := rfl

example (r : ResourceId) (e : ActorId) (tr : Amount) :
    (Action.compile (.proportionalDilute r e tr)).source =
      .proportionalDilute r e tr := rfl

example (d : Disputes.Dispute) :
    (Action.compile (.dispute d)).source = .dispute d := rfl

example (idx : Disputes.LogIndex) :
    (Action.compile (.disputeWithdraw idx)).source = .disputeWithdraw idx := rfl

example (v : Disputes.Verdict) :
    (Action.compile (.verdict v)).source = .verdict v := rfl

example (idx : Disputes.LogIndex) :
    (Action.compile (.rollback idx)).source = .rollback idx := rfl

example (actor : ActorId) (pk : PublicKey) :
    (Action.compile (.registerIdentity actor pk)).source =
      .registerIdentity actor pk := rfl

example (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : Bridge.DepositId) :
    (Action.compile (.deposit r recipient amount d)).source =
      .deposit r recipient amount d := rfl

example (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : Bridge.EthAddress) :
    (Action.compile (.withdraw r sender amount rcp)).source =
      .withdraw r sender amount rcp := rfl

end Authority
end LegalKernel

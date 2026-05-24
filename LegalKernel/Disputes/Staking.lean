/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.Staking — kernel-conservative anti-fraud
staking for the §8.4 dispute pipeline.

Phase-6 incentive-integration amendment.  Provides:

  * `StakingPolicy` structure: deployment-supplied
    (stakeResource, stakeAmount, escrowActor, treasuryActor)
    parameters for anti-fraud staking.
  * `StakingPolicy.canStake`: the pre-filing balance check.
  * `StakedFilingError`: unified error type wrapping
    `FilingError` (per D2 of the plan).
  * `stakeFilingActions`: emits a single
    `transfer challenger → escrow stakeAmount` action at filing
    time.  Returns `[]` when staking is disabled
    (`stakeAmount = 0`).
  * `stakeResolutionActions`: emits a forfeiture transfer
    `escrow → treasury stakeAmount` on rejected / inconclusive
    verdicts; emits `[]` on upheld (per D1 of the plan: the
    runtime's `applyVerdict` rollback to `log[0..impugnedIdx-1]`
    implicitly returns the stake by virtue of replaying to a
    state BEFORE the staking transfer).
  * `fileDisputeStaked`: composes `fileDispute` (Stage 1) with
    the stake check, returning the dispute record + the
    filing-staking action the runtime should sign and append.

All emitted actions are `Action.transfer` — never `burn` — so
kernel-level conservation AND monotonicity hold.  Slashing is
modelled as a transfer to a deployment-supplied treasury actor,
not as token destruction; the treasury can later issue the
forfeited tokens back into circulation (e.g. as adjudicator-pool
funding).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Authority.Action
import LegalKernel.Disputes.Types
import LegalKernel.Disputes.Filing
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority
open LegalKernel.Runtime

/-! ## StakingPolicy structure (WU 6.19a) -/

/-- Deployment-supplied anti-fraud staking policy.

    The `stakeResource` is the resource (currency) the stake is
    denominated in; `stakeAmount` is the minimum stake required
    to file a dispute; `escrowActor` holds stakes during open
    disputes; `treasuryActor` receives forfeited stakes on
    rejected / inconclusive verdicts.

    Setting `stakeAmount = 0` disables staking (see
    `StakingPolicy.disabled`). -/
structure StakingPolicy where
  /-- Resource the stake is denominated in. -/
  stakeResource : ResourceId
  /-- Minimum stake required to file a dispute.  Filing fails if
      the challenger's balance at `stakeResource` is below this. -/
  stakeAmount   : Amount
  /-- Escrow actor that holds stakes during open disputes. -/
  escrowActor   : ActorId
  /-- Treasury actor that receives forfeited stakes on
      rejected / inconclusive verdicts. -/
  treasuryActor : ActorId

/-- The disabled staking policy: `stakeAmount = 0`, all helpers
    short-circuit to `[]`.  Use this for deployments that don't
    want anti-fraud staking. -/
def StakingPolicy.disabled : StakingPolicy where
  stakeResource := 0
  stakeAmount   := 0
  escrowActor   := 0
  treasuryActor := 0

/-! ## Pre-filing stake check (WU 6.19c) -/

/-- True iff the challenger has at least `stakeAmount` units of
    `stakeResource` in their balance.  Always returns `true` when
    `stakeAmount = 0` (the disabled-policy case). -/
def StakingPolicy.canStake
    (sp : StakingPolicy) (es : ExtendedState) (challenger : ActorId) : Bool :=
  decide (getBalance es.base sp.stakeResource challenger ≥ sp.stakeAmount)

/-! ## Unified error type (WU 6.19d, per plan D2) -/

/-- Errors that `fileDisputeStaked` can produce.  Wraps
    `FilingError` (the dispute-pipeline error vocabulary) plus
    a new `insufficientStake` variant for the staking precondition. -/
inductive StakedFilingError
  /-- Underlying filing error (from `fileDispute`'s Stage 1
      acceptance checks). -/
  | filing            (e : FilingError)
  /-- Challenger's balance at `stakeResource` is below the policy's
      `stakeAmount`.  Records both the actual balance (`have_`)
      and the required stake (`need`) for ops diagnostics. -/
  | insufficientStake (have_ : Amount) (need : Amount)
  deriving Repr

/-! ## Action emission (WUs 6.19e, 6.19f) -/

/-- The staking action(s) the runtime appends BEFORE the dispute
    SignedAction at filing time.  Returns a single
    `transfer challenger → escrow stakeAmount` when staking is
    enabled, or `[]` when disabled. -/
def stakeFilingActions (sp : StakingPolicy) (challenger : ActorId) :
    List Action :=
  if sp.stakeAmount = 0 then []
  else [Action.transfer sp.stakeResource challenger sp.escrowActor sp.stakeAmount]

/-- The staking action(s) the runtime appends AFTER the verdict
    SignedAction at resolution time.

    Per D1 of the plan: on `.upheld`, the rollback computed by
    `applyVerdict` replays `log[0..impugnedIdx-1]` from genesis,
    which is the state BEFORE the filing-staking transfer (since
    that transfer was appended after the impugned action).  The
    stake is therefore implicitly returned via the rollback;
    NO explicit refund action is needed.

    On `.rejected` / `.inconclusive`, no rollback happens, so the
    runtime emits an explicit `transfer escrow → treasury
    stakeAmount` to forfeit the stake into the deployment's
    treasury.

    **Rollback-returns-stake invariant (AR.13.3 / i-11
    sub-issue).**  Soundness of the implicit-refund path depends
    on the runtime appending the stake transfer *strictly* AFTER
    the impugned action's log index in the L2 log (since the
    rollback's `replayFromGenesis log[0..impugnedIdx-1]` does not
    include any entry whose index is `≥ impugnedIdx`).  The
    invariant is enforced by the runtime adaptor's ordering
    policy (see `LegalKernel/Disputes/Staking.lean`'s
    `fileDisputeStaked` step ordering) and is NOT proved as a
    Lean theorem on the kernel side — promoting it would require
    a runtime-ordering predicate as a parameter to the rollback
    semantics, a follow-up workstream. -/
def stakeResolutionActions (sp : StakingPolicy) (v : Verdict) : List Action :=
  if sp.stakeAmount = 0 then []
  else
    match v.outcome with
    | .upheld => []  -- per D1: rollback implicitly returns the stake
    | _       => [Action.transfer sp.stakeResource sp.escrowActor
                                   sp.treasuryActor sp.stakeAmount]

/-! ## fileDisputeStaked wrapper (WU 6.19g) -/

/-- Stage-1 wrapper: standard `fileDispute` + the staking
    precondition.  Returns the `DisputeRecord` PLUS the staking-
    filing actions the runtime should sign and append BEFORE the
    dispute SignedAction.

    Order of operations the runtime SHOULD follow:

      1. Call `fileDisputeStaked sp es log d`.
      2. On `.ok (rec, stakingActions)`:
         a. Sign each action in `stakingActions` with the
            deployment's reward-issuer key.
         b. Append the signed staking actions to the log via
            `processSignedAction` (this debits the challenger
            and credits the escrow).
         c. Append the dispute SignedAction itself.
      3. On `.error e`: surface the precise diagnostic. -/
def fileDisputeStaked
    (sp : StakingPolicy) (es : ExtendedState) (log : List LogEntry)
    (d : Dispute) :
    Except StakedFilingError (DisputeRecord × List Action) :=
  if !sp.canStake es d.challenger then
    let have_ := getBalance es.base sp.stakeResource d.challenger
    Except.error (.insufficientStake have_ sp.stakeAmount)
  else
    match fileDispute es log d with
    | .ok rec  => Except.ok (rec, stakeFilingActions sp d.challenger)
    | .error e => Except.error (.filing e)

/-! ## Sanity theorems (WU 6.19h) -/

/-- Every action emitted by `stakeFilingActions` is a `transfer`. -/
theorem stakeFilingActions_emits_only_transfers
    (sp : StakingPolicy) (challenger : ActorId) :
    ∀ a ∈ stakeFilingActions sp challenger,
      ∃ r s r' amt, a = Action.transfer r s r' amt := by
  intro a ha
  unfold stakeFilingActions at ha
  by_cases h : sp.stakeAmount = 0
  · rw [if_pos h] at ha; cases ha
  · rw [if_neg h] at ha
    simp only [List.mem_singleton] at ha
    exact ⟨sp.stakeResource, challenger, sp.escrowActor, sp.stakeAmount, ha⟩

/-- Every action emitted by `stakeResolutionActions` is a `transfer`. -/
theorem stakeResolutionActions_emits_only_transfers
    (sp : StakingPolicy) (v : Verdict) :
    ∀ a ∈ stakeResolutionActions sp v,
      ∃ r s r' amt, a = Action.transfer r s r' amt := by
  intro a ha
  unfold stakeResolutionActions at ha
  by_cases h : sp.stakeAmount = 0
  · rw [if_pos h] at ha; cases ha
  · rw [if_neg h] at ha
    cases hOutcome : v.outcome with
    | upheld =>
      rw [hOutcome] at ha
      cases ha
    | rejected =>
      rw [hOutcome] at ha
      simp only [List.mem_singleton] at ha
      exact ⟨sp.stakeResource, sp.escrowActor, sp.treasuryActor, sp.stakeAmount, ha⟩
    | inconclusive =>
      rw [hOutcome] at ha
      simp only [List.mem_singleton] at ha
      exact ⟨sp.stakeResource, sp.escrowActor, sp.treasuryActor, sp.stakeAmount, ha⟩

/-- Disabled policy emits no filing actions. -/
theorem stakeFilingActions_disabled_no_actions (challenger : ActorId) :
    stakeFilingActions StakingPolicy.disabled challenger = [] := by
  unfold stakeFilingActions StakingPolicy.disabled
  rfl

/-- Disabled policy emits no resolution actions. -/
theorem stakeResolutionActions_disabled_no_actions (v : Verdict) :
    stakeResolutionActions StakingPolicy.disabled v = [] := by
  unfold stakeResolutionActions StakingPolicy.disabled
  rfl

/-- Per D1: upheld verdicts emit no resolution actions (rollback
    implicitly returns the stake). -/
theorem stakeResolutionActions_upheld_no_actions
    (sp : StakingPolicy) (v : Verdict) (h : v.outcome = .upheld) :
    stakeResolutionActions sp v = [] := by
  unfold stakeResolutionActions
  by_cases hSA : sp.stakeAmount = 0
  · rw [if_pos hSA]
  · rw [if_neg hSA, h]

/-- Rejected verdicts emit a treasury transfer (forfeiture). -/
theorem stakeResolutionActions_rejected_emits_treasury_transfer
    (sp : StakingPolicy) (v : Verdict)
    (hSA : sp.stakeAmount > 0) (h : v.outcome = .rejected) :
    stakeResolutionActions sp v =
    [Action.transfer sp.stakeResource sp.escrowActor sp.treasuryActor sp.stakeAmount] := by
  unfold stakeResolutionActions
  have h_ne : sp.stakeAmount ≠ 0 := Nat.pos_iff_ne_zero.mp hSA
  rw [if_neg h_ne, h]

/-- Inconclusive verdicts emit a treasury transfer (forfeiture). -/
theorem stakeResolutionActions_inconclusive_emits_treasury_transfer
    (sp : StakingPolicy) (v : Verdict)
    (hSA : sp.stakeAmount > 0) (h : v.outcome = .inconclusive) :
    stakeResolutionActions sp v =
    [Action.transfer sp.stakeResource sp.escrowActor sp.treasuryActor sp.stakeAmount] := by
  unfold stakeResolutionActions
  have h_ne : sp.stakeAmount ≠ 0 := Nat.pos_iff_ne_zero.mp hSA
  rw [if_neg h_ne, h]

/-! ## fileDisputeStaked properties (WU 6.19i, 6.19j) -/

/-- `fileDisputeStaked` rejects an underfunded challenger.  The
    hypothesis `h : sp.canStake es d.challenger = false` is the
    `Bool`-form of "the challenger doesn't have enough stake".
    Holds for every `log` (the underfunding check happens before
    the log is consulted, so the conclusion is independent of `log`). -/
theorem fileDisputeStaked_rejects_underfunded
    (sp : StakingPolicy) (es : ExtendedState) (log : List LogEntry)
    (d : Dispute)
    (h : sp.canStake es d.challenger = false) :
    fileDisputeStaked sp es log d =
    .error (.insufficientStake
              (getBalance es.base sp.stakeResource d.challenger)
              sp.stakeAmount) := by
  unfold fileDisputeStaked
  -- The `if !sp.canStake ...` reduces because `!sp.canStake = !false = true`.
  have h_not : (!sp.canStake es d.challenger) = true := by rw [h]; rfl
  rw [if_pos h_not]

/-- Disabled policy passthrough: when staking is off, the
    `canStake` predicate is unconditionally `true` (every
    challenger trivially has at least 0 stake).  Combined with
    `stakeFilingActions_disabled_no_actions` and
    `stakeResolutionActions_disabled_no_actions`, this means the
    disabled-policy path through `fileDisputeStaked` reduces to
    `fileDispute` modulo the unused empty staking-action list. -/
theorem fileDisputeStaked_disabled_passthrough
    (es : ExtendedState) (d : Dispute) :
    StakingPolicy.disabled.canStake es d.challenger = true := by
  unfold StakingPolicy.canStake StakingPolicy.disabled
  simp

end Disputes
end LegalKernel

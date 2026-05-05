/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.Filing — Stage 1 (filing) of the §8.4 dispute
pipeline.

Phase 6 WU 6.3 + WU 6.11.  Provides:

  * `claimImpugnedIdx` — extract the primary impugned index from a
    `DisputeClaim`.
  * `fileDispute` — Stage 1 acceptance check: the dispute is
    syntactically well-formed, the challenger is registered, the
    impugned index is in range, and no prior dispute has been filed
    on the same `(challenger, claim)` pair.  Returns a
    `DisputeRecord` (with `status = open`) on success or a
    `FilingError` diagnostic.
  * `disputeStatus` — derive the current `DisputeStatus` from the log
    by scanning forward for verdicts and withdraw markers.  Returns
    `none` when the log entry at the given index is not an
    `Action.dispute` SignedAction.
  * `disputeWithdraw_idempotent` — type-level statement that filing
    a `disputeWithdraw` against an already-decided / already-
    withdrawn dispute is a kernel-level no-op (the action lands in
    the log but the dispute's status is unchanged).

Module discipline.  This module operates on a `List LogEntry`
(referred to as "the log" throughout) plus an `ExtendedState`
(for the registry check).  It does NOT mutate state — Stage 1 is
purely advisory.  The actual recording of a dispute happens via
`apply_admissible` on the `Action.dispute d` signed action; this
module's role is to validate the dispute *before* the runtime
records it.

This module is **not** part of the trusted computing base.  Bugs
here can produce a runtime that accepts a malformed dispute or
rejects a valid one (a deployment-level diagnostic problem) but
cannot violate any kernel invariant.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Disputes.Types
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority
open LegalKernel.Runtime
open Std

/-! ## DisputeClaim → impugned index extractor

Each `DisputeClaim` variant names one or two log indices.  The
*primary* impugned index is the one the dispute pipeline cares about
for in-range checks; for `doubleApply`, both indices must be in
range, but the primary is `idx₁`.  Stage 2's `checkEvidence`
consults both indices for `doubleApply`. -/

/-- The primary impugned log index for a dispute claim.  For most
    claim variants this is the unique `idx`; for `doubleApply` it is
    `idx₁`.  Used by the in-range check in `fileDispute`. -/
def claimImpugnedIdx : DisputeClaim → LogIndex
  | .preconditionFalse idx       => idx
  | .signatureInvalid idx        => idx
  | .nonceMismatch idx           => idx
  | .oracleMisreported idx _     => idx
  | .doubleApply idx₁ _          => idx₁

/-- The secondary impugned log index for a dispute claim (only
    `doubleApply` has one; other variants return `none`).  Used by
    `fileDispute` for `doubleApply`'s in-range check. -/
def claimSecondaryIdx : DisputeClaim → Option LogIndex
  | .doubleApply _ idx₂          => some idx₂
  | _                            => none

/-! ## Log scanning helpers

`isOpenDisputeFor d log` returns true iff the log already contains
a dispute log entry with the same `(challenger, claim)` pair as
`d`.  Used by `fileDispute`'s duplicate check. -/

/-- True iff `entry` is an `Action.dispute d'` with the same
    `(challenger, claim)` as `d`. -/
def disputeMatchesEntry (d : Dispute) (entry : LogEntry) : Bool :=
  match entry.signedAction.action with
  | .dispute d' => decide (d'.challenger = d.challenger ∧ d'.claim = d.claim)
  | _           => false

/-- Find the index (if any) at which a prior dispute by the same
    challenger with the same claim was filed.  Returns the *first*
    such index. -/
def findPriorDisputeIdx (d : Dispute) (log : List LogEntry) : Option LogIndex :=
  let rec go (i : Nat) : List LogEntry → Option LogIndex
    | [] => none
    | e :: rest =>
      if disputeMatchesEntry d e then some i
      else go (i + 1) rest
  go 0 log

/-! ## fileDispute (Stage 1; WU 6.3)

`fileDispute` performs **three** of the four §8.4.4 acceptance
checks, in order:

  1. **`unknownChallenger`** — `d.challenger` must be registered in
     `es.registry`.
  2. **`indexOutOfRange`** — every impugned index in `d.claim` must
     be `< log.length`.  Both primary (`claimImpugnedIdx`) and
     secondary (`claimSecondaryIdx`, for `doubleApply`) indices are
     checked.
  3. **`duplicateDispute`** — no earlier log entry with the same
     `(challenger, claim)` pair.  **Status-blind**: a withdrawn or
     decided prior dispute still triggers this error.

The fourth §8.4.4 check, `malformedAction` ("the dispute is not
wrapped in `Action.dispute`"), is **not** performed by this
function: `fileDispute` takes `d : Dispute` directly, so the
caller must already have extracted the `Dispute` from a
`SignedAction`.  The `FilingError.malformedAction` constructor is
exposed for deployment-level wrappers that combine extraction +
filing — see `Disputes/Types.lean` for details.

On success, returns a `DisputeRecord` with `status = open`.  The
`idx` field is set to `log.length` (the position the dispute will
take on the log when the runtime appends it).

Note: `fileDispute` does NOT consume the dispute's nonce — that's
the runtime layer's job (`apply_admissible` advances the nonce on
the dispute's signer when the `Action.dispute` is applied).
Stage 1 is the *pre-acceptance* check; Stage 4's `applyVerdict`
performs the post-acceptance state transition. -/

/-- Stage 1 of the dispute pipeline.  Returns the prepared
    `DisputeRecord` on success or a precise `FilingError` on
    failure.  Pure — no IO, no state mutation. -/
def fileDispute
    (es : ExtendedState) (log : List LogEntry) (d : Dispute) :
    Except FilingError DisputeRecord :=
  -- 1. Challenger registration check.
  match es.registry[d.challenger]? with
  | none =>
    .error .unknownChallenger
  | some _ =>
    -- 2. Primary in-range check.
    let primaryIdx := claimImpugnedIdx d.claim
    if primaryIdx ≥ log.length then
      .error (.indexOutOfRange primaryIdx log.length)
    else
      -- 3. Secondary in-range check (for doubleApply).
      match claimSecondaryIdx d.claim with
      | some secondaryIdx =>
        if secondaryIdx ≥ log.length then
          .error (.indexOutOfRange secondaryIdx log.length)
        else
          -- 4. Duplicate check.
          match findPriorDisputeIdx d log with
          | some priorIdx =>
            .error (.duplicateDispute priorIdx)
          | none =>
            .ok { dispute := d, idx := log.length, status := .open }
      | none =>
        match findPriorDisputeIdx d log with
        | some priorIdx =>
          .error (.duplicateDispute priorIdx)
        | none =>
          .ok { dispute := d, idx := log.length, status := .open }

/-! ## disputeWithdraw idempotency (WU 6.11)

The `Action.disputeWithdraw idx` action records a withdrawal in the
log.  Its kernel-level effect is identity (compileTransition is the
freezeResource no-op).  Its *semantic* effect is to mark the
dispute at index `idx` as withdrawn — but only if that dispute is
currently `open`.  Withdraw of an already-decided or already-
withdrawn dispute is a no-op at the *status* level: the dispute
remains in its prior state.

This is the WU 6.11 idempotency property: filing the same withdraw
twice does not change the dispute's status. -/

/-- Apply a withdrawal action to a dispute status, idempotently.
    Withdrawing an `open` dispute marks it `withdrawn`; withdrawing
    a `decided` or `withdrawn` dispute leaves the status unchanged. -/
def applyWithdraw : DisputeStatus → DisputeStatus
  | .open       => .withdrawn
  | s           => s

/-- Apply a verdict outcome to an `open` dispute, transitioning it
    to `decided outcome`; non-open disputes are unchanged
    (idempotency at the verdict level). -/
def applyVerdictOutcome (outcome : EvidenceVerdict) : DisputeStatus → DisputeStatus
  | .open       => .decided outcome
  | s           => s

/-! ## disputeStatus: walk-the-log derivation

Given the log and the index `disputeIdx` of the original
`Action.dispute` entry, scan the log entries at indices `>
disputeIdx` for matching `Action.disputeWithdraw disputeIdx` or
`Action.verdict v` entries.  Return the derived status.

Returns `none` iff `log[disputeIdx]?` is not an `Action.dispute _`. -/

/-- The status of a filed dispute, derived by scanning the log
    forward from the dispute's filing index.  Returns `none` if
    there is no `Action.dispute` log entry at the given index. -/
def disputeStatus (log : List LogEntry) (disputeIdx : LogIndex) :
    Option DisputeStatus :=
  match log[disputeIdx]? with
  | none => none
  | some entry =>
    match entry.signedAction.action with
    | .dispute _ =>
      -- Walk forward from disputeIdx + 1 to log.length, accumulating status.
      let rec scan (i : Nat) (current : DisputeStatus) : DisputeStatus :=
        if h : i < log.length then
          match log[i]? with
          | some e =>
            match e.signedAction.action with
            | .disputeWithdraw idx =>
              if idx = disputeIdx then scan (i + 1) (applyWithdraw current)
              else scan (i + 1) current
            | .verdict v =>
              if v.disputeId = disputeIdx then
                scan (i + 1) (applyVerdictOutcome v.outcome current)
              else scan (i + 1) current
            | _ => scan (i + 1) current
          | none => current
        else
          let _ := h
          current
      termination_by log.length - i
      some (scan (disputeIdx + 1) .open)
    | _ => none

/-! ## Idempotency theorems (WU 6.11) -/

/-- Withdrawing an already-decided dispute does not change its
    status.  The headline idempotency property: even if the runtime
    accepts a withdraw against a decided dispute (because the
    challenger was unaware of the verdict), the dispute's status
    remains `decided` rather than reverting to `withdrawn`. -/
theorem applyWithdraw_decided_idempotent (outcome : EvidenceVerdict) :
    applyWithdraw (.decided outcome) = .decided outcome := rfl

/-- Withdrawing an already-withdrawn dispute is a no-op. -/
theorem applyWithdraw_withdrawn_idempotent :
    applyWithdraw .withdrawn = .withdrawn := rfl

/-- Withdrawing an open dispute closes it as `withdrawn`. -/
theorem applyWithdraw_open : applyWithdraw .open = .withdrawn := rfl

/-- Two consecutive withdraws are equivalent to one. -/
theorem applyWithdraw_idempotent (s : DisputeStatus) :
    applyWithdraw (applyWithdraw s) = applyWithdraw s := by
  cases s <;> rfl

/-! ## fileDispute basic properties -/

/-- `fileDispute` rejects an unregistered challenger. -/
theorem fileDispute_rejects_unknown_challenger
    (es : ExtendedState) (log : List LogEntry) (d : Dispute)
    (h : es.registry[d.challenger]? = none) :
    fileDispute es log d = .error .unknownChallenger := by
  unfold fileDispute
  rw [h]

/-- `fileDispute` returns `.ok` iff all four conditions hold (we state
    the registration condition; in-range and duplicate are stated
    separately).  Used as an API-stability sanity check by the test
    suite. -/
theorem fileDispute_returns_open_status
    (es : ExtendedState) (log : List LogEntry) (d : Dispute)
    (rec : DisputeRecord) (h : fileDispute es log d = .ok rec) :
    rec.status = .open ∧ rec.dispute = d ∧ rec.idx = log.length := by
  -- Generic strategy: every `.ok` branch in `fileDispute` assigns
  -- the fields `dispute := d`, `idx := log.length`, `status := .open`,
  -- so the projection reads them off directly.  We walk the case
  -- tree, deriving a contradiction in every error branch.
  simp only [fileDispute] at h
  split at h
  case _ => exact absurd h (by simp)
  case _ =>
    split at h
    case _ => exact absurd h (by simp)
    case _ =>
      split at h
      case _ =>
        split at h
        case _ => exact absurd h (by simp)
        case _ =>
          split at h
          case _ => exact absurd h (by simp)
          case _ =>
            have hr : rec = { dispute := d, idx := log.length, status := .open } :=
              (Except.ok.inj h).symm
            rw [hr]
            exact ⟨rfl, rfl, rfl⟩
      case _ =>
        split at h
        case _ => exact absurd h (by simp)
        case _ =>
          have hr : rec = { dispute := d, idx := log.length, status := .open } :=
            (Except.ok.inj h).symm
          rw [hr]
          exact ⟨rfl, rfl, rfl⟩

end Disputes
end LegalKernel

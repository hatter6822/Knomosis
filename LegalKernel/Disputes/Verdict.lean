/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.Verdict — Stages 3 + 4 of the §8.4 dispute
pipeline.

Phase 6 WU 6.9 + WU 6.10.  Provides:

  * **`QuorumPolicy`** — the deployment-supplied quorum threshold +
    list of approved adjudicators.
  * **`countVerifiedSignatures`** — count how many of the verdict's
    `(signer, sig)` pairs verify under their registered keys.
  * **`proposeVerdict`** (Stage 3, WU 6.9) — validate a verdict's
    quorum + outcome consistency.  Returns the verdict on success
    or a `VerdictError`.
  * **`applyVerdict`** (Stage 4, WU 6.10) — apply an upheld
    verdict's rollback effect: replay the log up to `disputeIdx-1
    (after locating the impugned action) to recover the rolled-
    back `ExtendedState`.  Returns the rolled-back state on success
    or a `VerdictError`.
  * **Status pre-check** — `applyVerdict` rejects with `alreadyDecided`
    if the dispute has already been closed by a prior verdict or
    withdraw.

The headline takeaway: an upheld verdict whose dispute targets log
entry `idx` produces a *forward action* (`Action.rollback idx_target`)
whose effect is "set state to the replay of `log[0..idx_target-1]`
from genesis".  The runtime layer wires the rollback in by
appending the `Action.rollback` to the log and using the
recomputed `ExtendedState` as the new runtime state.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong rollback decisions or fail to roll back
correctly (a deployment-level adjudication problem) but cannot
violate any kernel invariant — every state advance still goes
through `apply_admissible` (or its dispute-pipeline analogue
`applyVerdict`), which carries the relevant witnesses.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Disputes.Types
import LegalKernel.Disputes.Filing
import LegalKernel.Disputes.Evidence
import LegalKernel.Runtime.Replay

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority
open LegalKernel.Runtime

/-! ## QuorumPolicy

The quorum threshold + approved adjudicator list for verdict
acceptance.  Genesis Plan §8.4.2 specifies this as part of the
`AuthorityPolicy`, but Phase 6 splits it out into its own structure
for two reasons:

  1. **Modularity.**  The quorum policy is a deployment-time
     decision that may change independently of the static
     authorisation predicate.
  2. **Test ergonomics.**  Tests can inject a quorum policy
     directly without constructing a full authority predicate.

The `verifierCount` field is the minimum number of valid
adjudicator signatures required.  Deployments typically set this
to a non-trivial fraction of `approvedAdjudicators.length` (e.g.
`2/3` of an odd-sized adjudicator set). -/

/-- Deployment-supplied quorum policy: who can sign verdicts and
    how many signatures are required for acceptance. -/
structure QuorumPolicy where
  /-- The list of adjudicator `ActorId`s whose signatures are
      eligible to count towards the quorum.  Verdict signers not in
      this list are silently ignored (their signature does not
      contribute to the count, but they are not actively rejected). -/
  approvedAdjudicators : List ActorId
  /-- The minimum number of valid signatures required for verdict
      acceptance.  Must be `≤ approvedAdjudicators.length` for any
      verdict to be acceptable. -/
  required             : Nat

/-- A trivial single-adjudicator quorum policy.  Useful for tests
    and for deployments that pre-trust a single adjudicator. -/
def QuorumPolicy.singleton (adjudicator : ActorId) : QuorumPolicy where
  approvedAdjudicators := [adjudicator]
  required             := 1

/-- An empty quorum policy: no adjudicators, no required count.
    Every verdict is rejected (`required = 0` ≤ `verified = 0`,
    but `approvedAdjudicators = []` means no signature is ever
    eligible — see `countVerifiedSignatures` discipline below).

    Strictly: with `required = 0`, *any* verdict passes the count
    threshold (vacuously).  Deployments using `QuorumPolicy.empty`
    should also set `required > 0` via `QuorumPolicy.requiredAtLeast`
    if non-trivial adjudication is desired. -/
def QuorumPolicy.empty : QuorumPolicy where
  approvedAdjudicators := []
  required             := 0

/-! ## Signature counting

`countVerifiedSignatures` walks the verdict's `(signers[i], sigs[i])`
pairs and increments a counter for each `i` such that:

  1. `signers[i]` is in the policy's `approvedAdjudicators` list,
  2. `signers[i]` is registered in the runtime's key registry, and
  3. `Verify pk msg sig` returns `true` for the verdict's canonical
     encoding under `signers[i]`'s registered key.

The function is total: missing signatures, unregistered signers, or
mismatched signature lengths simply produce a count that does not
clear the quorum threshold. -/

/-- The bytes that are signed by adjudicators when proposing a
    verdict.  Phase 6 placeholder analogous to `signingInput`
    (Phase 3 / Phase 4); a future Phase-6 follow-up will replace
    this with a domain-separated CBE encoding (Genesis Plan §8.8.5
    extended to verdicts). -/
def verdictSigningInput (v : Verdict) : ByteArray :=
  -- Phase-6 placeholder: returns a deterministic-but-content-free
  -- byte sequence.  Like Phase 3's `signingInput`, this is safe at
  -- the *Lean proof* level (Verify is opaque) but requires a
  -- domain-separated CBE encoding for the runtime layer.
  let _ := v
  ByteArray.empty

/-- Count the `(signer, sig)` pairs in a verdict whose signer is
    on the approved-adjudicator list AND whose signature verifies
    under their registered key.

    Walks the parallel `signers` and `sigs` lists, skipping pairs
    where the signer is not approved, not registered, or whose
    signature does not verify. -/
def countVerifiedSignatures
    (qp : QuorumPolicy) (currentEs : ExtendedState) (v : Verdict) : Nat :=
  let msg := verdictSigningInput v
  let pairs : List (ActorId × Signature) := List.zip v.signers v.sigs
  pairs.foldl (fun acc (a, s) =>
    if decide (a ∈ qp.approvedAdjudicators) then
      match currentEs.registry[a]? with
      | some pk =>
        if Verify pk msg s = true then
          acc + 1
        else
          acc
      | none => acc
    else
      acc) 0

/-! ## proposeVerdict (Stage 3; WU 6.9)

Validate a proposed verdict:

  1. The `disputeId` must reference an `Action.dispute` log entry.
  2. The dispute must be currently `open` (not already decided or
     withdrawn).
  3. The verdict's `outcome` must agree with `checkEvidence`'s
     deterministic re-evaluation of the dispute's evidence.
  4. The `(signers, sigs)` lists must produce at least
     `quorum.required` verified signatures.

Returns the validated verdict on success (which the runtime then
appends as `Action.verdict v` to the log).  All four checks are
kept in this single function so that a deployment can unit-test
the proposal pipeline without building a full multi-stage
fixture. -/

/-- Stage 3 of the dispute pipeline: validate a proposed verdict.
    Returns the verdict on success or a precise `VerdictError`. -/
def proposeVerdict
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError Verdict :=
  -- 1. The disputeId must reference an `Action.dispute` entry.
  match log[v.disputeId]? with
  | none => .error (.unknownDispute v.disputeId)
  | some entry =>
    match entry.signedAction.action with
    | .dispute d =>
      -- 2. The dispute must still be `open`.
      match disputeStatus log v.disputeId with
      | some .open =>
        let drec : DisputeRecord := { dispute := d, idx := v.disputeId, status := .open }
        -- 3. Outcome must match the deterministic re-evaluation.
        let recomputed := checkEvidence P oracle currentEs genesis log drec
        if recomputed ≠ v.outcome then
          .error .outcomeMismatch
        else
          -- 4. Quorum check.
          let verified := countVerifiedSignatures qp currentEs v
          if verified < qp.required then
            .error (.quorumNotMet verified qp.required)
          else
            .ok v
      | _ => .error .alreadyDecided
    | _ => .error (.unknownDispute v.disputeId)

/-! ## applyVerdict (Stage 4; WU 6.10)

If the verdict is `upheld`, compute the rollback target by replaying
`log[0..impugnedIdx-1]` from genesis.  The impugned index is
extracted from the dispute's claim (via `claimImpugnedIdx`).
Returns the rolled-back `ExtendedState`.

If the verdict is `rejected` or `inconclusive`, no state change:
return the runtime's current state unchanged.  The verdict is
still recorded (the runtime appends `Action.verdict v` to the log)
for audit-trail purposes — the kernel level treats it as a no-op,
and downstream `disputeStatus` reads recover the verdict state.

If the verdict's outcome cannot be applied (replay failure),
return `VerdictError.replayFailed`.  This indicates either a
corrupt log or a kernel runtime bug — neither is recoverable from
within the dispute pipeline. -/

/-- Stage 4 of the dispute pipeline: apply the verdict.  For
    `upheld` verdicts, computes the rollback target via prefix
    replay; for `rejected` / `inconclusive` verdicts, returns the
    current state unchanged.

    Pre-validation: the `proposeVerdict` step (Stage 3) is the
    upstream caller; if you want the full Stage 3 + 4 pipeline,
    chain `proposeVerdict` then `applyVerdict`.  This function
    accepts a "validated" verdict (one that already passed Stage 3
    checks); deployments that bypass Stage 3 must apply their own
    verifier discipline.

    Returns the post-application `ExtendedState` on success.  For
    `rejected`/`inconclusive` outcomes, the returned state equals
    `currentEs` (no rollback). -/
def applyVerdict
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError ExtendedState :=
  -- Look up the dispute the verdict targets.
  match log[v.disputeId]? with
  | none => .error (.unknownDispute v.disputeId)
  | some entry =>
    match entry.signedAction.action with
    | .dispute d =>
      -- Status pre-check: don't apply a verdict to an already-closed dispute.
      match disputeStatus log v.disputeId with
      | some .open =>
        match v.outcome with
        | .upheld =>
          -- Compute the rollback target: replay log[0..impugnedIdx-1] from genesis.
          let impugnedIdx := claimImpugnedIdx d.claim
          match replayPrefix P genesis log impugnedIdx with
          | none => .error .replayFailed
          | some rolledBack => .ok rolledBack
        | _ =>
          -- rejected or inconclusive: no rollback, no state change.
          .ok currentEs
      | _ => .error .alreadyDecided
    | _ => .error (.unknownDispute v.disputeId)

/-! ## Properties -/

/-- `proposeVerdict` is deterministic. -/
theorem proposeVerdict_deterministic
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs₁ currentEs₂ : ExtendedState) (genesis₁ genesis₂ : ExtendedState)
    (log₁ log₂ : List LogEntry) (v₁ v₂ : Verdict)
    (h_es : currentEs₁ = currentEs₂) (h_g : genesis₁ = genesis₂)
    (h_l : log₁ = log₂) (h_v : v₁ = v₂) :
    proposeVerdict P oracle qp currentEs₁ genesis₁ log₁ v₁ =
    proposeVerdict P oracle qp currentEs₂ genesis₂ log₂ v₂ := by
  rw [h_es, h_g, h_l, h_v]

/-- `applyVerdict` with a `rejected` outcome leaves the state
    unchanged (provided the dispute is open and the disputeId
    references a valid dispute entry). -/
theorem applyVerdict_rejected_no_change
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d)
    (h_open : disputeStatus log v.disputeId = some .open)
    (h_rej : v.outcome = .rejected) :
    applyVerdict P currentEs genesis log v = .ok currentEs := by
  unfold applyVerdict
  rw [h_idx]
  dsimp only
  rw [h_act]
  dsimp only
  rw [h_open]
  dsimp only
  rw [h_rej]

/-- `applyVerdict` with an `inconclusive` outcome leaves the state
    unchanged. -/
theorem applyVerdict_inconclusive_no_change
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d)
    (h_open : disputeStatus log v.disputeId = some .open)
    (h_inc : v.outcome = .inconclusive) :
    applyVerdict P currentEs genesis log v = .ok currentEs := by
  unfold applyVerdict
  rw [h_idx]
  dsimp only
  rw [h_act]
  dsimp only
  rw [h_open]
  dsimp only
  rw [h_inc]

/-- `applyVerdict` rejects a verdict against an unknown dispute. -/
theorem applyVerdict_unknown_dispute
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (h : log[v.disputeId]? = none) :
    applyVerdict P currentEs genesis log v = .error (.unknownDispute v.disputeId) := by
  unfold applyVerdict
  rw [h]

/-- `applyVerdict` is deterministic. -/
theorem applyVerdict_deterministic
    (P : AuthorityPolicy) (currentEs₁ currentEs₂ : ExtendedState)
    (genesis₁ genesis₂ : ExtendedState) (log₁ log₂ : List LogEntry) (v₁ v₂ : Verdict)
    (h_es : currentEs₁ = currentEs₂) (h_g : genesis₁ = genesis₂)
    (h_l : log₁ = log₂) (h_v : v₁ = v₂) :
    applyVerdict P currentEs₁ genesis₁ log₁ v₁ =
    applyVerdict P currentEs₂ genesis₂ log₂ v₂ := by
  rw [h_es, h_g, h_l, h_v]

end Disputes
end LegalKernel

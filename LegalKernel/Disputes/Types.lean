/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.Types — the §8.4 dispute / verdict data types.

Phase 6 WU 6.1.  Defines the first-order data the dispute pipeline
operates on:

  * `LogIndex` — a `Nat` alias, identifying a single entry in the
    runtime's transition log.
  * `DisputeClaim` — the five-variant inductive enumerating the
    structural reasons a log entry may be wrong (precondition false,
    bad signature, wrong nonce, oracle mis-report, double-apply).
  * `EvidenceVerdict` — the three-state outcome of evidence
    evaluation (`upheld` / `rejected` / `inconclusive`).
  * `Dispute` — a signed challenge: who is challenging, what claim,
    what evidence, plus the standard nonce + signature replay-
    protection envelope.
  * `Verdict` — a quorum-signed adjudicator decision pointing at a
    dispute log entry plus the evidence outcome.
  * `DisputeRecord` — the runtime-derived per-dispute view: the
    filed `Dispute`, the index it was filed at, plus a `status` tag
    distinguishing `open` / `withdrawn` / `decided` disputes.
  * `OraclePolicy` — the deployment-supplied per-oracle evidence
    verifier (consumed by `checkEvidence`'s `oracleMisreported`
    case).

Module discipline.  This module ships *types only* — no functions
that mutate state or read the log.  The dispute pipeline (filing,
evidence checking, verdict application) lives in sibling modules
under `LegalKernel/Disputes/`.  Encodings for the new types live in
`LegalKernel/Encoding/Disputes.lean`.

This module is **not** part of the trusted computing base.  The
kernel's invariant proofs do not depend on dispute data; bugs here
weaken the deployment's adjudication guarantees but cannot violate
any kernel invariant.

Coverage map:

  * WU 6.1 — types and their `Repr` / `DecidableEq` instances.
-/

import LegalKernel.Kernel
import LegalKernel.Authority.Crypto

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority

/-! ## LogIndex

A `Nat` alias.  Phase 5's runtime tracks the log entry count via
`RuntimeState.logIndex : Nat`; we re-export the same type here under
a more suggestive name so that `Dispute.idx`-style fields document
their domain at the type level. -/

/-- An index into the runtime's transition log.  Each `LogEntry`
    appended to the log has a unique `LogIndex` (its position,
    counted from 0).  Disputes name a specific log entry by index. -/
abbrev LogIndex : Type := Nat

/-! ## DisputeClaim (§8.4.1)

The five structural reasons a log entry may be wrong.  Genesis Plan
§8.4.1 verbatim: each variant carries the index of the impugned
entry plus any auxiliary data the verifier needs (oracle counter-
evidence; double-apply's *second* index).

**Constructor-ordering policy (append-only).**  Phase 6 ships the
five variants in the order Genesis Plan §8.4.1 lists them.  The
indices are part of the canonical encoding (Phase 6 WU 6.1) and
cannot shift retroactively without invalidating every signed
dispute in production. -/

/-- The five variants of a dispute claim.  Each variant names the
    impugned `LogIndex` plus any auxiliary data the corresponding
    `checkEvidence` verifier consumes. -/
inductive DisputeClaim
  /-- The action's compiled precondition was false at the time of
      application (a kernel violation by collusion of the runtime
      and the signer).  Verifier replays the log up to `idx-1` and
      evaluates `Action.compile log[idx].action |>.transition.pre`
      against the recovered pre-state. -/
  | preconditionFalse  (idx : LogIndex)
  /-- The signature on `log[idx]` did not verify under the registered
      key for `log[idx].signer`.  Indicates either a kernel runtime
      bug or registry corruption.  Verifier re-runs `Verify` against
      the registered key. -/
  | signatureInvalid   (idx : LogIndex)
  /-- The nonce in `log[idx]` did not match the actor's
      next-expected nonce at the time of application.  Indicates
      either a replay of an earlier action or a skip in nonce
      sequencing.  Verifier recomputes `expectsNonce es_{idx-1}
      log[idx].signer` and compares. -/
  | nonceMismatch      (idx : LogIndex)
  /-- An oracle action at `idx` reported a value that external
      evidence (carried in the dispute's `evidence` field, but bound
      here for verifier convenience) contradicts.  Verifier consults
      a deployment-supplied `OraclePolicy.verifier`. -/
  | oracleMisreported  (idx : LogIndex) (evidence : ByteArray)
  /-- The same nonce was applied twice (`idx₁ ≠ idx₂`, but
      `log[idx₁].nonce = log[idx₂].nonce` and same signer).  This
      should be impossible under a correctly-functioning kernel
      (the §8.5 `replay_impossible` theorem rules it out); a
      successful `doubleApply` dispute is a symptom of a kernel
      runtime bug. -/
  | doubleApply        (idx₁ idx₂ : LogIndex)
  deriving Repr, DecidableEq

/-! ## EvidenceVerdict (§8.4.2)

The three-state outcome of `checkEvidence`.  `upheld` means the
claim is established by the evidence (deployment SHOULD apply
rollback); `rejected` means the evidence does not support the claim
(deployment SHOULD discard the dispute); `inconclusive` means the
evidence parses but does not establish the claim either way
(deployment chooses to retry with stronger evidence, escalate to a
human adjudicator, or close the dispute). -/

/-- The outcome of an evidence check.  `upheld` → claim established;
    `rejected` → claim refuted; `inconclusive` → evidence is well-
    formed but does not decide the claim. -/
inductive EvidenceVerdict
  /-- The claim is established by the evidence.  Upheld disputes
      proceed to verdict proposal and (potentially) rollback. -/
  | upheld
  /-- The evidence refutes the claim — either the impugned entry
      was correct after all, or the supplied evidence does not
      contradict the entry's effects. -/
  | rejected
  /-- The evidence is well-formed but does not decide the claim
      either way.  Deployment chooses how to handle this case
      (retry with stronger evidence, escalate, or close). -/
  | inconclusive
  deriving Repr, DecidableEq

/-! ## Dispute (§8.4.1)

A challenge to a specific log entry, signed by a registered actor
(the *challenger*).  Like every other action in the system, a
`Dispute` is wrapped in a `SignedAction` (`Action.dispute (d :
Dispute)`) and consumes the standard nonce + signature replay-
protection machinery.

The `evidence` field is interpreted per-claim:

  * `preconditionFalse` / `signatureInvalid` / `nonceMismatch` /
    `doubleApply`: ignored by the verifier (the claim is established
    by re-deriving facts from the log, not from the dispute's
    evidence).
  * `oracleMisreported`: consumed by the deployment's
    `OraclePolicy.verifier` to determine whether the counter-evidence
    establishes the claim. -/

/-- A signed challenge against a specific log entry.  Carries the
    challenger's identity, the structural claim, optional supporting
    evidence bytes, plus the standard nonce + signature replay-
    protection envelope.

    A `Dispute` is itself wrapped in `Action.dispute` to become a
    full `SignedAction` that the runtime appends to the log; the
    challenger's signature is over the canonical encoding of
    `(action = Action.dispute d, signer = d.challenger, nonce =
    d.nonce)`. -/
structure Dispute where
  /-- The actor filing the dispute.  Must be registered in
      `ExtendedState.registry` for `fileDispute` (Stage 1) to
      accept the challenge. -/
  challenger : ActorId
  /-- The structural claim about which log entry is wrong and why. -/
  claim      : DisputeClaim
  /-- Optional supporting bytes.  Interpretation is per-claim:
      `oracleMisreported` consumes them; the other claims ignore
      them (the verifier re-derives the claim from the log). -/
  evidence   : ByteArray
  /-- The challenger's per-actor nonce at the time of filing. -/
  nonce      : Nonce
  /-- The challenger's signature over the canonical encoding of
      this dispute. -/
  sig        : Signature
  deriving Repr, DecidableEq

/-! ## Verdict (§8.4.2)

A signed decision by one or more adjudicators.  References the
*dispute log entry* (not the impugned entry) — adjudicators sign
verdicts about disputes, not about underlying actions.

The `signers` and `sigs` lists are parallel: `signers[i]` signed the
verdict's canonical encoding, producing `sigs[i]`.  A verdict is
*quorum-valid* when at least `quorum` of the listed `(signer, sig)`
pairs verify under their respective registered keys.  The `quorum`
threshold is supplied by the deployment's authority policy. -/

/-- A quorum-signed adjudicator decision.  References the dispute
    log entry by its `LogIndex`; carries the evidence outcome plus
    a free-form rationale (typically a canonical evidence summary). -/
structure Verdict where
  /-- The log index of the dispute entry being adjudicated.  This
      is the entry containing the `Action.dispute d` SignedAction
      whose claim the verdict resolves. -/
  disputeId  : LogIndex
  /-- The evidence-check outcome.  Re-evaluating the dispute's
      evidence against the log and the deployment's `OraclePolicy`
      MUST reproduce this value (deterministic verifier — see
      §8.4.3). -/
  outcome    : EvidenceVerdict
  /-- A free-form summary of the evidence and reasoning.  Bytes here
      are not consulted by the kernel; deployments use them for
      audit-trail readability. -/
  rationale  : ByteArray
  /-- The list of adjudicator `ActorId`s whose signatures are
      attached.  Order matches `sigs`. -/
  signers    : List ActorId
  /-- The list of adjudicator signatures, in the same order as
      `signers`.  Each `sigs[i]` is `Verify`-checked under
      `signers[i]`'s registered public key. -/
  sigs       : List Signature
  deriving Repr, DecidableEq

/-! ## DisputeStatus

Disputes go through three operational states:

  * `open` — filed, awaiting adjudication;
  * `withdrawn` — the challenger filed an `Action.disputeWithdraw`,
    closing the dispute without a verdict;
  * `decided` — a quorum-signed `Action.verdict` was applied,
    closing the dispute with an `EvidenceVerdict`.

The status is *derived* from the log: scanning the entries
identifies open disputes and detects subsequent verdicts /
withdrawals.  We do not store the status on disk; it is recomputed
on demand by `disputeStatus` (in `Disputes/Filing.lean`). -/

/-- The runtime-derived status of a filed dispute.  Disputes
    transition through `open` → `withdrawn` or `open` → `decided`
    at most once; subsequent attempts to mutate a closed dispute
    are rejected by Stage 1 (`fileDispute`'s `duplicateDispute`
    check) or Stage 4 (`applyVerdict`'s `alreadyDecided` check). -/
inductive DisputeStatus
  /-- Filed and awaiting either a verdict or a withdraw. -/
  | open
  /-- Closed by the challenger's `Action.disputeWithdraw`. -/
  | withdrawn
  /-- Closed by a quorum-signed `Action.verdict` carrying the
      evaluated `EvidenceVerdict`. -/
  | decided (outcome : EvidenceVerdict)
  deriving Repr, DecidableEq

/-! ## DisputeRecord

The runtime's view of a single filed dispute: the underlying
`Dispute` data, the log index where it was filed, plus the current
`DisputeStatus`.  Used by `fileDispute`'s output (Stage 1) and by
`disputeStatus`'s walk-the-log derivation. -/

/-- A filed dispute's runtime-level summary.  `dispute` is the data
    that was signed and submitted; `idx` is the log index where it
    landed; `status` is the derived current state. -/
structure DisputeRecord where
  /-- The originating `Dispute` data — what the challenger signed. -/
  dispute : Dispute
  /-- The log index where the `Action.dispute` signed action was
      appended.  Verdict actions reference this index. -/
  idx     : LogIndex
  /-- The derived dispute status (open / withdrawn / decided). -/
  status  : DisputeStatus
  deriving Repr, DecidableEq

/-! ## OraclePolicy (§8.4.2 — `oracleMisreported` plug-in)

Deployment-supplied evidence verifier for the `oracleMisreported`
claim.  The verifier consumes:

  * the impugned log index (so the verifier can correlate the
    counter-evidence with the oracle entry's payload), and
  * the dispute's `evidence` byte string.

Returns an `EvidenceVerdict` (deterministic — same inputs always
produce the same verdict).  Deployments without oracles supply
`oracleAlwaysRejects` (every oracle dispute is `rejected`); a
deployment with a single time-feed oracle might supply a verifier
that consults a hash-committed external feed. -/

/-- Deployment-supplied per-oracle evidence verifier.  Consumed by
    `checkEvidence` for the `oracleMisreported` claim variant. -/
structure OraclePolicy where
  /-- Given the impugned log index and the dispute's evidence
      bytes, return the evidence verdict.  Deterministic: equal
      inputs always produce equal outputs. -/
  verifier : LogIndex → ByteArray → EvidenceVerdict

/-- The default oracle policy: every oracle dispute is `rejected`.
    Acts as a safe default for deployments that do receive
    `oracleMisreported` claims but have no actual oracle to
    consult — every such claim is dismissed.  Also serves as a
    test fixture for the `checkEvidence` test suite. -/
def OraclePolicy.alwaysRejects : OraclePolicy where
  verifier _ _ := .rejected

/-- A degenerate oracle policy: every oracle dispute is `upheld`.
    Used to exercise the `oracleMisreported` upheld code path in
    tests. -/
def OraclePolicy.alwaysUpheld : OraclePolicy where
  verifier _ _ := .upheld

/-! ## Filing-error vocabulary (§8.4.4)

The ways `fileDispute` can reject a dispute submission.  Each
variant maps to a Genesis-Plan §8.4.4 row:

  * `malformedAction` — the dispute is not wrapped in
    `Action.dispute` (deployment-level type mismatch; reserved
    for callers that extract a `Dispute` from a `SignedAction`
    and want a uniform error path).  **Note**: the in-tree
    `fileDispute` takes `d : Dispute` directly rather than a
    `SignedAction`, so it does NOT return this variant — the
    caller is responsible for the type extraction.  The variant
    is exposed for deployment-level wrappers that combine
    extraction + filing.
  * `unknownChallenger` — the challenger is not registered.
  * `indexOutOfRange` — the named `LogIndex` exceeds `log.length`.
  * `duplicateDispute` — the same `(challenger, claim)` pair has
    already been filed at an earlier index, **regardless of the
    prior dispute's current status** (open / withdrawn /
    decided).  This is a deliberate design choice: deployments
    that want to allow re-filing of withdrawn disputes can
    inspect the prior dispute's status via `disputeStatus` and
    construct a fresh `Dispute` with a different claim payload
    (e.g. by mutating the `evidence` field for an
    `oracleMisreported` claim). -/

/-- Errors that `fileDispute` can produce.  Each variant maps to a
    §8.4.4 failure case. -/
inductive FilingError
  /-- The supplied `SignedAction`'s action is not `Action.dispute _`.
      Reserved for deployment-level wrappers; the in-tree
      `fileDispute` does not return this variant (it takes
      `d : Dispute` directly). -/
  | malformedAction
  /-- The challenger is not registered in the runtime's key
      registry. -/
  | unknownChallenger
  /-- The dispute claim names a log index that exceeds the log's
      length. -/
  | indexOutOfRange (idx : LogIndex) (logLen : Nat)
  /-- A prior dispute with the same `(challenger, claim)` pair has
      already been filed at index `priorIdx`.  Status-blind: a
      withdrawn or decided prior dispute still triggers this
      error. -/
  | duplicateDispute (priorIdx : LogIndex)
  deriving Repr, DecidableEq

/-! ## Verdict-error vocabulary

`VerdictError` is the unified error vocabulary for **both**
`proposeVerdict` (Stage 3) and `applyVerdict` (Stage 4).

Errors **`proposeVerdict`** can return:

  * `unknownDispute` — `disputeId` does not point at an
    `Action.dispute` log entry.
  * `alreadyDecided` — the dispute has already been closed by a
    prior verdict or withdraw.
  * `outcomeMismatch` — the verdict's recorded `outcome` disagrees
    with the deterministic re-evaluation of the dispute's
    evidence (the verdict is forged or the inputs have changed
    since signing).
  * `quorumNotMet` — fewer than `quorum` signatures verify under
    the listed signers' registered keys.

Errors **`applyVerdict`** can return:

  * `unknownDispute` — same as above.
  * `alreadyDecided` — same as above.
  * `replayFailed` — replay of `log[0..idx-1]` (used to compute
    the rollback target) failed.  Indicates either a corrupt log
    or a kernel runtime bug; should be impossible if Stage 1
    enforced the in-range check on the impugned index.

`applyVerdict` does NOT return `outcomeMismatch` or `quorumNotMet`
— it accepts a "validated" verdict (one that already passed
Stage 3 checks).  Deployments that bypass Stage 3 must apply
their own verifier discipline; calling `applyVerdict` on an
unvalidated verdict will faithfully apply whatever outcome the
verdict claims.  See the `applyVerdict` docstring in
`Disputes/Verdict.lean` for the runtime-contract details. -/

/-- Errors that the verdict pipeline (`proposeVerdict` /
    `applyVerdict`) can produce. -/
inductive VerdictError
  /-- The `disputeId` does not reference a log entry whose action
      is `Action.dispute _`. -/
  | unknownDispute (idx : LogIndex)
  /-- Fewer than the required quorum of signers' signatures
      verified.  `verified` reports the count actually accepted. -/
  | quorumNotMet (verified required : Nat)
  /-- The verdict's `outcome` disagrees with the deterministic
      re-evaluation of the dispute's evidence. -/
  | outcomeMismatch
  /-- The dispute has already been closed (by a prior verdict or
      withdraw). -/
  | alreadyDecided
  /-- Replay of the pre-impugned-action log prefix failed. -/
  | replayFailed
  deriving Repr

end Disputes
end LegalKernel

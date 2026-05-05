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

Phase 6 WU 6.9 + WU 6.10, with the Phase-6 Option-C amendment
adding the `VerdictPassedStage3` propositional witness for
type-safe Stage-4 invocation.

This module exposes **three** entry points for verdict
application, each with a different security/ergonomics tradeoff:

  1. **`proposeAndApplyVerdict` (DEFAULT-SAFE)** — combined Stage 3
     + Stage 4 atomically.  Internally validates via
     `proposeVerdict` and then applies via `applyVerdict`
     (witness-bearing).  Use this unless you have a specific reason
     not to.

  2. **`applyVerdict` (WITNESS-BEARING)** — for callers that have
     already validated the verdict and want to skip the
     re-validation overhead.  Carries a propositional
     `VerdictPassedStage3` argument that proves Stage 3 passed.
     Type-safe: cannot be called without the witness.

  3. **`applyVerdictUnchecked` (BYPASS — TESTING ONLY)** — applies
     the rollback semantics WITHOUT Stage 3 validation.  A
     malicious caller invoking this with a forged verdict gets
     the rollback fired without quorum-signature validation.
     Exposed for tests that intentionally exercise bypass
     semantics (e.g. `unknownDispute` error paths where the
     witness can't be constructed).  Production deployments MUST
     NOT use this form.

The module also exports:

  * **`QuorumPolicy`** — the deployment-supplied quorum threshold
    + list of approved adjudicators.
  * **`countVerifiedSignatures`** — count how many of the
    verdict's `(signer, sig)` pairs verify under their registered
    keys.
  * **`proposeVerdict`** (Stage 3, WU 6.9) — validate a verdict's
    quorum + outcome consistency.  Returns the verdict on success
    or a `VerdictError`.
  * **`proposeVerdict_ok_returns_input`** — bridge lemma stating
    that successful `proposeVerdict` calls preserve the input
    verdict (every `.ok v'` return implies `v' = v`).  Used by
    `proposeAndApplyVerdict` to construct the witness.
  * **`VerdictPassedStage3`** — propositional witness type.
    Single-field structure carrying the equation
    `proposeVerdict ... = .ok v`.  Constructed via
    `of_proposeVerdict_ok` (literal) or
    `of_proposeVerdict_ok_with_eq` (with the input-output
    equality bridge).
  * **Three witness-extraction theorems** — `applyVerdict_log_in_range`,
    `_entry_is_dispute`, `_dispute_open` derive the per-branch
    facts of `proposeVerdict`'s match tree from the witness.
    Used internally by `applyVerdict_under_witness_succeeds` and
    available to deployments that need them.
  * **`applyVerdict_under_witness_succeeds`** — strong-correctness
    theorem: the witness-bearing `applyVerdict` is provably
    total.  Every error path (`unknownDispute`, `alreadyDecided`,
    `replayFailed`) is mechanically unreachable.  Layer-0's
    defensive `checkOracleMisreported` index check is the
    load-bearing precondition.
  * **Three unreachable-error theorems** —
    `_unknownDispute_unreachable`, `_alreadyDecided_unreachable`,
    `_replayFailed_unreachable` document the strong-correctness
    guarantee per error variant for local auditing at callsites.
  * **Status pre-check** — `applyVerdictUnchecked` rejects with
    `alreadyDecided` if the dispute has already been closed by
    a prior verdict or withdraw.

The headline takeaway: an upheld verdict whose dispute targets
log entry `idx` produces a *forward action*
(`Action.rollback idx_target`) whose effect is "set state to the
replay of `log[0..idx_target-1]` from genesis".  The runtime
layer wires the rollback in by appending the `Action.rollback`
to the log and using the recomputed `ExtendedState` as the new
runtime state.

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
pairs and increments a counter for each *distinct* signer `a` such
that:

  1. `a` is in the policy's `approvedAdjudicators` list,
  2. `a` is registered in the runtime's key registry, and
  3. `Verify pk msg sig` returns `true` for the verdict's canonical
     encoding under `a`'s registered key (where `sig` is `a`'s
     first paired signature in `v.sigs`).

The function is total: missing signatures, unregistered signers, or
mismatched signature lengths simply produce a count that does not
clear the quorum threshold.

**Per-signer deduplication (security-critical).**  Each distinct
signer can contribute *at most one* to the count, regardless of
how many times the `(signer, sig)` pair appears in `v.signers /
v.sigs`.  Without this safeguard, a single approved adjudicator
with one valid signature could meet any quorum threshold simply
by repeating themselves N times in the lists — a trivial quorum
forgery.  The first occurrence of a signer takes precedence; any
subsequent duplicate (whether the signature verifies or not) is
silently discarded. -/

/-- The bytes that adjudicators sign when proposing a verdict.

    Layout (concatenation of CBE encodings):

      * `Encodable.encode v.disputeId` — the impugned dispute log
        index, as a CBE unsigned integer.
      * `Encodable.encode v.outcome` — the verdict outcome
        constructor (`upheld` / `rejected` / `inconclusive`).
      * `Encodable.encode v.rationale` — the optional human-readable
        rationale bytes.

    Note that the `signers` and `sigs` fields are deliberately NOT
    included: those are the witnesses we're trying to verify, and
    including them in the signed bytes would create a circular
    dependency (each adjudicator's signature would need to predict
    every other adjudicator's signature).  All adjudicators
    therefore sign the same `(disputeId, outcome, rationale)`
    payload, and their individual signatures accumulate in the
    `signers` / `sigs` lists.

    The encoding is content-distinguishing (distinct payloads
    produce distinct bytes by `Encodable` round-trip injectivity),
    so a signature on one verdict cannot be reused on a different
    `(disputeId, outcome, rationale)` payload.  Cross-deployment
    replay protection is provided at the runtime adaptor layer
    (deployment-scoped `Verify` keyring); a follow-up enhancement
    can prepend a `"legalkernel/v1/verdict"` domain string and the
    deployment-id once `proposeVerdict` carries the deploymentId. -/
def verdictSigningInput (v : Verdict) : ByteArray :=
  ByteArray.mk
    (Encoding.Encodable.encode (T := Nat) v.disputeId ++
     Encoding.Encodable.encode (T := EvidenceVerdict) v.outcome ++
     Encoding.Encodable.encode (T := ByteArray) v.rationale).toArray

/-- Count the *distinct* signers in a verdict whose signature
    verifies under their registered key AND who appear on the
    approved-adjudicator list.

    Walks the parallel `signers` and `sigs` lists, deduplicating
    by signer (the *first* `(signer, sig)` pair per signer wins;
    later duplicates are silently ignored).  This per-signer
    deduplication prevents a malicious adjudicator from inflating
    the count by submitting N copies of their `(signer, sig)`
    pair — see the section docstring for the security
    rationale. -/
def countVerifiedSignatures
    (qp : QuorumPolicy) (currentEs : ExtendedState) (v : Verdict) : Nat :=
  let msg := verdictSigningInput v
  let pairs : List (ActorId × Signature) := List.zip v.signers v.sigs
  -- Walk pairs once, threading both the running count and the list
  -- of signers already accounted for.  Each signer is counted at
  -- most once (the first time we see them in the list).  We mark
  -- a signer "seen" the first time we encounter it regardless of
  -- whether its signature verified, so a malformed first signature
  -- forfeits that signer's quorum slot rather than letting later
  -- duplicates retry.
  (pairs.foldl (fun (acc : Nat × List ActorId) (p : ActorId × Signature) =>
    let count := acc.fst
    let seen  := acc.snd
    let a     := p.fst
    let s     := p.snd
    if decide (a ∈ seen) then
      (count, seen)
    else if decide (a ∈ qp.approvedAdjudicators) then
      match currentEs.registry[a]? with
      | some pk =>
        if Verify pk msg s = true then
          (count + 1, a :: seen)
        else
          (count, a :: seen)
      | none => (count, a :: seen)
    else
      (count, a :: seen)) (0, [])).fst

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

/-! ## proposeVerdict input-preservation (bridge lemma, C.1)

`proposeVerdict` either returns an error or returns `.ok v` (the
input).  The only `.ok` branch in the function returns the
verdict that was passed in, verbatim.  This lemma is the bridge
that lets `proposeAndApplyVerdict` (Layer 2) construct a
`VerdictPassedStage3` witness from the success branch of a
`match h : proposeVerdict ... with | .ok v' => …` pattern: the
witness type's parameter is the *input* `v`, but the pattern
binds `v'`; this lemma collapses the difference. -/

/-- `proposeVerdict` is input-preserving on success: every
    `.ok v'` return implies `v' = v` (the input).  Proven by
    walking `proposeVerdict`'s match tree (5 error branches +
    1 success branch). -/
theorem proposeVerdict_ok_returns_input
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry)
    (v v' : Verdict)
    (h : proposeVerdict P oracle qp currentEs genesis log v = .ok v') :
    v' = v := by
  unfold proposeVerdict at h
  split at h
  · -- log[disputeId]? = none → .error (.unknownDispute …)
    exact absurd h (by simp)
  · split at h
    · -- entry.signedAction.action = .dispute d
      split at h
      · -- disputeStatus = some .open
        -- The body now reads:
        --   let drec := …; let recomputed := …;
        --   if recomputed ≠ v.outcome then .error .outcomeMismatch
        --   else (let verified := …;
        --         if verified < qp.required then .error … else .ok v)
        -- `split at h` can't dive through the `let`s; `dsimp only at h`
        -- beta-reduces them so the inner `if` becomes top-level.
        dsimp only at h
        split at h
        · -- recomputed ≠ outcome → .error .outcomeMismatch
          exact absurd h (by simp)
        · -- recomputed = outcome
          split at h
          · -- verified < required → .error .quorumNotMet
            exact absurd h (by simp)
          · -- success: h : .ok v = .ok v'
            exact (Except.ok.inj h).symm
      · -- disputeStatus ≠ some .open → .error .alreadyDecided
        exact absurd h (by simp)
    · -- non-dispute action → .error (.unknownDispute …)
      exact absurd h (by simp)

/-! ## VerdictPassedStage3 — propositional witness (C.2)

The kernel-layer's `Admissible` carries a dependent witness that
makes the type system mechanically prevent calling
`apply_admissible` without proof of admissibility.  The dispute
layer's Stage 4 (`applyVerdict`) previously had no such witness —
the "Stage 3 was called first" contract was enforced by
documentation only.

`VerdictPassedStage3` is the dispute-layer counterpart: a single-
field `Prop` structure whose only field is the equation
`proposeVerdict P oracle qp currentEs genesis log v = .ok v`.
Constructed from a successful Stage 3 call (directly via
`of_proposeVerdict_ok`, or via the `_with_eq` form that handles
the `proposeVerdict ... = .ok v'` pattern with an
input-preserving step from `proposeVerdict_ok_returns_input`).

The witness is propositional, hence proof-irrelevant — it has
zero runtime cost.  Lean's compiler erases the witness argument
of `applyVerdict` at code-gen time. -/

/-- Propositional witness that `proposeVerdict` accepted `v`.
    Carries the success equation as its only field.

    Use `VerdictPassedStage3.of_proposeVerdict_ok` to build the
    witness from a literal `proposeVerdict ... v = .ok v`
    success, or `of_proposeVerdict_ok_with_eq` to bridge the
    `proposeVerdict ... v = .ok v'` form via the input-
    preservation lemma. -/
structure VerdictPassedStage3
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) : Prop where
  /-- The success equation: Stage 3 accepted this verdict against
      the named state, log, and policies.  Carries enough
      information to reconstruct (via three extraction theorems
      in Layer 1's C.4d) that the log entry exists, is a
      dispute, the dispute is open, and the outcome matches
      `checkEvidence`'s recomputation. -/
  proposed : proposeVerdict P oracle qp currentEs genesis log v = .ok v

/-- Construct the witness from a successful `proposeVerdict`
    call where the input and output verdicts are *literally*
    equal.  This is the simplest constructor: every test fixture
    that builds the witness via `decide` ends up here. -/
theorem VerdictPassedStage3.of_proposeVerdict_ok
    {P : AuthorityPolicy} {oracle : OraclePolicy} {qp : QuorumPolicy}
    {currentEs genesis : ExtendedState} {log : List LogEntry}
    {v : Verdict}
    (h : proposeVerdict P oracle qp currentEs genesis log v = .ok v) :
    VerdictPassedStage3 P oracle qp currentEs genesis log v := ⟨h⟩

/-- Construct the witness from a `proposeVerdict` call whose
    output verdict differs from the input by name only (the
    input-output equality is provided by
    `proposeVerdict_ok_returns_input`).  Used by
    `proposeAndApplyVerdict` (Layer 2) to bridge the
    `match h_propose : proposeVerdict ... with | .ok v' => …`
    pattern-binding form. -/
theorem VerdictPassedStage3.of_proposeVerdict_ok_with_eq
    {P : AuthorityPolicy} {oracle : OraclePolicy} {qp : QuorumPolicy}
    {currentEs genesis : ExtendedState} {log : List LogEntry}
    {v v' : Verdict}
    (h : proposeVerdict P oracle qp currentEs genesis log v = .ok v')
    (h_eq : v' = v) :
    VerdictPassedStage3 P oracle qp currentEs genesis log v := by
  rw [h_eq] at h
  exact ⟨h⟩

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

/-- **UNCHECKED — bypasses Stage 3.**  This function applies the
    verdict's rollback semantics WITHOUT validating that the
    verdict was approved by `proposeVerdict` (Stage 3).  A
    malicious caller invoking this with a forged `.upheld`
    verdict gets the rollback fired without quorum-signature
    validation.

    For the type-safe entry point that requires Stage 3 validation
    via a `VerdictPassedStage3` proof witness, use `applyVerdict`.
    For the default-safe combined entry point, use
    `proposeAndApplyVerdict`.

    This function is exposed for:
      1. Tests that intentionally exercise bypass semantics
         (e.g. `unknownDispute` error-path tests where the
         witness can't be constructed because the dispute
         doesn't exist).
      2. Deployments with deployment-supplied pre-validation
         that want to skip the witness-construction overhead.

    For `upheld` verdicts, computes the rollback target via
    prefix replay; for `rejected` / `inconclusive` verdicts,
    returns the current state unchanged.

    Production runtimes MUST NOT call this function directly
    on an externally-supplied verdict.  Use
    `proposeAndApplyVerdict` (default-safe) or `applyVerdict`
    (witness-bearing). -/
def applyVerdictUnchecked
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

/-- `applyVerdictUnchecked` with a `rejected` outcome leaves the
    state unchanged (provided the dispute is open and the
    disputeId references a valid dispute entry). -/
theorem applyVerdictUnchecked_rejected_no_change
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d)
    (h_open : disputeStatus log v.disputeId = some .open)
    (h_rej : v.outcome = .rejected) :
    applyVerdictUnchecked P currentEs genesis log v = .ok currentEs := by
  unfold applyVerdictUnchecked
  rw [h_idx]
  dsimp only
  rw [h_act]
  dsimp only
  rw [h_open]
  dsimp only
  rw [h_rej]

/-- `applyVerdictUnchecked` with an `inconclusive` outcome leaves
    the state unchanged. -/
theorem applyVerdictUnchecked_inconclusive_no_change
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d)
    (h_open : disputeStatus log v.disputeId = some .open)
    (h_inc : v.outcome = .inconclusive) :
    applyVerdictUnchecked P currentEs genesis log v = .ok currentEs := by
  unfold applyVerdictUnchecked
  rw [h_idx]
  dsimp only
  rw [h_act]
  dsimp only
  rw [h_open]
  dsimp only
  rw [h_inc]

/-- `applyVerdictUnchecked` rejects a verdict against an unknown
    dispute. -/
theorem applyVerdictUnchecked_unknown_dispute
    (P : AuthorityPolicy) (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (h : log[v.disputeId]? = none) :
    applyVerdictUnchecked P currentEs genesis log v =
    .error (.unknownDispute v.disputeId) := by
  unfold applyVerdictUnchecked
  rw [h]

/-- `applyVerdictUnchecked` is deterministic. -/
theorem applyVerdictUnchecked_deterministic
    (P : AuthorityPolicy) (currentEs₁ currentEs₂ : ExtendedState)
    (genesis₁ genesis₂ : ExtendedState) (log₁ log₂ : List LogEntry) (v₁ v₂ : Verdict)
    (h_es : currentEs₁ = currentEs₂) (h_g : genesis₁ = genesis₂)
    (h_l : log₁ = log₂) (h_v : v₁ = v₂) :
    applyVerdictUnchecked P currentEs₁ genesis₁ log₁ v₁ =
    applyVerdictUnchecked P currentEs₂ genesis₂ log₂ v₂ := by
  rw [h_es, h_g, h_l, h_v]

/-! ## Witness-bearing applyVerdict (C.4)

The type-safe Stage 4 entry point.  Carries a propositional
`VerdictPassedStage3` argument that ensures the verdict was
validated by Stage 3 before rollback semantics fire.  Type-safe
by construction: cannot be called without the witness.

The witness is a `Prop`, hence proof-irrelevant — the witness
argument is erased at compile time.  This function compiles to
exactly the same code as `applyVerdictUnchecked`.

The witness is the cryptographic safety net: an auditor reading
`applyVerdict P oracle qp es gen log v _h` knows that some valid
proof of `proposeVerdict ... = .ok v` exists.  This is the
dispute-layer counterpart of the kernel's
`apply_admissible P es st h`. -/

/-- Stage 4 of the dispute pipeline (witness-bearing).  Carries
    a propositional `VerdictPassedStage3` proof argument that
    ensures the verdict was validated by Stage 3.  Cannot be
    called without the witness — auditors verify
    bypass-resistance locally at each callsite.

    The witness is propositional and erased at runtime; this
    function compiles to exactly the same code as
    `applyVerdictUnchecked`. -/
def applyVerdict
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (_h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    Except VerdictError ExtendedState :=
  applyVerdictUnchecked P currentEs genesis log v

/-- Trivial-equivalence theorem.  `applyVerdict` and
    `applyVerdictUnchecked` produce identical outputs on the same
    inputs (the witness adds nothing at the value level).  Used
    by every per-outcome theorem to reduce a witness-bearing
    claim to its `_Unchecked` counterpart. -/
theorem applyVerdict_eq_unchecked
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdict P oracle qp currentEs genesis log v h =
    applyVerdictUnchecked P currentEs genesis log v := rfl

/-! ## Per-outcome theorems for witness-bearing applyVerdict (C.4c)

These are the witness-bearing analogues of the four `_Unchecked`
theorems.  Each is proved by `rfl`-reducing through
`applyVerdict_eq_unchecked` and delegating to the matching
`_Unchecked` theorem. -/

/-- Witness-bearing `applyVerdict` with a `.rejected` outcome
    leaves the state unchanged. -/
theorem applyVerdict_rejected_no_change
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d)
    (h_open : disputeStatus log v.disputeId = some .open)
    (h_rej : v.outcome = .rejected)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdict P oracle qp currentEs genesis log v h = .ok currentEs := by
  rw [applyVerdict_eq_unchecked]
  exact applyVerdictUnchecked_rejected_no_change P currentEs genesis log v
                                                  entry d h_idx h_act h_open h_rej

/-- Witness-bearing `applyVerdict` with an `.inconclusive`
    outcome leaves the state unchanged. -/
theorem applyVerdict_inconclusive_no_change
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d)
    (h_open : disputeStatus log v.disputeId = some .open)
    (h_inc : v.outcome = .inconclusive)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdict P oracle qp currentEs genesis log v h = .ok currentEs := by
  rw [applyVerdict_eq_unchecked]
  exact applyVerdictUnchecked_inconclusive_no_change P currentEs genesis log v
                                                      entry d h_idx h_act h_open h_inc

/-- Witness-bearing `applyVerdict` is deterministic. -/
theorem applyVerdict_deterministic
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs₁ currentEs₂ : ExtendedState)
    (genesis₁ genesis₂ : ExtendedState) (log₁ log₂ : List LogEntry)
    (v₁ v₂ : Verdict)
    (h₁ : VerdictPassedStage3 P oracle qp currentEs₁ genesis₁ log₁ v₁)
    (h₂ : VerdictPassedStage3 P oracle qp currentEs₂ genesis₂ log₂ v₂)
    (h_es : currentEs₁ = currentEs₂) (h_g : genesis₁ = genesis₂)
    (h_l : log₁ = log₂) (h_v : v₁ = v₂) :
    applyVerdict P oracle qp currentEs₁ genesis₁ log₁ v₁ h₁ =
    applyVerdict P oracle qp currentEs₂ genesis₂ log₂ v₂ h₂ := by
  rw [applyVerdict_eq_unchecked, applyVerdict_eq_unchecked]
  exact applyVerdictUnchecked_deterministic P currentEs₁ currentEs₂
                                             genesis₁ genesis₂ log₁ log₂
                                             v₁ v₂ h_es h_g h_l h_v

/-! ## Witness-extraction theorems (C.4d)

The witness `VerdictPassedStage3 P oracle qp currentEs genesis
log v` carries the equation `proposeVerdict ... v = .ok v`.
By walking `proposeVerdict`'s match tree, we can extract three
side facts about the call:

  1. `log[v.disputeId]? = some entry` for some `entry`.
  2. The entry's action is `.dispute d` for some `d`.
  3. The dispute is currently `.open`.

These facts are what `applyVerdict_under_witness_succeeds` (C.4e)
uses to discharge the non-upheld branches of
`applyVerdictUnchecked`'s match tree mechanically. -/

/-- Witness extraction: the log entry at `v.disputeId` exists. -/
theorem applyVerdict_log_in_range
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    ∃ entry, log[v.disputeId]? = some entry := by
  have h_propose := h.proposed
  unfold proposeVerdict at h_propose
  split at h_propose
  · -- log[v.disputeId]? = none → .error, contradicts h_propose : .ok v
    exact absurd h_propose (by simp)
  · rename_i entry h_eq
    exact ⟨entry, h_eq⟩

/-- Witness extraction: the log entry's action is a `.dispute _`. -/
theorem applyVerdict_entry_is_dispute
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (entry : LogEntry)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v)
    (h_idx : log[v.disputeId]? = some entry) :
    ∃ d, entry.signedAction.action = .dispute d := by
  have h_propose := h.proposed
  unfold proposeVerdict at h_propose
  -- `simp only [h_idx]` rewrites + iota-reduces the outer match.
  simp only [h_idx] at h_propose
  -- h_propose : (match entry.signedAction.action with | .dispute d => …
  --              | _ => .error (.unknownDispute v.disputeId)) = .ok v
  split at h_propose
  · -- .dispute d branch: rename pattern var + equation.
    rename_i d h_act
    exact ⟨d, h_act⟩
  all_goals exact absurd h_propose (by simp)

/-! ## Helper lemma: in-range bound on the impugned index (C.4e4)

When `checkEvidence` returns `.upheld`, the impugned index
(extracted from the dispute claim) must be in range.  Each of
the five claim variants has its own reasoning:

  * `preconditionFalse`/`signatureInvalid`/`nonceMismatch`: each
    verifier returns `.inconclusive` if `log[idx]? = none`, so
    `.upheld` implies the impugned entry exists.
  * `oracleMisreported`: Layer 0's defensive check
    (`checkOracleMisreported_inconclusive_on_out_of_range`)
    closes this gap.
  * `doubleApply`: `.upheld` requires both indices to lookup, so
    in particular the primary index is in range. -/

/-- Helper: `log[idx]? = some _` implies `idx < log.length`. -/
theorem List_idx_lt_of_getElem?_some
    {α : Type _} (l : List α) (idx : Nat) (a : α)
    (h : l[idx]? = some a) : idx < l.length :=
  (List.getElem?_eq_some_iff.mp h).1

/-- When `checkEvidence` returns `.upheld`, the impugned index of
    the dispute's claim is `< log.length`.  Load-bearing for
    `applyVerdict_under_witness_succeeds`: the in-range bound
    ensures `replayPrefix` succeeds at the prefix-replay step. -/
theorem claimImpugnedIdx_in_range_when_upheld
    (P : AuthorityPolicy) (oracle : OraclePolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry)
    (rec : DisputeRecord)
    (h : checkEvidence P oracle currentEs genesis log rec = .upheld) :
    claimImpugnedIdx rec.dispute.claim < log.length := by
  -- Case-split on the claim variant; in each case, unfold both
  -- `checkEvidence` and `claimImpugnedIdx` simultaneously via `simp only`.
  cases h_claim : rec.dispute.claim with
  | preconditionFalse idx =>
    -- claimImpugnedIdx reduces to idx.
    simp only [h_claim, checkEvidence, claimImpugnedIdx] at h ⊢
    -- h : checkPreconditionFalse P genesis log idx = .upheld
    -- Goal: idx < log.length
    unfold checkPreconditionFalse at h
    cases h_lookup : log[idx]? with
    | none =>
      rw [h_lookup] at h
      exact absurd h (by simp)
    | some entry =>
      exact List_idx_lt_of_getElem?_some log idx entry h_lookup
  | signatureInvalid idx =>
    simp only [h_claim, checkEvidence, claimImpugnedIdx] at h ⊢
    unfold checkSignatureInvalid at h
    cases h_lookup : log[idx]? with
    | none =>
      rw [h_lookup] at h
      exact absurd h (by simp)
    | some entry =>
      exact List_idx_lt_of_getElem?_some log idx entry h_lookup
  | nonceMismatch idx =>
    simp only [h_claim, checkEvidence, claimImpugnedIdx] at h ⊢
    unfold checkNonceMismatch at h
    cases h_lookup : log[idx]? with
    | none =>
      rw [h_lookup] at h
      exact absurd h (by simp)
    | some entry =>
      exact List_idx_lt_of_getElem?_some log idx entry h_lookup
  | oracleMisreported idx ev =>
    simp only [h_claim, checkEvidence, claimImpugnedIdx] at h ⊢
    -- C.0's defensive check: checkOracleMisreported returns .inconclusive
    -- when log[idx]? = none.
    unfold checkOracleMisreported at h
    cases h_lookup : log[idx]? with
    | none =>
      rw [h_lookup] at h
      exact absurd h (by simp)
    | some entry =>
      exact List_idx_lt_of_getElem?_some log idx entry h_lookup
  | doubleApply idx₁ idx₂ =>
    simp only [h_claim, checkEvidence, claimImpugnedIdx] at h ⊢
    unfold checkDoubleApply at h
    -- h : (if idx₁ = idx₂ then .rejected else
    --       match log[idx₁]?, log[idx₂]? with …) = .upheld
    by_cases h_eq : idx₁ = idx₂
    · rw [if_pos h_eq] at h
      exact absurd h (by simp)
    · rw [if_neg h_eq] at h
      cases h_l1 : log[idx₁]? with
      | none =>
        rw [h_l1] at h
        cases h_l2 : log[idx₂]? with
        | none => rw [h_l2] at h; exact absurd h (by simp)
        | some e₂ => rw [h_l2] at h; exact absurd h (by simp)
      | some e₁ =>
        exact List_idx_lt_of_getElem?_some log idx₁ e₁ h_l1

/-- Witness extraction: the dispute is currently `.open`. -/
theorem applyVerdict_dispute_open
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    disputeStatus log v.disputeId = some .open := by
  have h_propose := h.proposed
  obtain ⟨entry, h_idx⟩ :=
    applyVerdict_log_in_range P oracle qp currentEs genesis log v h
  obtain ⟨d, h_act⟩ :=
    applyVerdict_entry_is_dispute P oracle qp currentEs genesis log v entry h h_idx
  unfold proposeVerdict at h_propose
  simp only [h_idx, h_act] at h_propose
  -- h_propose : (match disputeStatus log v.disputeId with
  --   | some .open => … | _ => .error .alreadyDecided) = .ok v
  split at h_propose
  · -- some .open branch — `split` brings `heq : disputeStatus … = some .open`.
    rename_i h_status
    exact h_status
  · -- non-open catch-all — h_propose is `.error _ = .ok v`, contradiction.
    exact absurd h_propose (by simp)

/-! ## Outcome-match extraction (helper for C.4e)

When the witness holds, `checkEvidence`'s recomputation matches
the verdict's outcome.  Used by `applyVerdict_under_witness_succeeds`
to discharge the `.upheld` branch (where we need the recomputation
to be `.upheld` so the in-range bound from
`claimImpugnedIdx_in_range_when_upheld` fires). -/

/-- The witness implies `checkEvidence`'s recomputed outcome
    matches the verdict's outcome. -/
theorem applyVerdict_outcome_matches
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (entry : LogEntry) (d : Dispute)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v)
    (h_idx : log[v.disputeId]? = some entry)
    (h_act : entry.signedAction.action = .dispute d) :
    checkEvidence P oracle currentEs genesis log
        { dispute := d, idx := v.disputeId, status := .open } = v.outcome := by
  have h_propose := h.proposed
  have h_open := applyVerdict_dispute_open P oracle qp currentEs genesis log v h
  unfold proposeVerdict at h_propose
  simp only [h_idx, h_act, h_open] at h_propose
  -- h_propose : (if recomputed ≠ v.outcome then .error _ else
  --               if verified < required then .error _ else .ok v) = .ok v
  -- Split on the outer `if`.
  split at h_propose
  · -- recomputed ≠ v.outcome → .error .outcomeMismatch = .ok v, contradiction.
    exact absurd h_propose (by simp)
  · -- recomputed = v.outcome.  The hypothesis `rename_i` brings in is
    -- `¬(recomputed ≠ v.outcome) = ¬¬(recomputed = v.outcome)`.
    rename_i h_neg
    exact Decidable.of_not_not h_neg

/-! ## Strong correctness: applyVerdict is total under witness (C.4e)

The headline theorem of Layer 1: with a `VerdictPassedStage3`
witness, `applyVerdict` is **provably total** — every error path
(`unknownDispute` / `alreadyDecided` / `replayFailed`) is
mechanically unreachable.

The proof composes:
  * Three witness-extraction theorems (C.4d) to discharge
    `unknownDispute` and `alreadyDecided`.
  * The outcome-match helper (above) and the in-range helper
    (`claimImpugnedIdx_in_range_when_upheld`) to discharge
    `replayFailed` for the `.upheld` branch. -/

/-- **Strong correctness.** `applyVerdict` always returns `.ok`
    under a witness — every error path is unreachable.  The
    three `_unreachable` theorems below derive specific
    unreachability statements per error variant from this. -/
theorem applyVerdict_under_witness_succeeds
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    ∃ es, applyVerdict P oracle qp currentEs genesis log v h = .ok es := by
  -- Reduce to applyVerdictUnchecked.
  rw [applyVerdict_eq_unchecked]
  -- Extract the witness's facts.
  obtain ⟨entry, h_idx⟩ :=
    applyVerdict_log_in_range P oracle qp currentEs genesis log v h
  obtain ⟨d, h_act⟩ :=
    applyVerdict_entry_is_dispute P oracle qp currentEs genesis log v entry h h_idx
  have h_open := applyVerdict_dispute_open P oracle qp currentEs genesis log v h
  -- Walk applyVerdictUnchecked's match tree.
  unfold applyVerdictUnchecked
  simp only [h_idx, h_act, h_open]
  -- Goal: ∃ es, (match v.outcome with
  --              | .upheld => let i := claimImpugnedIdx d.claim;
  --                           match replayPrefix … i with
  --                           | none => .error .replayFailed
  --                           | some r => .ok r
  --              | _ => .ok currentEs) = .ok es
  cases h_outcome : v.outcome with
  | rejected => exact ⟨currentEs, rfl⟩
  | inconclusive => exact ⟨currentEs, rfl⟩
  | upheld =>
    -- Need: replayPrefix P genesis log (claimImpugnedIdx d.claim) = some _.
    have h_match :
        checkEvidence P oracle currentEs genesis log
          { dispute := d, idx := v.disputeId, status := .open } = .upheld := by
      have := applyVerdict_outcome_matches P oracle qp currentEs genesis log v
                entry d h h_idx h_act
      rw [this, h_outcome]
    -- Use the helper to bound claimImpugnedIdx d.claim < log.length.
    have h_in_range :
        claimImpugnedIdx d.claim < log.length := by
      have := claimImpugnedIdx_in_range_when_upheld P oracle currentEs genesis log
                { dispute := d, idx := v.disputeId, status := .open } h_match
      simpa using this
    -- replayPrefix succeeds when idx ≤ log.length.
    have h_le : claimImpugnedIdx d.claim ≤ log.length := Nat.le_of_lt h_in_range
    have h_replay :
        replayPrefix P genesis log (claimImpugnedIdx d.claim) =
          some (kernelOnlyReplay genesis (log.take (claimImpugnedIdx d.claim))) := by
      unfold replayPrefix
      rw [if_neg (Nat.not_lt.mpr h_le)]
    rw [h_replay]
    exact ⟨_, rfl⟩

/-! ## Unreachable-error theorems (C.4f)

Each error variant of `applyVerdict` is mechanically unreachable
under the witness.  These three theorems give auditors a local
check at every callsite: a witness-bearing `applyVerdict` cannot
return any of these errors, period. -/

/-- Witness-bearing `applyVerdict` cannot return `.unknownDispute`. -/
theorem applyVerdict_unknownDispute_unreachable
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdict P oracle qp currentEs genesis log v h ≠
      .error (.unknownDispute v.disputeId) := by
  intro h_eq
  obtain ⟨_es, h_ok⟩ :=
    applyVerdict_under_witness_succeeds P oracle qp currentEs genesis log v h
  rw [h_ok] at h_eq
  exact absurd h_eq (by simp)

/-- Witness-bearing `applyVerdict` cannot return `.alreadyDecided`. -/
theorem applyVerdict_alreadyDecided_unreachable
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdict P oracle qp currentEs genesis log v h ≠ .error .alreadyDecided := by
  intro h_eq
  obtain ⟨_es, h_ok⟩ :=
    applyVerdict_under_witness_succeeds P oracle qp currentEs genesis log v h
  rw [h_ok] at h_eq
  exact absurd h_eq (by simp)

/-- Witness-bearing `applyVerdict` cannot return `.replayFailed`. -/
theorem applyVerdict_replayFailed_unreachable
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : VerdictPassedStage3 P oracle qp currentEs genesis log v) :
    applyVerdict P oracle qp currentEs genesis log v h ≠ .error .replayFailed := by
  intro h_eq
  obtain ⟨_es, h_ok⟩ :=
    applyVerdict_under_witness_succeeds P oracle qp currentEs genesis log v h
  rw [h_ok] at h_eq
  exact absurd h_eq (by simp)

/-! ## proposeAndApplyVerdict — default-safe combined entry point (C.5)

The recommended Stage 3 + Stage 4 entry point.  Internally
validates via `proposeVerdict`, then constructs the
`VerdictPassedStage3` witness via `proposeVerdict_ok_returns_input`
and calls the witness-bearing `applyVerdict`.  Use this unless
you have a specific reason to call `applyVerdict` (witness-bearing)
or `applyVerdictUnchecked` (bypass) directly. -/

/-- Default-safe combined entry point.  Chains Stage 3 + Stage 4
    atomically: validates the verdict via `proposeVerdict`; on
    success, constructs the witness and calls the witness-bearing
    `applyVerdict`; on failure, surfaces the proposing error. -/
def proposeAndApplyVerdict
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (v : Verdict) :
    Except VerdictError ExtendedState :=
  match h_propose : proposeVerdict P oracle qp currentEs genesis log v with
  | .ok v' =>
    have h_eq : v' = v :=
      proposeVerdict_ok_returns_input P oracle qp currentEs genesis log v v' h_propose
    have h_witness : VerdictPassedStage3 P oracle qp currentEs genesis log v :=
      VerdictPassedStage3.of_proposeVerdict_ok_with_eq h_propose h_eq
    applyVerdict P oracle qp currentEs genesis log v h_witness
  | .error e => .error e

/-! ## Properties of proposeAndApplyVerdict (C.5b–e) -/

/-- When `proposeVerdict` would have succeeded, `proposeAndApplyVerdict`
    is equivalent to `applyVerdictUnchecked` (since the witness-
    bearing `applyVerdict` reduces to it definitionally). -/
theorem proposeAndApplyVerdict_eq_applyVerdict_when_proposed_ok
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : proposeVerdict P oracle qp currentEs genesis log v = .ok v) :
    proposeAndApplyVerdict P oracle qp currentEs genesis log v =
    applyVerdictUnchecked P currentEs genesis log v := by
  unfold proposeAndApplyVerdict
  -- The match-with-pattern-binding requires the equation to evaluate.
  split
  · -- .ok v' branch
    rename_i v' h_propose
    rw [h] at h_propose
    cases h_propose
    rfl
  · -- .error e branch — but `h` says proposeVerdict returns .ok, so this case is unreachable.
    rename_i e h_propose
    rw [h] at h_propose
    exact absurd h_propose (by simp)

/-- When `proposeVerdict` returns an error, `proposeAndApplyVerdict`
    surfaces that error verbatim. -/
theorem proposeAndApplyVerdict_proposeVerdict_error_path
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (e : VerdictError)
    (h : proposeVerdict P oracle qp currentEs genesis log v = .error e) :
    proposeAndApplyVerdict P oracle qp currentEs genesis log v = .error e := by
  unfold proposeAndApplyVerdict
  split
  · -- .ok v' — but `h` says .error e, contradiction.
    rename_i v' h_propose
    rw [h] at h_propose
    exact absurd h_propose (by simp)
  · -- .error e' branch — extract `e' = e` from h_propose vs h.
    rename_i e' h_propose
    rw [h] at h_propose
    have : e' = e := by
      have := Except.error.inj h_propose
      exact this.symm
    rw [this]

/-- `proposeAndApplyVerdict` is deterministic. -/
theorem proposeAndApplyVerdict_deterministic
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (es₁ es₂ g₁ g₂ : ExtendedState) (l₁ l₂ : List LogEntry) (v₁ v₂ : Verdict)
    (h_es : es₁ = es₂) (h_g : g₁ = g₂) (h_l : l₁ = l₂) (h_v : v₁ = v₂) :
    proposeAndApplyVerdict P oracle qp es₁ g₁ l₁ v₁ =
    proposeAndApplyVerdict P oracle qp es₂ g₂ l₂ v₂ := by
  rw [h_es, h_g, h_l, h_v]

/-- `proposeAndApplyVerdict` returns `.unknownDispute` when the
    `disputeId` doesn't reference a log entry.  Direct corollary
    of `proposeVerdict`'s error path. -/
theorem proposeAndApplyVerdict_unknown_dispute
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : log[v.disputeId]? = none) :
    proposeAndApplyVerdict P oracle qp currentEs genesis log v =
    .error (.unknownDispute v.disputeId) := by
  apply proposeAndApplyVerdict_proposeVerdict_error_path
  -- proposeVerdict's outer match returns .error (.unknownDispute _) when log[v.disputeId]? = none.
  unfold proposeVerdict
  rw [h]

end Disputes
end LegalKernel

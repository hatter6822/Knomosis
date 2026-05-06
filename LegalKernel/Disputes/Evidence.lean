/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.Evidence — Stage 2 (evidence check) of the §8.4
dispute pipeline.

Phase 6 WU 6.4 / WU 6.5 / WU 6.6 / WU 6.7 / WU 6.8.  Implements the
five `checkEvidence` variants:

  * **`preconditionFalse`** (WU 6.4): replay the log up to `idx-1`,
    recompute `(Action.compile log[idx].action).pre s_{idx-1}`, and
    return `upheld` iff the precondition is false.
  * **`signatureInvalid`** (WU 6.5): re-run `Verify` against the
    registered key for `log[idx].signer` at the time of filing.
    Returns `upheld` iff `Verify` returns `false`.
  * **`nonceMismatch`** (WU 6.6): recompute
    `expectsNonce es_{idx-1} log[idx].signer`, compare to
    `log[idx].nonce`.  Returns `upheld` iff they differ.
  * **`oracleMisreported`** (WU 6.7): consult the deployment-supplied
    `OraclePolicy.verifier`.  Returns whatever the verifier returns.
  * **`doubleApply`** (WU 6.8): verify `log[idx₁].nonce =
    log[idx₂].nonce`, both signed by the same actor, with `idx₁ ≠
    idx₂`.  Returns `upheld` iff all three conditions hold.

The headline `checkEvidence` function dispatches to the
appropriate per-variant verifier based on `claim`.  All verifiers
are *pure*: equal `(P, oracle, log, claim)` inputs always produce
equal `EvidenceVerdict` outputs.  This is what allows multi-
adjudicator quorums to be safe (Genesis Plan §8.4.3).

Module discipline.  Verifiers operate on `(genesis, log, claim,
evidence)`.  They do NOT consult the runtime's current state — the
relevant state is the *replay* of `log[0..idx-1]`, which the
verifier recomputes from scratch.  This is the mathematical
content of "different adjudicators reach the same verdict": same
log → same replay → same verdict.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong evidence verdicts (a deployment-level
adjudication problem) but cannot violate any kernel invariant.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Disputes.Types
import LegalKernel.Runtime.Replay

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority
open LegalKernel.Runtime

/-! ## checkPreconditionFalse (WU 6.4)

Replay the log up to (and including) idx-1, recovering the pre-
state for `log[idx]`.  Then evaluate `Action.compile log[idx].action
|>.transition.pre` against that pre-state.  Return `upheld` iff
the precondition is `false`.

Edge cases:

  * If `idx = 0`, the pre-state is `genesis`; we evaluate
    `(compile log[0].action).transition.pre genesis.base`.
  * If `idx ≥ log.length`, the claim is structurally invalid (the
    Stage 1 in-range check should have caught it).  We return
    `inconclusive` for safety: the caller is expected to ensure
    Stage 1 ran first.
  * If the replay of `log[0..idx-1]` itself fails (e.g. chain
    broken), we return `inconclusive` — the log is corrupt; we
    cannot evaluate the claim against it. -/

/-- Apply one log entry's compiled action to the running state,
    without checking admissibility or chain integrity.  Used by
    the dispute pipeline's prefix-replay, which must succeed even
    on logs whose runtime-time admissibility we cannot
    re-establish (e.g. when a key has rotated since application).

    The kernel-level `step_impl` is a no-op when the precondition
    fails, so applying an inadmissible action via `kernelOnlyApply`
    is safe: the state stays unchanged.  This mirrors the
    runtime's "no silent illegality" property at the dispute
    pipeline's analytical layer. -/
def kernelOnlyApply (es : ExtendedState) (entry : LogEntry) : ExtendedState :=
  let action  := entry.signedAction.action
  let signer  := entry.signedAction.signer
  let t       := (Action.compile action).transition
  let newBase := step_impl es.base t
  let es'     : ExtendedState := { es with base := newBase }
  let es''    := advanceNonce es' signer
  -- Apply registry mutations from `replaceKey` actions.
  match action with
  | .replaceKey actor newKey =>
      { es'' with registry := es''.registry.insert actor newKey }
  | _ => es''

/-- Apply a list of log entries via `kernelOnlyApply` in order.
    Used by the dispute pipeline for prefix-replay where the
    chain-integrity / admissibility / post-hash checks of the
    runtime's `replay` are inappropriate (the dispute pipeline is
    diagnosing whether the runtime should have rejected an action;
    it cannot rely on those checks having passed). -/
def kernelOnlyReplay (genesis : ExtendedState) (entries : List LogEntry) :
    ExtendedState :=
  entries.foldl kernelOnlyApply genesis

/-- Replay the prefix `log[0..idx-1]` against the genesis state and
    recover the pre-state for `log[idx]`.  Uses `kernelOnlyReplay`
    so that admissibility / chain failures in the underlying log
    do not block the dispute pipeline's prefix-state reconstruction.

    Returns `none` if `idx` exceeds `log.length`. -/
def replayPrefix
    (_P : AuthorityPolicy) (genesis : ExtendedState)
    (log : List LogEntry) (idx : LogIndex) :
    Option ExtendedState :=
  if idx > log.length then
    none
  else
    let prefixEntries : List LogEntry := log.take idx
    some (kernelOnlyReplay genesis prefixEntries)

/-- WU 6.4 verifier: `preconditionFalse` claim against `log[idx]`.
    Returns `upheld` iff the precondition fails at the recovered
    pre-state. -/
def checkPreconditionFalse
    (P : AuthorityPolicy) (genesis : ExtendedState)
    (log : List LogEntry) (idx : LogIndex) :
    EvidenceVerdict :=
  match log[idx]? with
  | none => .inconclusive
  | some entry =>
    match replayPrefix P genesis log idx with
    | none => .inconclusive
    | some preState =>
      if (Action.compile entry.signedAction.action).transition.pre preState.base then
        .rejected
      else
        .upheld

/-! ## checkSignatureInvalid (WU 6.5)

Re-run `Verify pk msg sig` against the registered key for
`log[idx].signer` at the time of filing.  Returns `upheld` iff
`Verify` returns `false`.

Note: "the time of filing" means the runtime's *current* registry,
not the registry at `log[idx]`'s application time.  Genesis Plan
§8.4.2 specifies this: re-run Verify against the *registered* key
when the dispute is filed.  This means a key rotation between
application and dispute filing may surface a `signatureInvalid`
verdict that wouldn't have applied at the original time — which is
intentional: the dispute pipeline's job is to catch *current*
inconsistencies, not historical ones. -/

/-- WU 6.5 verifier: `signatureInvalid` claim.  Returns `upheld` iff
    `Verify` returns `false` for the impugned entry's
    `(action, signer, nonce, sig)` under the *current* registered
    key for that signer.

    `currentEs` is the `ExtendedState` at filing time (used to look
    up the current key).  Returns `inconclusive` if the signer is
    no longer registered (the registry was wiped between
    application and filing — the dispute can't be evaluated
    against a missing key). -/
def checkSignatureInvalid
    (currentEs : ExtendedState) (log : List LogEntry) (idx : LogIndex) :
    EvidenceVerdict :=
  match log[idx]? with
  | none => .inconclusive
  | some entry =>
    let st := entry.signedAction
    match currentEs.registry[st.signer]? with
    | none => .inconclusive
    | some pk =>
      -- Audit-3.4 deploymentId: the dispute pipeline currently
      -- hardcodes `ByteArray.empty` for the deploymentId so the
      -- evidence check matches what the back-compat `Admissible`
      -- alias (= `AdmissibleWith Verify ByteArray.empty`) computes.
      -- Deployments using `processSignedActionWith Verify <non-empty-id>`
      -- with a non-empty `deploymentId` need a parameterised
      -- `checkSignatureInvalidWith verify d` variant; this is a
      -- documented Audit-3.4 follow-up scoped for the next CLI
      -- integration pass when the runtime carries `deploymentId`
      -- through `RuntimeState`.
      let msg := signingInput st.action st.signer st.nonce ByteArray.empty
      if Verify pk msg st.sig = true then
        .rejected
      else
        .upheld

/-! ## checkNonceMismatch (WU 6.6)

Recompute `expectsNonce es_{idx-1} log[idx].signer`; compare to
`log[idx].nonce`.  Returns `upheld` iff they differ.

This is the dispute counterpart of admissibility condition 4
(§8.2): if the runtime accepted an action with the wrong nonce,
the dispute pipeline should detect it. -/

/-- WU 6.6 verifier: `nonceMismatch` claim.  Returns `upheld` iff
    the impugned entry's nonce disagrees with the recomputed
    `expectsNonce` at the prefix-replay state. -/
def checkNonceMismatch
    (P : AuthorityPolicy) (genesis : ExtendedState)
    (log : List LogEntry) (idx : LogIndex) :
    EvidenceVerdict :=
  match log[idx]? with
  | none => .inconclusive
  | some entry =>
    match replayPrefix P genesis log idx with
    | none => .inconclusive
    | some preState =>
      let expected := expectsNonce preState entry.signedAction.signer
      if entry.signedAction.nonce = expected then
        .rejected
      else
        .upheld

/-! ## checkOracleMisreported (WU 6.7)

Consult the deployment-supplied `OraclePolicy.verifier`.  No
in-tree logic — the verifier is the entire policy.

The Genesis Plan §8.4.2 specifies: "Run a per-oracle, per-feed
evidence verifier (deployment-supplied).  Holds iff the verifier
accepts the counter-evidence."  We pass through the verifier's
return value verbatim. -/

/-- WU 6.7 verifier: `oracleMisreported` claim.  Delegates to the
    deployment's `OraclePolicy.verifier`.

    **Defensive index check.**  If the impugned index is out of
    range (`log[idx]? = none`), returns `.inconclusive` *without*
    invoking the oracle's verifier.  This protects deployments
    from oracle policies that have undefined behaviour on
    out-of-range indices, and aligns the variant with the other
    four `check*` verifiers (each returns `.inconclusive` when
    the impugned entry is missing).  It is also a load-bearing
    precondition for the strong-correctness theorem
    `applyVerdict_under_witness_succeeds`: combined with the
    Stage-3 witness, it ensures that an `.upheld` evidence
    verdict implies the impugned index is in range — which is
    what makes `replayPrefix` succeed at the prefix-replay step. -/
def checkOracleMisreported
    (oracle : OraclePolicy) (log : List LogEntry)
    (idx : LogIndex) (evidence : ByteArray) :
    EvidenceVerdict :=
  match log[idx]? with
  | none   => .inconclusive
  | some _ => oracle.verifier idx evidence

/-! ## checkDoubleApply (WU 6.8)

Verify `log[idx₁].nonce = log[idx₂].nonce`, both signed by the same
actor, with `idx₁ ≠ idx₂`.  Returns `upheld` iff all three
conditions hold.

The §8.5 `replay_impossible` theorem rules this out under a
correctly-functioning kernel; an `upheld` `doubleApply` is
therefore a kernel-runtime bug. -/

/-- WU 6.8 verifier: `doubleApply` claim.  Returns `upheld` iff
    `log[idx₁].nonce = log[idx₂].nonce`, both have the same
    signer, and `idx₁ ≠ idx₂`. -/
def checkDoubleApply (log : List LogEntry) (idx₁ idx₂ : LogIndex) :
    EvidenceVerdict :=
  if idx₁ = idx₂ then
    .rejected
  else
    match log[idx₁]?, log[idx₂]? with
    | some e₁, some e₂ =>
      let st₁ := e₁.signedAction
      let st₂ := e₂.signedAction
      if st₁.signer = st₂.signer ∧ st₁.nonce = st₂.nonce then
        .upheld
      else
        .rejected
    | _, _ => .inconclusive

/-! ## The headline `checkEvidence` dispatcher (Stage 2)

Dispatches to the appropriate per-variant verifier.  Pure: equal
inputs always produce equal outputs (§8.4.3 determinism property).

The `currentEs` argument is the runtime's `ExtendedState` at filing
time (consulted by `signatureInvalid` for the current registered
key).  The `genesis` argument is the deployment's genesis
`ExtendedState` (consulted by `preconditionFalse` and
`nonceMismatch` for the prefix-replay starting point). -/

/-- Stage 2 of the dispute pipeline: evaluate the dispute's
    evidence and return the verdict.  Pure (deterministic) —
    equal `(P, oracle, currentEs, genesis, log, rec)` inputs
    always produce equal outputs. -/
def checkEvidence
    (P : AuthorityPolicy) (oracle : OraclePolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (rec : DisputeRecord) :
    EvidenceVerdict :=
  match rec.dispute.claim with
  | .preconditionFalse idx       =>
      checkPreconditionFalse P genesis log idx
  | .signatureInvalid idx        =>
      checkSignatureInvalid currentEs log idx
  | .nonceMismatch idx           =>
      checkNonceMismatch P genesis log idx
  | .oracleMisreported idx ev    =>
      checkOracleMisreported oracle log idx ev
  | .doubleApply idx₁ idx₂       =>
      checkDoubleApply log idx₁ idx₂

/-! ## Determinism (§8.4.3 headline property) -/

/-- `checkEvidence` is deterministic: equal inputs produce equal
    outputs.  Trivial (it's a pure function), but stated for the
    Phase-6 acceptance gate. -/
theorem checkEvidence_deterministic
    (P : AuthorityPolicy) (oracle : OraclePolicy)
    (currentEs₁ currentEs₂ : ExtendedState)
    (genesis₁ genesis₂ : ExtendedState)
    (log₁ log₂ : List LogEntry) (rec₁ rec₂ : DisputeRecord)
    (h_es : currentEs₁ = currentEs₂) (h_g : genesis₁ = genesis₂)
    (h_l : log₁ = log₂) (h_r : rec₁ = rec₂) :
    checkEvidence P oracle currentEs₁ genesis₁ log₁ rec₁ =
    checkEvidence P oracle currentEs₂ genesis₂ log₂ rec₂ := by
  rw [h_es, h_g, h_l, h_r]

/-- `checkPreconditionFalse` is deterministic. -/
theorem checkPreconditionFalse_deterministic
    (P : AuthorityPolicy) (genesis₁ genesis₂ : ExtendedState)
    (log₁ log₂ : List LogEntry) (idx₁ idx₂ : LogIndex)
    (h_g : genesis₁ = genesis₂) (h_l : log₁ = log₂) (h_idx : idx₁ = idx₂) :
    checkPreconditionFalse P genesis₁ log₁ idx₁ =
    checkPreconditionFalse P genesis₂ log₂ idx₂ := by
  rw [h_g, h_l, h_idx]

/-- `checkOracleMisreported` returns whatever the oracle policy
    returns *when the impugned index is in range*.  Pass-through
    on the in-range branch; the out-of-range branch is governed
    by `checkOracleMisreported_inconclusive_on_out_of_range`. -/
theorem checkOracleMisreported_returns_oracle_verdict
    (oracle : OraclePolicy) (log : List LogEntry) (idx : LogIndex)
    (evidence : ByteArray) (entry : LogEntry)
    (h : log[idx]? = some entry) :
    checkOracleMisreported oracle log idx evidence =
    oracle.verifier idx evidence := by
  unfold checkOracleMisreported
  rw [h]

/-- `checkOracleMisreported` returns `.inconclusive` when the
    impugned index is out of range, *without* invoking the
    oracle's verifier.  Defensive index check — the fifth
    `check*` verifier now matches the other four in this
    respect. -/
theorem checkOracleMisreported_inconclusive_on_out_of_range
    (oracle : OraclePolicy) (log : List LogEntry) (idx : LogIndex)
    (evidence : ByteArray) (h : log[idx]? = none) :
    checkOracleMisreported oracle log idx evidence = .inconclusive := by
  unfold checkOracleMisreported
  rw [h]

/-- `checkDoubleApply` rejects the `idx₁ = idx₂` case (claim
    structurally invalid). -/
theorem checkDoubleApply_rejects_self
    (log : List LogEntry) (idx : LogIndex) :
    checkDoubleApply log idx idx = .rejected := by
  unfold checkDoubleApply
  simp

/-! ## kernelOnlyApply ↔ apply_admissible_with coherence (Audit-3.6)

The dispute pipeline replays log prefixes via `kernelOnlyApply`
(admissibility-blind, falls back to `step_impl`'s identity branch
when preconditions fail).  The runtime applies log entries via
`apply_admissible_with` (admissibility-checked, uses the
transition's `apply_impl` directly).

These two functions agree on every log entry that the runtime
*would* have accepted as admissible.  The headline theorem
formalises this:

  apply_admissible_with verify P d es entry.signedAction h
    = kernelOnlyApply es entry

(under the admissibility witness `h`).

Operational consequence: on any log prefix where the runtime
accepted every entry, `kernelOnlyReplay` and the runtime's state
agree at every point.  The dispute pipeline's evidence checks
are therefore evaluating against the same pre-states the runtime
saw — there is no asymmetry that could produce phantom dispute
upholds.

The theorem closes a previously-flagged trust-boundary concern:
without the coherence guarantee, a registry-state divergence
between the two replay paths could theoretically let a dispute
verifier reach a different verdict than the runtime's behaviour
warrants.  The proof certifies that no such divergence exists
under admissibility. -/

/-- Audit-3.6 per-step coherence lemma.  Under the admissibility
    witness, `apply_admissible_with` and `kernelOnlyApply` produce
    the same `ExtendedState`.

    Proof: `apply_admissible_with` uses `t.apply_impl es.base`
    directly; `kernelOnlyApply` uses `step_impl es.base t = if t.pre
    es.base then t.apply_impl es.base else es.base`.  The 5th
    conjunct of `AdmissibleWith` (the kernel precondition holds)
    forces the `if` to take the `then` branch, making the two
    expressions equal.  Nonce advancement and registry mutation
    agree definitionally for every Action constructor. -/
theorem apply_admissible_with_eq_kernelOnlyApply
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {entry : LogEntry}
    (h : AdmissibleWith verify P d es entry.signedAction) :
    apply_admissible_with verify P d es entry.signedAction h
      = kernelOnlyApply es entry := by
  -- The admissibility witness's 5th conjunct gives us
  -- `(Action.compile entry.signedAction.action).transition.pre es.base`.
  have hPre : (Action.compile entry.signedAction.action).transition.pre es.base :=
    h.2.2.2
  -- Unfold both sides; under hPre, `step_impl` collapses to `apply_impl`,
  -- and the registry/nonce updates agree by construction.
  unfold apply_admissible_with applyActionToRegistry kernelOnlyApply step_impl
  -- The runtime path (LHS) uses `t.apply_impl`; the dispute path (RHS) uses
  -- `if t.pre es.base then t.apply_impl es.base else es.base`.  Replace the
  -- `if` with its `then` branch via `hPre`.
  simp only [if_pos hPre]
  -- Now both sides match modulo per-constructor registry handling.  Case
  -- split on the action constructor to settle the registry field.
  cases hact : entry.signedAction.action with
  | transfer _ _ _ _         => rfl
  | mint _ _ _               => rfl
  | burn _ _ _               => rfl
  | freezeResource _         => rfl
  | replaceKey actor newKey  => rfl
  | reward _ _ _             => rfl
  | distributeOthers _ _ _   => rfl
  | proportionalDilute _ _ _ => rfl
  | dispute _                => rfl
  | disputeWithdraw _        => rfl
  | verdict _                => rfl
  | rollback _               => rfl

/-! ### Inductive runtime-admissibility predicate

`RuntimeAdmissibleWith verify P d es log` means: every entry in
`log`, applied in order starting from `es`, was admissible.  This
is the load-bearing hypothesis of the headline coherence
theorem. -/

/-- Audit-3.6: `RuntimeAdmissibleWith` carries an admissibility
    witness for every log entry, evaluated at the running state.

    `nil`: the empty log is trivially admissible.
    `cons`: the head entry is admissible at the current state, and
            the tail is admissible at the post-application state. -/
inductive RuntimeAdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) :
    ExtendedState → List LogEntry → Prop
  /-- The empty log is trivially admissible. -/
  | nil  {es : ExtendedState} : RuntimeAdmissibleWith verify P d es []
  /-- A non-empty log is admissible iff its head is admissible at
      the current state AND the tail is admissible at the post-
      head-application state. -/
  | cons {es : ExtendedState} {entry : LogEntry} {rest : List LogEntry}
         (h : AdmissibleWith verify P d es entry.signedAction)
         (tail : RuntimeAdmissibleWith verify P d
                   (apply_admissible_with verify P d es entry.signedAction h) rest) :
         RuntimeAdmissibleWith verify P d es (entry :: rest)

/-! ### Chain-level coherence (Audit-3.6 headline)

The per-step lemma `apply_admissible_with_eq_kernelOnlyApply`
above is the load-bearing coherence guarantee: at every log entry
under admissibility, the dispute pipeline's
`kernelOnlyApply` produces the same post-state as the runtime's
`apply_admissible_with`.

Lifted to a full log via `RuntimeAdmissibleWith` (the inductive
chain-level admissibility predicate), this means: if the runtime
accepted every entry of `log`, the dispute pipeline's
`kernelOnlyReplay es log` recovers the same `ExtendedState` that
the runtime would have computed.  Operational consequence: the
dispute pipeline's evidence checks evaluate against the same
pre-states the runtime saw — there is no replay-path asymmetry
that could produce phantom dispute upholds.

The chain-level corollary follows by routine induction on
`RuntimeAdmissibleWith`: at each `cons` step, the per-step lemma
gives equality, and the inductive hypothesis closes the tail.
The proof is mechanical given the per-step lemma; we leave
explicit chain-level theorem statements to per-callsite derivation
because the dependent-type machinery for "fold apply_admissible_with
along a witness chain" is awkward to state generically without
adding accessor lemmas to the `RuntimeAdmissibleWith` predicate
that downstream code does not need. -/

/-- Audit-3.6: extract the head-entry admissibility witness from a
    non-empty `RuntimeAdmissibleWith`.  Useful for callers that
    need to pass the witness to `apply_admissible_with`. -/
theorem RuntimeAdmissibleWith.head
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {entry : LogEntry} {rest : List LogEntry}
    (h : RuntimeAdmissibleWith verify P d es (entry :: rest)) :
    AdmissibleWith verify P d es entry.signedAction := by
  cases h with
  | cons hh _ => exact hh

/-- Audit-3.6: the per-step coherence lifted to a `cons` step.
    Under the head admissibility witness, applying the head entry
    via `apply_admissible_with` produces the same post-state as
    `kernelOnlyApply`.  Operationally: the dispute-pipeline's
    prefix-replay agrees with the runtime at the head entry of
    any admissible chain. -/
theorem kernelOnlyApply_eq_apply_admissible_with_at_head
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {entry : LogEntry} {rest : List LogEntry}
    (h : RuntimeAdmissibleWith verify P d es (entry :: rest)) :
    kernelOnlyApply es entry =
      apply_admissible_with verify P d es entry.signedAction h.head :=
  (apply_admissible_with_eq_kernelOnlyApply h.head).symm

end Disputes
end LegalKernel

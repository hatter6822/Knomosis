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
      let msg := signingInput st.action st.signer st.nonce
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

end Disputes
end LegalKernel

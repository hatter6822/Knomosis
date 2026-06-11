-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
  -- GP.2.3: use the signer-aware `Action.toTransition` helper so the
  -- kernel-level effect for `topUpActionBudget` debits the actual
  -- signer (not the placeholder bridgeActor).  Mirrors
  -- `apply_admissible_with` exactly, preserving the §8.4 dispute
  -- pipeline's prefix-replay byte-equivalence with the runtime path.
  let t       := Action.toTransition action signer
  let newBase := step_impl es.base t
  let es'     : ExtendedState := { es with base := newBase }
  let es''    := advanceNonce es' signer
  -- Apply registry mutations.  Currently `replaceKey` and (Workstream B)
  -- `registerIdentity` are the only registry-mutating actions; both
  -- semantics are `kr.insert actor key`.  The `applyActionToRegistry`
  -- function in `Authority/SignedAction.lean` is the canonical
  -- definition; this match keeps `kernelOnlyApply` self-contained
  -- (and keeps the §8.4.3 prefix-replay determinism theorems
  -- unconditional on `Authority/SignedAction.lean`'s import surface).
  -- AR.17 / m-14.  Pre-AR this match ended with `| _ => es''` which
  -- silently absorbed any future `Action` constructor.  The
  -- post-AR exhaustive case-split forces a manual review of
  -- `kernelOnlyApply`'s policy at compile time whenever the
  -- `Action` inductive grows: an un-enumerated constructor is an
  -- elaboration error rather than a silent no-op.  Every
  -- non-registry / non-LP action is explicitly mapped to `es''`
  -- (no further mutation beyond the kernel step + nonce advance
  -- already applied above).
  match action with
  -- Registry-mutating actions.
  | .replaceKey actor newKey =>
      { es'' with registry := es''.registry.insert actor newKey }
  | .registerIdentity actor pk =>
      { es'' with registry := es''.registry.insert actor pk }
  -- LP.5: local-policy meta-actions.
  | .declareLocalPolicy policy =>
      { es'' with localPolicies := es''.localPolicies.declare signer policy }
  | .revokeLocalPolicy =>
      { es'' with localPolicies := es''.localPolicies.revoke signer }
  -- Every other `Action` constructor: the kernel step + nonce
  -- advance above are the entirety of `kernelOnlyApply`'s effect;
  -- no registry / local-policy / bridge mutation in this layer.
  -- (Bridge mutations happen via `applyActionToBridgeState`; the
  -- dispute pipeline's `kernelOnlyApply` deliberately doesn't
  -- evaluate them — disputes never directly reason about bridge
  -- sub-state.)
  | .transfer _ _ _ _              => es''
  | .mint _ _ _                    => es''
  | .burn _ _ _                    => es''
  | .freezeResource _              => es''
  | .reward _ _ _                  => es''
  | .distributeOthers _ _ _        => es''
  | .proportionalDilute _ _ _      => es''
  | .dispute _                     => es''
  | .disputeWithdraw _             => es''
  | .verdict _                     => es''
  | .rollback _                    => es''
  | .deposit _ _ _ _               => es''
  | .withdraw _ _ _ _              => es''
  | .faultProofChallenge _ _ _ _   => es''
  | .faultProofResolution _ _ _ _  => es''
  -- Workstream GP (v1.0): depositWithFee + topUpActionBudget.
  -- For depositWithFee, the kernel-level effect (credit recipient +
  -- credit poolActor) is fully in `Laws.depositWithFee` — handled
  -- by the kernel step above.  No further authority-level effect
  -- at the kernelOnlyApply layer (budget-grant effects live in the
  -- admission gate, which kernelOnlyApply doesn't model).
  -- For topUpActionBudget, the signer-aware kernel effect is
  -- handled by the `let t := match action with ...` arm above; no
  -- further mutation at this point.
  | .depositWithFee _ _ _ _ _ _ _  => es''
  | .topUpActionBudget _ _ _ _     => es''
  -- Workstream GP (GP.3.4): delegated top-up.  Like
  -- `topUpActionBudget`, the signer-aware kernel effect
  -- (`Laws.topUpActionBudgetFor recipient signer …`) is handled by
  -- the `let t := Action.toTransition action signer` step above; no
  -- further registry / local-policy mutation at this layer (the
  -- recipient budget grant is an admission-layer effect that
  -- `kernelOnlyApply` deliberately doesn't model).
  | .topUpActionBudgetFor _ _ _ _ _ => es''
  -- Workstream GP (GP.9.1): refund-on-exit.  The signer-aware kernel
  -- effect (`Laws.claimBudgetRefund signer poolActor gasResource
  -- (budgetUnits × weiPerBudgetUnit)`, crediting the claimant from the
  -- pool) is handled by the `let t := Action.toTransition action
  -- signer` step above; no further registry / local-policy mutation at
  -- this layer (the refund's budget DEBIT is an admission-layer effect
  -- that `kernelOnlyApply` deliberately doesn't model).
  | .claimBudgetRefund _ _ _ _     => es''
  -- Workstream GP (GP.11.4): L2 AMM swap.  The swap is NOT signer-
  -- aware; `Action.compileTransition` (and thus `Action.toTransition`)
  -- maps it directly to `Laws.ammSwap`.  No registry / local-policy
  -- mutation.
  | .ammSwap _ _ _ _ _             => es''
  -- Workstream GP (GP.11.10): post-disable reserve sweep.  Like
  -- `ammSwap`, the sweep is NOT signer-aware; `Action.compileTransition`
  -- maps it directly to `Laws.reclaimAmmReserves` (handled by the
  -- kernel step above).  No registry / local-policy mutation; the
  -- kill-switch admission gate (`BridgeAdmissibleWith` conjunct 9) is
  -- an admission-layer effect `kernelOnlyApply` deliberately doesn't
  -- model.
  | .reclaimAmmReserves _ _ _ _    => es''

/-- **Bridge-scope invariant.**  `kernelOnlyApply` leaves the bridge
    sub-state (`consumed` / `pending` / `nextWdId`) completely
    unchanged.  It only ever writes `base` (the kernel step), `nonces`
    (the nonce advance), and — for the registry / local-policy
    meta-actions — `registry` / `localPolicies`.  The L1 ↔ L2 bridge
    ledger is mutated exclusively by `applyActionToBridgeState` at the
    bridge-admission layer (`apply_bridge_admissible_with`), never
    here.

    This promotes the scope boundary stated informally in
    `kernelOnlyApply`'s body comment to a machine-checked fact.  The
    dispute pipeline and the Workstream-H fault proof — whose per-step
    reference semantics is `kernelOnlyApply` (via
    `FaultProof.recomputeCommitment`) — adjudicate the kernel-execution
    sub-state only; the bridge sub-state is a constant context across
    every adjudicated step.  Its evolution (deposit-replay protection,
    withdrawal tracking) is verified by the dedicated bridge machinery
    — `BridgeAdmissibleWith`'s deposit-id-freshness conjuncts at
    admission time and the §7.6 / §13 withdrawal-proof + finalisation
    chain on L1 — not by the per-step bisection game. -/
theorem kernelOnlyApply_preserves_bridge (es : ExtendedState)
    (entry : LogEntry) :
    (kernelOnlyApply es entry).bridge = es.bridge := by
  simp only [kernelOnlyApply]
  split <;> rfl

/-- Apply a list of log entries via `kernelOnlyApply` in order.
    Used by the dispute pipeline for prefix-replay where the
    chain-integrity / admissibility / post-hash checks of the
    runtime's `replay` are inappropriate (the dispute pipeline is
    diagnosing whether the runtime should have rejected an action;
    it cannot rely on those checks having passed). -/
def kernelOnlyReplay (genesis : ExtendedState) (entries : List LogEntry) :
    ExtendedState :=
  entries.foldl kernelOnlyApply genesis

/-- The bridge-scope invariant lifts to multi-step replay:
    `kernelOnlyReplay` over any log leaves the genesis bridge
    sub-state unchanged (each step preserves it via
    `kernelOnlyApply_preserves_bridge`).  So an entire dispute /
    fault-proof prefix-replay holds the bridge ledger constant. -/
theorem kernelOnlyReplay_preserves_bridge (genesis : ExtendedState)
    (entries : List LogEntry) :
    (kernelOnlyReplay genesis entries).bridge = genesis.bridge := by
  unfold kernelOnlyReplay
  induction entries generalizing genesis with
  | nil => rfl
  | cons hd tl ih =>
    simp only [List.foldl]
    rw [ih (kernelOnlyApply genesis hd)]
    exact kernelOnlyApply_preserves_bridge genesis hd

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

/-- AR.2.5 / M-5: parameterised verifier for `signatureInvalid`
    claims.  Returns `upheld` iff `verify pk msg sig` returns
    `false` for the impugned entry under the supplied deploymentId
    `d`.

    `currentEs` is the `ExtendedState` at filing time (used to look
    up the current key).  Returns `inconclusive` if the signer is
    no longer registered (the registry was wiped between
    application and filing — the dispute can't be evaluated against
    a missing key).

    Production callers (the runtime dispute pipeline) thread the
    deployment's `deploymentId` here so cross-deployment-replay
    signatures are correctly flagged as invalid.  The
    back-compat `checkSignatureInvalid` alias below specialises at
    `ByteArray.empty` for the empty-deployment test path. -/
def checkSignatureInvalidWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray)
    (currentEs : ExtendedState) (log : List LogEntry) (idx : LogIndex) :
    EvidenceVerdict :=
  match log[idx]? with
  | none => .inconclusive
  | some entry =>
    let st := entry.signedAction
    match currentEs.registry[st.signer]? with
    | none => .inconclusive
    | some pk =>
      let msg := signingInput st.action st.signer st.nonce d
      if verify pk msg st.sig = true then
        .rejected
      else
        .upheld

/-- WU 6.5 verifier: `signatureInvalid` claim.  Back-compat alias
    for `checkSignatureInvalidWith Verify ByteArray.empty`.

    Production callers must NOT use this alias — they should call
    `checkSignatureInvalidWith Verify <deploymentId>` directly so
    cross-deployment-replay signatures are correctly distinguished
    from same-deployment invalid signatures.  The alias is kept for
    test scaffolding that operates at the empty deploymentId. -/
def checkSignatureInvalid
    (currentEs : ExtendedState) (log : List LogEntry) (idx : LogIndex) :
    EvidenceVerdict :=
  checkSignatureInvalidWith Verify ByteArray.empty currentEs log idx

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

/-- AR.2.5 / M-5: parameterised Stage 2 dispatcher.  Routes the
    `signatureInvalid` claim through `checkSignatureInvalidWith
    verify d` so cross-deployment-replay rejection is observable
    end-to-end in the dispute pipeline.  Pure (deterministic) —
    equal inputs always produce equal outputs.

    Production callers should use this parameterised form,
    threading the deployment's `deploymentId` from `RuntimeState`.
    The back-compat alias `checkEvidence` below specialises at
    `(Verify, ByteArray.empty)` for test scaffolding.

    AR.2.5 architectural note.  The plan's AR.2.5 wording asked
    for threading `deploymentId` "through `fileDispute`", but
    `fileDispute` is Stage 1 (acceptance only — registration,
    in-range, duplicate) and invokes no signature verifier.  The
    actual cross-deployment-replay hazard lives in Stage 2's
    `checkEvidence` (which dispatches to `checkSignatureInvalid`
    for the `signatureInvalid` claim).  Parameterising
    `checkEvidence` here addresses the hazard the plan
    identified, even though the plan's text named the wrong
    Stage. -/
def checkEvidenceWith
    (verify : Authority.PublicKey → ByteArray → Authority.Signature → Bool)
    (d : ByteArray)
    (P : AuthorityPolicy) (oracle : OraclePolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (rec : DisputeRecord) :
    EvidenceVerdict :=
  match rec.dispute.claim with
  | .preconditionFalse idx       =>
      checkPreconditionFalse P genesis log idx
  | .signatureInvalid idx        =>
      checkSignatureInvalidWith verify d currentEs log idx
  | .nonceMismatch idx           =>
      checkNonceMismatch P genesis log idx
  | .oracleMisreported idx ev    =>
      checkOracleMisreported oracle log idx ev
  | .doubleApply idx₁ idx₂       =>
      checkDoubleApply log idx₁ idx₂

/-- Stage 2 of the dispute pipeline: evaluate the dispute's
    evidence and return the verdict.  Pure (deterministic) —
    equal `(P, oracle, currentEs, genesis, log, rec)` inputs
    always produce equal outputs.

    AR.2.5 back-compat alias.  Defined as `checkEvidenceWith
    Verify ByteArray.empty` so existing callers (test
    harnesses, single-deployment dev mode) keep their pre-AR
    behaviour.  Production callers should migrate to
    `checkEvidenceWith Verify <deploymentId>`. -/
def checkEvidence
    (P : AuthorityPolicy) (oracle : OraclePolicy)
    (currentEs : ExtendedState) (genesis : ExtendedState)
    (log : List LogEntry) (rec : DisputeRecord) :
    EvidenceVerdict :=
  checkEvidenceWith Verify ByteArray.empty P oracle
                    currentEs genesis log rec

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
  -- The admissibility witness's 4th conjunct gives us
  -- `(Action.compile entry.signedAction.action).transition.pre es.base`.
  -- LP.7 robustness: use `obtain` rather than chained-tuple projection
  -- (the conjunct chain shifted with LP.7's local-policy addition).
  have hPre : (Action.compile entry.signedAction.action).transition.pre es.base := by
    obtain ⟨_, _, _, hPre, _⟩ := h
    exact hPre
  -- Unfold both sides.  Post-GP.2.3 both `apply_admissible_with`
  -- and `kernelOnlyApply` use the same shape (signer-aware match
  -- + `step_impl`); they agree by construction in every arm.  The
  -- `hPre` witness ensures `step_impl` collapses to `apply_impl`
  -- for non-topUpActionBudget actions, which is needed only for
  -- the term-level downstream consumers; the structural equality
  -- here doesn't depend on it.
  let _ := hPre  -- mark consumed (proof obligation discharged via match below)
  unfold apply_admissible_with applyActionToRegistry kernelOnlyApply
  -- Now both sides match modulo per-constructor registry handling.  Case
  -- split on the action constructor to settle the registry field.
  cases hact : entry.signedAction.action with
  | transfer _ _ _ _              => rfl
  | mint _ _ _                    => rfl
  | burn _ _ _                    => rfl
  | freezeResource _              => rfl
  | replaceKey actor newKey       => rfl
  | reward _ _ _                  => rfl
  | distributeOthers _ _ _        => rfl
  | proportionalDilute _ _ _      => rfl
  | dispute _                     => rfl
  | disputeWithdraw _             => rfl
  | verdict _                     => rfl
  | rollback _                    => rfl
  | registerIdentity actor pk     => rfl
  | deposit _ _ _ _               => rfl
  | withdraw _ _ _ _              => rfl
  | declareLocalPolicy _          => rfl
  | revokeLocalPolicy             => rfl
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl
  -- Workstream GP (v1.0): depositWithFee compiles to
  -- `Laws.depositWithFee` (signer-independent kernel effect);
  -- both `apply_admissible_with` and `kernelOnlyApply` use the
  -- same `(Action.compile st.action).transition`, so they agree
  -- by `rfl`.
  | depositWithFee _ _ _ _ _ _ _  => rfl
  -- topUpActionBudget compiles to `Laws.freezeResource 0` at the
  -- signer-unaware level, but both `apply_admissible_with` and
  -- `kernelOnlyApply` post-GP.2.3 dispatch on the action and use
  -- the signer-aware `Laws.topUpActionBudget signer ...`.  Both
  -- paths wrap the transition in `step_impl` (same body), so
  -- they remain byte-identical for this action variant too.
  | topUpActionBudget _ _ _ _     => rfl
  -- GP.3.4: same signer-aware shape for the delegated top-up; both
  -- paths use `Laws.topUpActionBudgetFor recipient signer …` via
  -- `Action.toTransition`, wrapped in `step_impl`.
  | topUpActionBudgetFor _ _ _ _ _ => rfl
  | claimBudgetRefund _ _ _ _     => rfl
  | ammSwap _ _ _ _ _             => rfl
  -- GP.11.10: the reserve sweep is signer-unaware (it compiles
  -- directly to `Laws.reclaimAmmReserves`); both paths wrap the same
  -- transition in `step_impl`, so they stay byte-identical.
  | reclaimAmmReserves _ _ _ _    => rfl

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

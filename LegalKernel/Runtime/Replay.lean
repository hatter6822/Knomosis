/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.Replay — replay tool: genesis + log → final state.

Phase 5 WU 5.5.  Implements the replay function that an auditor or a
freshly-bootstrapped replica uses to recover the deployment's state
from a transition log.

Genesis Plan §8.7 acceptance: "the current state $s_n$ is reproducible
from $s_0$ and the log, bit-for-bit, by replay."

The replay tool is **independent** of the runtime: it reads the same
log file the runtime writes, but it does NOT call the runtime's
`apply_admissible` directly through the runtime binary — instead it
re-runs `apply_admissible` from a clean process, producing a state
that the runtime did not influence.  The acceptance test compares
the replay tool's `StateHash` against the runtime's: a mismatch is a
non-determinism bug.

**Determinism property.**  The kernel's `apply_admissible` is a pure
Lean function (no IO, no global state, no concurrency).  Replay
calls it on the same inputs in the same order, so equal logs produce
equal final states (`replay_deterministic`).  This is what the
Phase-5 acceptance gate requires.

**Admissibility witness reconstruction.**  Each `LogEntry` carries
the `SignedAction` but not the `Admissible` proof — the kernel
discharged that proof at apply time, and the proof is irrelevant
once the action has been applied.  Replay reconstructs the
admissibility witness by re-running the same admissibility checks
against the current replay state.  If a log entry fails the check
during replay, the log itself is corrupt (the runtime would have
rejected it in the first place); replay returns a `ReplayError`.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong replay results (a deployment-level
diagnostic problem) but cannot violate any kernel invariant.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Bridge.Admissible
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace Runtime

open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## Replay errors

Distinguish `chainBroken` (entry's `prevHash` doesn't match
predecessor) from `notAdmissible` (action wasn't admissible at the
recovered state) from `postHashMismatch` (the recorded
`postStateHash` doesn't match the recomputed one).  All three
indicate log corruption — none can occur on a log produced by an
honest runtime — but they distinguish *which kind* of corruption,
which is useful for diagnostics. -/

/-- Errors that replay can produce. -/
inductive ReplayError where
  /-- An entry's `prevHash` did not match its predecessor's
      `LogEntry.hash`.  Indicates either a corrupt log file or a
      reordering attack. -/
  | chainBroken (atIndex : Nat)
  /-- The signed action at index `atIndex` was not admissible at the
      replayed state.  Indicates either a bug in the runtime (it
      applied an inadmissible action) or a forged log. -/
  | notAdmissible (atIndex : Nat)
  /-- The recorded `postStateHash` did not match the recomputed
      hash of the replay's intermediate state.  Indicates a
      non-deterministic computation between the runtime and the
      replay tool — i.e. a kernel bug. -/
  | postHashMismatch (atIndex : Nat)
  deriving Repr

/-! ## The admissibility-checking helper

To replay each log entry, we need to verify that its `SignedAction`
is admissible at the current replay state under the deployment's
`AuthorityPolicy`.  We use Lean's `Decidable` machinery: every
clause of `Admissible` is decidable (the policy's `decAuth`, the
nonce match, signer registration, signature verification, kernel
precondition), so the whole predicate is decidable. -/

/-- Decidability of the registration-and-verify clause: there
    exists a public key `pk` such that the registry maps `signer`
    to `pk` and `verify pk msg sig = true`.  This is the
    "registration ∧ signature" part of `AdmissibleWith`.

    Audit-3.3: parameterised over the verifier function so
    `mockVerify` (test) and the production `Verify` resolve via the
    same instance shape. -/
instance AdmissibleWith.decRegisteredAndSigned
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray) (es : ExtendedState) (st : SignedAction) :
    Decidable (∃ pk, es.registry[st.signer]? = some pk ∧
                      verify pk (signingInput st.action st.signer st.nonce d) st.sig = true) := by
  -- Generalise the lookup result so we can refine on it.
  generalize hLookup : es.registry[st.signer]? = lookupResult
  cases lookupResult with
  | none =>
    apply isFalse
    intro ⟨_, hReg, _⟩
    -- hReg : none = some _ which is impossible.
    exact (Option.some_ne_none _ hReg.symm).elim
  | some pk =>
    by_cases hver :
        verify pk (signingInput st.action st.signer st.nonce d) st.sig = true
    · exact isTrue ⟨pk, rfl, hver⟩
    · apply isFalse
      intro ⟨pk', hReg, hver'⟩
      have heq := Option.some.inj hReg
      rw [← heq] at hver'
      exact hver hver'

/-- Audit-3.3: decidability of the parameterised admissibility
    predicate.  Built from the decidability of each conjunct:
    `P.authorized` (via `P.decAuth`), nonce equality (Nat),
    signer registration + signature (the `verify` is `Bool`-valued,
    so the existential decides via `decide` on the registry lookup),
    and the kernel precondition. -/
instance AdmissibleWith.decidable
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray)
    (es : ExtendedState) (st : SignedAction) :
    Decidable (AdmissibleWith verify P d es st) := by
  unfold AdmissibleWith
  haveI := P.decAuth st.signer st.action
  haveI := (Action.compile st.action).transition.decPre es.base
  haveI := AdmissibleWith.decRegisteredAndSigned verify d es st
  exact inferInstance

/-- Decidability of the §8.2 `Admissible` predicate.  Audit-3.3:
    derived from the parameterised `AdmissibleWith.decidable`
    instance specialised to `Verify` and the empty deploymentId. -/
instance Admissible.decidable
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction) :
    Decidable (Admissible P es st) :=
  AdmissibleWith.decidable Verify P ByteArray.empty es st

/-! ## Decidability of `BridgeAdmissibleWith` (RB.1 — bridge-aware
    runtime admission gate)

The runtime's `processSignedActionWith` / `processPure` /
`replayStepWith` entry points dispatch on `BridgeAdmissibleWith`
via Lean's `if h : ... then ... else ...` syntax, which requires a
`Decidable` instance.  Lives here (alongside `AdmissibleWith.decidable`
rather than in `Bridge/Admissible.lean` where the predicate is
defined) because the decidability proof depends on
`AdmissibleWith.decidable` — moving the dependency back into the
Bridge layer would invert the project's "decidability ships with
the consumer" convention.

Each of the three bridge-specific conjuncts (deposit-id freshness,
registration freshness, bridge-only signer) decomposes on `Action`-
constructor case analysis.  The `generalize` step is essential:
without it, `cases` on `st.action` substitutes the constructor into
the goal but leaves the universally-quantified equality hypothesis
in the `intro`-introduced subterm referring to the original
`st.action`, breaking unification on the deposit / registerIdentity
branches. -/

open LegalKernel.Bridge

/-- RB.1.a — Decidable instance for the deposit-id-freshness
    obligation (`BridgeAdmissibleWith` conjunct 6).  Reduces to
    `Decidable (bridge.consumed.contains depositId = false)` when
    the action is a `deposit`, and to `Decidable True` for every
    other constructor (the universally-quantified premise is
    structurally impossible). -/
instance BridgeAdmissibleWith.dec_depositIdFresh
    (es : ExtendedState) (st : SignedAction) :
    Decidable
      (∀ r recipient amount depositId,
         st.action = .deposit r recipient amount depositId →
         es.bridge.consumed.contains depositId = false) := by
  generalize _h_eq : st.action = a
  cases a with
  | deposit r recipient amount depositId =>
    by_cases hcon : es.bridge.consumed.contains depositId = false
    · apply isTrue
      intro _ _ _ _ heq
      injection heq with _ _ _ hd
      subst hd
      exact hcon
    · apply isFalse
      intro h
      exact hcon (h r recipient amount depositId rfl)
  | _ => apply isTrue; intro _ _ _ _ heq; cases heq

/-- RB.1.a' — Decidable instance for the depositWithFee-id-freshness
    obligation (`BridgeAdmissibleWith` conjunct 6b).  Mirror of
    `dec_depositIdFresh` for the Workstream-GP `.depositWithFee`
    constructor: reduces to `Decidable (bridge.consumed.contains
    depositId = false)` when the action is `.depositWithFee`, and
    to `Decidable True` for every other constructor. -/
instance BridgeAdmissibleWith.dec_depositWithFeeIdFresh
    (es : ExtendedState) (st : SignedAction) :
    Decidable
      (∀ r recipient poolActor userAmount poolAmount budgetGrant depositId,
         st.action = .depositWithFee r recipient poolActor userAmount poolAmount
                       budgetGrant depositId →
         es.bridge.consumed.contains depositId = false) := by
  generalize _h_eq : st.action = a
  cases a with
  | depositWithFee r recipient poolActor userAmount poolAmount budgetGrant depositId =>
    by_cases hcon : es.bridge.consumed.contains depositId = false
    · apply isTrue
      intro _ _ _ _ _ _ _ heq
      injection heq with _ _ _ _ _ _ hd
      subst hd
      exact hcon
    · apply isFalse
      intro h
      exact hcon (h r recipient poolActor userAmount poolAmount budgetGrant depositId rfl)
  | _ => apply isTrue; intro _ _ _ _ _ _ _ heq; cases heq

/-- RB.1.b — Decidable instance for the registration-freshness
    obligation (`BridgeAdmissibleWith` conjunct 7).  Reduces to
    `Decidable (registry[actor]? = none)` when the action is a
    `registerIdentity`, and to `Decidable True` for every other
    constructor.  Same `generalize` rationale as conjunct 6. -/
instance BridgeAdmissibleWith.dec_registrationFresh
    (es : ExtendedState) (st : SignedAction) :
    Decidable
      (∀ actor pk,
         st.action = .registerIdentity actor pk →
         es.registry[actor]? = none) := by
  generalize _h_eq : st.action = a
  cases a with
  | registerIdentity actor pk =>
    by_cases hcon : es.registry[actor]? = none
    · apply isTrue
      intro _ _ heq
      injection heq with hactor _
      subst hactor
      exact hcon
    · apply isFalse
      intro h
      exact hcon (h actor pk rfl)
  | _ => apply isTrue; intro _ _ heq; cases heq

/-- RB.1.c — Umbrella `Decidable` instance for `BridgeAdmissibleWith`.
    Composes the kernel-level `AdmissibleWith.decidable` with the
    two bridge-specific helpers above plus the bridge-only-signer
    conjunct, which is already decidable: `Action.isBridgeOnly` is
    `Bool`-valued (so the implication's antecedent `= true` is
    `Bool` equality) and `ActorId`'s structural `Eq` is decidable
    through its `UInt64` backing. -/
instance BridgeAdmissibleWith.decidable
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray)
    (es : ExtendedState) (st : SignedAction) :
    Decidable (BridgeAdmissibleWith verify P d es st) := by
  unfold BridgeAdmissibleWith
  haveI := AdmissibleWith.decidable verify P d es st
  exact inferInstance

/-! ## The replay function

`replay genesisState policy entries` re-runs each log entry against
the policy + initial state, producing the final state.  Returns an
`Except` so callers can distinguish success from per-step
diagnostics.

AR.2.4 / M-1 amendment.  The replay-tool entry points
(`replayStep` / `replayLoop` / `replay` / `replayFromSeed`)
threaded the admissibility check through the back-compat
`Admissible.decidable` alias (which fixes the deploymentId at
`ByteArray.empty`).  This is unsound for cross-deployment auditing:
a log signed under deployment `d₁` would be accepted by a replay
tool checking under any other deployment.

The `*With` family below is the resource-aware entry: each function
takes the deploymentId explicitly and routes through
`AdmissibleWith.decidable verify P d`.  The legacy non-`With`
versions remain as in-tree helpers (used by tests that operate at
the empty deploymentId), but the `knomosis-replay` audit binary
(`Replay.lean` at the repository root) uses `replayWith` and
refuses to start without an explicit `--deployment-id` flag. -/

/-- Internal step (parameterised): apply one log entry to the
    current replay state, producing the next state.  Same
    semantics as `replayStep`, with the `verify` function and
    deploymentId threaded explicitly so cross-deployment-replay
    rejection becomes a first-class property.

    RB.3 (2026-05-22, bridge-aware runtime admission gate):
    dispatches on `BridgeAdmissibleWith` (not the weaker
    `AdmissibleWith`) and applies via
    `apply_bridge_admissible_with_budget` so the bridge state
    (`bridge.consumed`, `bridge.pending`, `bridge.nextWdId`) is
    advanced atomically with the kernel state.  Replays of old
    logs that did NOT enforce the bridge conjuncts at production
    time may now reject at the admission step (e.g. duplicate
    `depositId`, re-registration of an existing actor,
    bridge-only action signed by a non-bridge actor); this is the
    intended security fix and is recorded in
    `docs/planning/unified_gas_pool_plan.md` §RB.  The
    `l2LogIndex` threaded into the bridge-state advance is the
    log-entry's own `idx`. -/
def replayStepWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray)
    (P : AuthorityPolicy) (state : ExtendedState) (prevHash : ContentHash)
    (e : LogEntry) (idx : Nat) :
    Except ReplayError ExtendedState :=
  -- 1. Chain check.
  if e.prevHash.toList ≠ prevHash.toList then
    .error (.chainBroken idx)
  else
    -- 2. Admissibility check (bridge-aware, RB.1 / RB.3).
    if h : BridgeAdmissibleWith verify P d state e.signedAction then
      -- 3. Bridge-aware admission + budget gate + bridge-state advance.
      match apply_bridge_admissible_with_budget verify P d state
              e.signedAction idx h with
      | some nextState =>
        -- 4. Post-state hash check.
        if (hashEncodable nextState).toList ≠ e.postStateHash.toList then
          .error (.postHashMismatch idx)
        else
          .ok nextState
      | none =>
        .error (.notAdmissible idx)
    else
      .error (.notAdmissible idx)

/-- Internal step: apply one log entry to the current replay state,
    producing the next state.

    Verifies (in order):
      1. The entry's `prevHash` matches the predecessor hash chain.
      2. The signed action is admissible at the current state.
      3. The recomputed post-state hash matches the recorded one.

    Each check fails fast with a precise diagnostic; the next
    check only runs if the previous succeeded.  This ordering
    matters: a chain-broken entry should never reach the
    admissibility check (it might be a forgery designed to provoke
    an admissibility-side-effect). -/
def replayStep
    (P : AuthorityPolicy) (state : ExtendedState) (prevHash : ContentHash)
    (e : LogEntry) (idx : Nat) :
    Except ReplayError ExtendedState :=
  replayStepWith Verify ByteArray.empty P state prevHash e idx

/-- Internal recursive replay (parameterised). -/
def replayLoopWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray)
    (P : AuthorityPolicy) :
    Nat → ContentHash → ExtendedState → List LogEntry →
    Except ReplayError ExtendedState
  | _idx, _prevHash, state, []      => .ok state
  | idx,  prevHash,  state, e :: rest =>
    match replayStepWith verify d P state prevHash e idx with
    | .ok state'  => replayLoopWith verify d P (idx + 1) (LogEntry.hash e) state' rest
    | .error err  => .error err

/-- Internal recursive replay: walk through the entries in order,
    threading the running state and predecessor hash. -/
def replayLoop
    (P : AuthorityPolicy) :
    Nat → ContentHash → ExtendedState → List LogEntry →
    Except ReplayError ExtendedState :=
  replayLoopWith Verify ByteArray.empty P

/-- AR.2.4 — replay the log against the genesis state under policy
    `P` and deploymentId `d`.  Returns the final `ExtendedState`
    on success.  On error, the diagnostic carries the index where
    replay failed and the failure type.  This is the
    auditor-binary entry point: `knomosis-replay` calls it with the
    operator-supplied `--deployment-id` flag.

    The starting predecessor hash is `zeroHash`: the first log
    entry's `prevHash` field must be `zeroHash` for a fresh
    deployment.  If the deployment started from a snapshot, the
    caller passes the snapshot's seed hash via `replayFromSeedWith`. -/
def replayWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray)
    (P : AuthorityPolicy) (genesis : ExtendedState) (entries : List LogEntry) :
    Except ReplayError ExtendedState :=
  replayLoopWith verify d P 0 zeroHash genesis entries

/-- Replay the log against the genesis state under policy `P`.

    Returns the final `ExtendedState` on success.  On error, the
    diagnostic carries the index where replay failed (counted from
    0) and the failure type.

    The starting predecessor hash is `zeroHash`: the first log
    entry's `prevHash` field must be `zeroHash` for a fresh
    deployment.  If the deployment started from a snapshot, the
    caller passes the snapshot's seed hash via `replayFromSeed`
    below.

    AR.2.4: kept for back-compat with test harnesses that operate
    at the empty deploymentId; `knomosis-replay` (the audit binary)
    uses `replayWith` directly. -/
def replay
    (P : AuthorityPolicy) (genesis : ExtendedState) (entries : List LogEntry) :
    Except ReplayError ExtendedState :=
  replayWith Verify ByteArray.empty P genesis entries

/-- AR.2.4 — parameterised seed-replay.  Like `replayWith` but
    starts from a non-genesis `(seedHash, seedState)`.  Used by
    the snapshot-bootstrap path when an attestor-supplied snapshot
    is in play. -/
def replayFromSeedWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray)
    (P : AuthorityPolicy) (seedHash : ContentHash) (seedState : ExtendedState)
    (entries : List LogEntry) :
    Except ReplayError ExtendedState :=
  replayLoopWith verify d P 0 seedHash seedState entries

/-- Like `replay`, but starts from a non-genesis seed hash and state.
    Used by the snapshot tool (WU 5.12): a replica restored from a
    snapshot resumes replay at the snapshot's `(seedHash, state)`
    rather than from genesis.  AR.2.4 back-compat alias. -/
def replayFromSeed
    (P : AuthorityPolicy) (seedHash : ContentHash) (seedState : ExtendedState)
    (entries : List LogEntry) :
    Except ReplayError ExtendedState :=
  replayFromSeedWith Verify ByteArray.empty P seedHash seedState entries

/-! ## Hash-only replay

Sometimes the auditor only cares about the final `StateHash`
(matching the runtime's recorded hash), not the full state.  This
wrapper packages the `replay >>= hashEncodable` composition so the
caller doesn't have to assemble it. -/

/-- Replay that returns just the final `StateHash`.  Equivalent to
    `(replay …).map hashEncodable`.  Used by the WU 5.5 binary's
    primary output mode (the auditor sees only the hex hash, not
    the underlying `ExtendedState`). -/
def replayHash
    (P : AuthorityPolicy) (genesis : ExtendedState) (entries : List LogEntry) :
    Except ReplayError ContentHash :=
  match replay P genesis entries with
  | .ok finalState => .ok (hashEncodable finalState)
  | .error e       => .error e

/-! ## Determinism (the §8.7 / §10.4 acceptance gate)

`replay` is a pure Lean function: same inputs → same output.  This
is what allows an auditor running the replay tool on a separate
machine (or at a separate time) to reproduce the runtime's
`StateHash` byte-for-byte. -/

/-- Determinism: equal inputs produce equal replay results. -/
theorem replay_deterministic
    (P : AuthorityPolicy)
    (genesis₁ genesis₂ : ExtendedState)
    (entries₁ entries₂ : List LogEntry)
    (h_g : genesis₁ = genesis₂) (h_e : entries₁ = entries₂) :
    replay P genesis₁ entries₁ = replay P genesis₂ entries₂ := by
  rw [h_g, h_e]

/-- Empty-log replay returns the genesis state.  Trivial but
    documents the acceptance condition for a fresh deployment. -/
theorem replay_empty (P : AuthorityPolicy) (genesis : ExtendedState) :
    replay P genesis [] = .ok genesis := rfl

end Runtime
end LegalKernel

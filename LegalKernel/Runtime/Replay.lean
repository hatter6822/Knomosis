/-
  Canon  - A Societal Kernel
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

/-! ## The replay function

`replay genesisState policy entries` re-runs each log entry against
the policy + initial state, producing the final state.  Returns an
`Except` so callers can distinguish success from per-step
diagnostics. -/

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
  -- 1. Chain check.
  if e.prevHash.toList ≠ prevHash.toList then
    .error (.chainBroken idx)
  else
    -- 2. Admissibility check.
    if h : Admissible P state e.signedAction then
      let nextState := apply_admissible P state e.signedAction h
      -- 3. Post-state hash check.
      if (hashEncodable nextState).toList ≠ e.postStateHash.toList then
        .error (.postHashMismatch idx)
      else
        .ok nextState
    else
      .error (.notAdmissible idx)

/-- Internal recursive replay: walk through the entries in order,
    threading the running state and predecessor hash. -/
def replayLoop
    (P : AuthorityPolicy) :
    Nat → ContentHash → ExtendedState → List LogEntry →
    Except ReplayError ExtendedState
  | _idx, _prevHash, state, []      => .ok state
  | idx,  prevHash,  state, e :: rest =>
    match replayStep P state prevHash e idx with
    | .ok state'  => replayLoop P (idx + 1) (LogEntry.hash e) state' rest
    | .error err  => .error err

/-- Replay the log against the genesis state under policy `P`.

    Returns the final `ExtendedState` on success.  On error, the
    diagnostic carries the index where replay failed (counted from
    0) and the failure type.

    The starting predecessor hash is `zeroHash`: the first log
    entry's `prevHash` field must be `zeroHash` for a fresh
    deployment.  If the deployment started from a snapshot, the
    caller passes the snapshot's seed hash via `replayFromSeed`
    below. -/
def replay
    (P : AuthorityPolicy) (genesis : ExtendedState) (entries : List LogEntry) :
    Except ReplayError ExtendedState :=
  replayLoop P 0 zeroHash genesis entries

/-- Like `replay`, but starts from a non-genesis seed hash and state.
    Used by the snapshot tool (WU 5.12): a replica restored from a
    snapshot resumes replay at the snapshot's `(seedHash, state)`
    rather than from genesis. -/
def replayFromSeed
    (P : AuthorityPolicy) (seedHash : ContentHash) (seedState : ExtendedState)
    (entries : List LogEntry) :
    Except ReplayError ExtendedState :=
  replayLoop P 0 seedHash seedState entries

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

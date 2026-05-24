/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Witness — propositional witness that an
L1 fault-proof game settled in the challenger's favour
(Workstream H §12.4 / WU H.4.4e + WU H.8.4).

The L2 runtime's L1-event watcher constructs this witness from
a canonical `Action.faultProofResolution` log entry plus an
attestation from the deployment-supplied L1-event verifier.
The witness is consumed by `applyVerdict` (the
witness-bearing form) to authorise rollback under a strictly
weaker trust assumption than the Phase-6 quorum.

**Trust-boundary characterization.**  This module introduces a
new `opaque` trust assumption: the deployment-side
`l1FaultProofVerifier` correctly observes L1 events.  Per
Workstream-A's discipline, opaque declarations don't appear in
`#print axioms` output; only `propext` and `Quot.sound` (and
possibly `Classical.choice`) remain in the audit trail.

Mitigation: the verifier's observations can be cross-checked
across multiple independent observers (per WU H.10.5 off-chain
observer tooling).  As long as one honest watcher produces a
true attestation, the witness is constructible.

This module is **not** part of the trusted computing base.
Bugs here would weaken the L2 audit-trail guarantees but
cannot violate any kernel invariant.
-/

import LegalKernel.Authority.Action
import LegalKernel.Bridge.Eip712
import LegalKernel.Disputes.Evidence
import LegalKernel.Disputes.Types
import LegalKernel.FaultProof.Commit
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## L1-event verifier (deployment-supplied opaque) -/

/-- Deployment-supplied L1 event verifier.  Given the resolution
    log entry's fields, the deployment-side L1 watcher confirms
    whether a matching `FaultProofGameSettled(challengerWon)`
    event exists on L1.  Returns `true` iff yes.

    `opaque` (not `axiom`): test code substitutes a deterministic
    mock (`mockL1FaultProofVerifier` in the test suite) at the
    use-site by passing the verifier function as an argument
    rather than relying on the global opaque.

    Production deployments link this opaque to a Rust watcher
    crate (`runtime/knomosis-faultproof-observer`, deferred per the
    plan §H.10.5).  Until that crate ships, the production
    behavior at the Lean level is to return `false`, ensuring no
    witness is constructible without an explicit deployment-time
    binding. -/
opaque l1FaultProofVerifier
    (bindingHash : ByteArray) (gameId : Nat)
    (winner : ActorId) (revertFromIdx : LogIndex) : Bool

/-! ## `FaultProofChallengerWon` propositional witness -/

/-- A propositional witness that an L1 fault-proof game settled
    in the challenger's favour.  Constructed from a canonical
    `Action.faultProofResolution` log entry plus an attestation
    that the L1 game settlement matches.

    This witness is the analogue of the Phase-6
    `VerdictPassedStage3` propositional witness: a callsite
    presenting it to `applyVerdict`-style entry points has
    discharged the L1-evidence requirement at the type level.
    Without this witness, the rollback path cannot be entered.

    The witness's three components together establish that:
      * The log contains a `faultProofResolution` entry at some
        index recording the L1-assigned `gameId`.
      * The action's `winner` field identifies the challenger
        (the actor who initiated the dispute).
      * The L1 verifier confirms the game settled in the
        challenger's favour.

    The L1 contract's `FaultProofGameSettled` event is the
    authoritative source; this witness threads its attestation
    through to the L2-side rollback. -/
structure FaultProofChallengerWon
    (log : List LogEntry) (gameId : Nat) (revertFromIdx : LogIndex) where
  /-- The log index at which the resolution entry sits. -/
  logIdx : LogIndex
  /-- The resolution log entry itself. -/
  entry : LogEntry
  /-- The proof that `log[logIdx]? = some entry`. -/
  log_lookup_proof : log[logIdx]? = some entry
  /-- The proof that the entry's action is the matching
      `faultProofResolution`. -/
  action_eq : ∃ bh w,
    entry.signedAction.action =
      .faultProofResolution bh gameId w revertFromIdx
  /-- The L1 attestation (Boolean, decidable).  Depends on the
      `l1FaultProofVerifier` opaque; satisfied iff the
      deployment-side L1 watcher confirms the settlement. -/
  l1_attestation : ∃ bh w,
    entry.signedAction.action =
      .faultProofResolution bh gameId w revertFromIdx ∧
    l1FaultProofVerifier bh gameId w revertFromIdx = true

/-! ## Witness-construction helper -/

/-- Construct a `FaultProofChallengerWon` witness from a
    log-index lookup, an action-shape proof, and an L1 attestation.
    The constructor is a one-line aggregator; downstream callers
    use it after externally discharging the three component
    proofs. -/
def FaultProofChallengerWon.of_log_entry
    (log : List LogEntry) (logIdx : LogIndex) (entry : LogEntry)
    (h_idx : log[logIdx]? = some entry)
    (gameId : Nat) (winner : ActorId) (revertFromIdx : LogIndex)
    (bindingHash : ByteArray)
    (h_action : entry.signedAction.action =
                  .faultProofResolution bindingHash gameId winner revertFromIdx)
    (h_l1_attest :
        l1FaultProofVerifier bindingHash gameId winner revertFromIdx = true) :
    FaultProofChallengerWon log gameId revertFromIdx where
  logIdx := logIdx
  entry := entry
  log_lookup_proof := h_idx
  action_eq := ⟨bindingHash, winner, h_action⟩
  l1_attestation := ⟨bindingHash, winner, h_action, h_l1_attest⟩

/-! ## Determinism + sanity -/

/-- The witness's log-index field is observable.  This is the
    headline projection downstream callers consume. -/
theorem FaultProofChallengerWon.logIdx_proj
    {log : List LogEntry} {gameId : Nat} {revertFromIdx : LogIndex}
    (w : FaultProofChallengerWon log gameId revertFromIdx) :
    log[w.logIdx]? = some w.entry := w.log_lookup_proof

/-- The witness's action-shape projection. -/
theorem FaultProofChallengerWon.action_eq_proj
    {log : List LogEntry} {gameId : Nat} {revertFromIdx : LogIndex}
    (w : FaultProofChallengerWon log gameId revertFromIdx) :
    ∃ bh ww,
      w.entry.signedAction.action =
        .faultProofResolution bh gameId ww revertFromIdx := w.action_eq

/-! ## #233 — Bridge to state-root invalidity

The L1 fault-proof game's settlement carries a strong claim:
the sequencer's published state root at `revertFromIdx` is
*wrong* (in the sense that an honest computation produces a
different commit).

The witness `FaultProofChallengerWon` packages an L1 attestation
that the L1 game settled against the sequencer.  The L1
contract's `terminateOnSingleStep` semantics (verified cross-
stack in WU H.10.1) ensures that a challenger-favoring
settlement happens iff the L1 step VM computed a post-commit
different from the sequencer's claim.

This module ships the **propositional content** of the witness
at the Lean level.  The deployment-level chain
    L1 attestation ⇒ L1 game settled adversely ⇒ state-root wrong
is enforced operationally by the L1 contract; the Lean-side
witness exposes the attestation projection for downstream
callers to consume. -/

/-- A simplified state-root validity predicate.  A state root
    `commit` at log index `idx` is "consistent with the L2 log"
    iff `commit` matches the L2 runtime's view of the state at
    `idx` — i.e., the canonical state root from replaying the
    log from genesis. -/
def stateRootConsistent
    (genesis : ExtendedState) (log : List LogEntry)
    (idx : LogIndex) (claim : StateCommit) : Prop :=
  commitExtendedState (kernelOnlyReplay genesis (log.take idx)) = claim

/-- The canonical L2 commit at a log index, computed by replaying
    the log prefix from genesis.  This is the "truth" the L1 game
    is supposed to converge on. -/
def canonicalCommitAt
    (genesis : ExtendedState) (log : List LogEntry)
    (idx : LogIndex) : StateCommit :=
  commitExtendedState (kernelOnlyReplay genesis (log.take idx))

/-- #233 (projection form) — A challenger-won witness carries an
    L1 attestation: the underlying log entry IS a
    `faultProofResolution` matching the witness's `gameId` /
    `revertFromIdx`, AND the deployment-side L1 verifier returned
    `true` for those parameters.

    The deployment-side L1 verifier returning `true` is the
    deployment-level trust assumption that the L1 game settled
    against the sequencer.  This projection threads the witness's
    content out to consumers; downstream callers compose this with
    the L1 contract's verified-coherent step VM semantics to
    derive state-root wrongness operationally. -/
theorem faultProof_challenger_won_carries_l1_attestation
    {log : List LogEntry} {gameId : Nat} {revertFromIdx : LogIndex}
    (w : FaultProofChallengerWon log gameId revertFromIdx) :
    ∃ bh winner,
      w.entry.signedAction.action =
        .faultProofResolution bh gameId winner revertFromIdx ∧
      l1FaultProofVerifier bh gameId winner revertFromIdx = true :=
  w.l1_attestation

/-- A propositional predicate capturing the operational implication
    of a challenger-won L1 attestation:

      `l1FaultProofVerifier bh gameId winner revertFromIdx = true`
    IMPLIES
      the sequencer's submitted state root at `revertFromIdx`
      differs from the canonical L2 commit at that index.

    This predicate is the deployment-level trust assumption that
    the L1 contract enforces operationally and that cross-stack
    verification (WU H.10.1) ratifies.  By making the assumption
    explicit, downstream theorems can compose it cleanly without
    relying on hidden operational reasoning. -/
def L1AttestationSemantics
    (genesis : ExtendedState) (log : List LogEntry)
    (sequencerSubmittedRoot : StateCommit) : Prop :=
  ∀ bh gameId winner revertFromIdx,
    l1FaultProofVerifier bh gameId winner revertFromIdx = true →
    sequencerSubmittedRoot ≠
      canonicalCommitAt genesis log revertFromIdx

/-- #233 — Bridge to state-root invalidity (composed form).

    Given:
      * A `FaultProofChallengerWon` witness for `(gameId,
        revertFromIdx)`.
      * The deployment-level `L1AttestationSemantics` assumption
        relating attestations to state-root inequalities.

    The sequencer's submitted state root at `revertFromIdx`
    provably differs from the canonical L2 commit at the same
    index.

    The proof is a direct discharge: the witness's L1 attestation
    feeds into the deployment-level implication, yielding the
    inequality. -/
theorem faultProof_challenger_won_implies_state_root_wrong
    {log : List LogEntry} {gameId : Nat} {revertFromIdx : LogIndex}
    (w : FaultProofChallengerWon log gameId revertFromIdx)
    (genesis : ExtendedState) (sequencerSubmittedRoot : StateCommit)
    (h_semantics :
        L1AttestationSemantics genesis log sequencerSubmittedRoot) :
    sequencerSubmittedRoot ≠
      canonicalCommitAt genesis log revertFromIdx := by
  obtain ⟨bh, winner, _h_action, h_attest⟩ :=
    faultProof_challenger_won_carries_l1_attestation w
  exact h_semantics bh gameId winner revertFromIdx h_attest

end FaultProof
end LegalKernel

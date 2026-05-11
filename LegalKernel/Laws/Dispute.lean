/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Laws.Lex.Dispute — Lex (LX.27) re-expression of the
four §8.4 dispute-pipeline action constructors.

M2-milestone Lex declarations for `dispute` (action index 8),
`disputeWithdraw` (index 9), `verdict` (index 10), and `rollback`
(index 11).  Each is a kernel-level no-op (`Laws.freezeResource 0`)
at the `Transition` level; the observable effect lives in the
dispute-pipeline modules under `LegalKernel/Disputes/`.

The M2 declarations capture the *kernel-level* shape only.  The
higher-level dispute semantics (filing a dispute, withdrawing it,
applying a verdict, recording a rollback) are out of scope for
M2's `lex_law` declarations — they live in the dispute-pipeline
runtime modules and are unaffected by the Lex re-expression.

See `LegalKernel/Laws/Transfer.lean`'s docstring for the "Why a
separate file?" explanation.  (After the LX-M2 in-place
migration, the Lex re-expressions of hand-written laws live
alongside their hand-written form in the same `Laws/*.lean`
file, rather than in a separate `Laws/Lex/` subdirectory.)
-/

import LegalKernel.Laws.Freeze
import LegalKernel.Disputes.Types
import Lex.DSL.Law

namespace LegalKernel
namespace Laws

open LegalKernel.Disputes

/-! ## `dispute` (frozen action index 8) -/

set_option linter.missingDocs false in
lexlaw legalkernel_dispute where
  lex_id              legalkernel.dispute
  lex_version         "1.0.0"
  lex_action_index    8
  lex_intent          "File a dispute against a prior log entry (Phase 6 §8.4).  The dispute carries the challenger's claim plus the standard nonce + signature replay-protection envelope.  Kernel-level effect is the identity on `State`; the dispute pipeline (`fileDispute`, `checkEvidence`) reads the dispute's data from the log without mutating state."
  lex_signed_by       challenger
  lex_authorized_by   (fun _ _ => True)
  lex_params          (_d : LegalKernel.Disputes.Dispute)
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  -- Per plan §19.4 LX.27: dispute-pipeline laws are kernel-level
  -- identity, so they trivially satisfy all kernel-level
  -- properties (conservative, monotonic, local, freeze_preserving,
  -- nonce_advances, registry_preserving).  The dispute pipeline's
  -- observable effects (verdict-driven rollback, dispute filing)
  -- live OUTSIDE `apply_admissible` — they don't show up at the
  -- kernel-Transition level.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  -- Per plan §19.4 LX.27: this law's events block should emit
  -- `Event.disputeFiled` per filing.  The full events-block
  -- elaborator (`do emit Event.disputeFiled ...` form) is M3
  -- work; the actual run-time emission is currently hard-coded
  -- in `actionEvents` in `Events/Extract.lean`.  M2 leaves this
  -- as `[]` (informational placeholder) so the JSON sidecar
  -- records the empty-events shape; M3's canonical-mode codegen
  -- will populate this from a dedicated events-calculus DSL.
  lex_events          := []

/-- LX.27 byte-equivalence regression for `dispute`. -/
example (d : Disputes.Dispute) :
    legalkernel_dispute_transition d =
    Laws.freezeResource 0 := rfl

/-! ## `disputeWithdraw` (frozen action index 9) -/

set_option linter.missingDocs false in
lexlaw legalkernel_disputeWithdraw where
  lex_id              legalkernel.disputeWithdraw
  lex_version         "1.0.0"
  lex_action_index    9
  lex_intent          "Withdraw a previously-filed dispute by referencing its log index (Phase 6 §8.4 / WU 6.11).  Idempotent: filing `disputeWithdraw idx` against an already-decided or already-withdrawn dispute is a no-op at the kernel level."
  lex_signed_by       challenger
  lex_authorized_by   (fun _ _ => True)
  lex_params          (_idx : LegalKernel.Disputes.LogIndex)
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  -- Per plan §19.4 LX.27: dispute-pipeline laws are kernel-level
  -- identity, so they trivially satisfy all kernel-level
  -- properties (conservative, monotonic, local, freeze_preserving,
  -- nonce_advances, registry_preserving).  The dispute pipeline's
  -- observable effects (verdict-driven rollback, dispute filing)
  -- live OUTSIDE `apply_admissible` — they don't show up at the
  -- kernel-Transition level.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- LX.27 byte-equivalence regression for `disputeWithdraw`. -/
example (idx : Disputes.LogIndex) :
    legalkernel_disputeWithdraw_transition idx =
    Laws.freezeResource 0 := rfl

/-! ## `verdict` (frozen action index 10) -/

set_option linter.missingDocs false in
lexlaw legalkernel_verdict where
  lex_id              legalkernel.verdict
  lex_version         "1.0.0"
  lex_action_index    10
  lex_intent          "Apply a quorum-signed verdict (Phase 6 §8.4 / WU 6.9).  The verdict references the dispute log entry's index; if upheld, the runtime layer's `applyVerdict` performs the rollback computation by replaying `log[0..idx-1]`.  Kernel-level effect is identity on `State`; the rollback semantics live in the runtime layer."
  lex_signed_by       adjudicator
  lex_authorized_by   (fun _ _ => True)
  lex_params          (_v : LegalKernel.Disputes.Verdict)
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  -- Per plan §19.4 LX.27: dispute-pipeline laws are kernel-level
  -- identity, so they trivially satisfy all kernel-level
  -- properties (conservative, monotonic, local, freeze_preserving,
  -- nonce_advances, registry_preserving).  The dispute pipeline's
  -- observable effects (verdict-driven rollback, dispute filing)
  -- live OUTSIDE `apply_admissible` — they don't show up at the
  -- kernel-Transition level.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- LX.27 byte-equivalence regression for `verdict`. -/
example (v : Disputes.Verdict) :
    legalkernel_verdict_transition v =
    Laws.freezeResource 0 := rfl

/-! ## `rollback` (frozen action index 11) -/

set_option linter.missingDocs false in
lexlaw legalkernel_rollback where
  lex_id              legalkernel.rollback
  lex_version         "1.0.0"
  lex_action_index    11
  lex_intent          "A rollback marker recording that the runtime restored state to the replay-target of `log[0..targetIdx-1]` after an upheld verdict (Phase 6 §8.4 / WU 6.10).  Kernel-level effect on `State` is identity; the runtime layer maintains a separate `rolledBackTo : Option LogIndex` field for replay.  The action exists primarily for audit-trail readability."
  lex_signed_by       adjudicator
  lex_authorized_by   (fun _ _ => True)
  lex_params          (_targetIdx : LegalKernel.Disputes.LogIndex)
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  -- Per plan §19.4 LX.27: dispute-pipeline laws are kernel-level
  -- identity, so they trivially satisfy all kernel-level
  -- properties (conservative, monotonic, local, freeze_preserving,
  -- nonce_advances, registry_preserving).  The dispute pipeline's
  -- observable effects (verdict-driven rollback, dispute filing)
  -- live OUTSIDE `apply_admissible` — they don't show up at the
  -- kernel-Transition level.
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, nonce_advances,
                          registry_preserving]
  lex_events          := []

/-- LX.27 byte-equivalence regression for `rollback`. -/
example (targetIdx : Disputes.LogIndex) :
    legalkernel_rollback_transition targetIdx =
    Laws.freezeResource 0 := rfl

end Laws
end LegalKernel

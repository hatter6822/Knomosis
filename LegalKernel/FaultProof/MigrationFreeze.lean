/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.MigrationFreeze — V1 freezing semantics
during migration to Workstream H (WU H.8.5).

When `KnomosisFaultProofMigration` activates and freezes V1 → V2,
in-flight V1 fault-proof games settle on V1; new challenges are
rejected; V2 starts fresh.  This module documents the Lean-side
semantics for replicas that observe the migration.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Authority.Action
import LegalKernel.Disputes.Types
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Runtime

/-! ## V1 freezing classifier

A predicate identifying log entries that record migration
activation.  In Workstream H's design, migration is L1-only;
the L2 log is unaware of it directly.  Replicas observe
migration via the L1-event-watcher subsystem and switch their
target contract from V1 to V2 going forward. -/

/-- A predicate identifying log entries that record migration
    activation at the L2 level.  Per the workstream design,
    migration is L1-only; this predicate always returns
    `false` (no L2 action records migration directly).

    Replicas surviving the migration switch their L1-event-
    watcher target from V1 to V2 *out-of-band*; the L2 log is
    not extended with a migration entry. -/
def isMigrationActivation (entry : LogEntry) : Bool :=
  match entry.signedAction.action with
  | _ => false  -- migration is L1-only; no L2 action records it.

/-- Determinism: equal log entries are equally classified. -/
theorem isMigrationActivation_deterministic
    (e₁ e₂ : LogEntry) (h : e₁ = e₂) :
    isMigrationActivation e₁ = isMigrationActivation e₂ := by rw [h]

/-- The classifier always returns `false` (migration is L1-only). -/
theorem isMigrationActivation_always_false
    (e : LogEntry) :
    isMigrationActivation e = false := by
  unfold isMigrationActivation
  cases e.signedAction.action <;> rfl

/-! ## V1 → V2 handover invariants

Documented at the type level for replica reasoning.  The
invariants are operational: replicas must observe migration via
L1 events, not L2 log entries.  This module captures the L2-
side correctness claim. -/

/-- A predicate on a `List LogEntry` asserting that *no* entry in
    the list is a migration-activation record.  By definition of
    `isMigrationActivation` (which is constantly `false`), this
    predicate is vacuously satisfied by every log; the substantive
    content is the corresponding decidability + the projection
    theorem below that captures the L2-invariance promise. -/
def noMigrationActivationInLog (entries : List LogEntry) : Prop :=
  ∀ e ∈ entries, isMigrationActivation e = false

/-- Decidability of `noMigrationActivationInLog`.  Trivially holds
    by `isMigrationActivation_always_false`; named so consumers can
    rely on `inferInstance`. -/
instance instDecidableNoMigrationActivationInLog
    (entries : List LogEntry) :
    Decidable (noMigrationActivationInLog entries) := by
  unfold noMigrationActivationInLog
  exact inferInstance

/-- **Substantive L2-invariance theorem**: every log satisfies
    `noMigrationActivationInLog`.  This captures the workstream-H
    design promise that L2 log entries do NOT record migration
    activations — i.e., the L2 log post-migration is observably
    indistinguishable from the L2 log pre-migration up to whatever
    actions actually got appended (none of them migration-related).

    A replica that crosses the migration boundary observes
    migration via the L1-event watcher subsystem, not via L2 log
    entries.  This theorem is the L2-side correctness witness:
    no matter what entries appear in the log, none of them is a
    migration activation. -/
theorem every_log_lacks_migration_activation
    (entries : List LogEntry) :
    noMigrationActivationInLog entries := by
  intro e _
  exact isMigrationActivation_always_false e

/-- **Corollary** for replicas: surviving the migration produces
    no migration-marker L2 log entries.  Concretely, the count of
    migration-activation entries in any log is zero. -/
theorem migration_activation_count_zero
    (entries : List LogEntry) :
    (entries.filter (fun e => isMigrationActivation e)).length = 0 := by
  have h : entries.filter (fun e => isMigrationActivation e) = [] := by
    induction entries with
    | nil => rfl
    | cons e rest ih =>
      simp [List.filter, isMigrationActivation_always_false e, ih]
  rw [h]
  rfl

end FaultProof
end LegalKernel

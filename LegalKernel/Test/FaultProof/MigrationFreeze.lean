/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.MigrationFreeze — value-level tests for
the V1 → V2 migration-freeze semantics (Workstream H WU H.8.5).

Exercises:
  * `isMigrationActivation` always-false invariant.
  * `noMigrationActivationInLog` predicate.
  * `every_log_lacks_migration_activation` substantive theorem.
  * `migration_activation_count_zero` corollary.
-/

import LegalKernel.FaultProof.MigrationFreeze
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.MigrationFreeze

/-- A trivial signed action used in test log entries. -/
private def trivialSignedAction : SignedAction :=
  { action := .freezeResource 0
  , signer := 1
  , nonce  := 0
  , sig    := ByteArray.empty }

/-- A trivial log entry. -/
private def trivialLogEntry : LogEntry :=
  { prevHash       := ByteArray.empty
  , signedAction   := trivialSignedAction
  , postStateHash  := ByteArray.empty }

/-- A second trivial log entry with a different signer. -/
private def trivialLogEntry₂ : LogEntry :=
  { prevHash       := ByteArray.empty
  , signedAction   :=
      { action := .freezeResource 0
      , signer := 42
      , nonce  := 0
      , sig    := ByteArray.empty }
  , postStateHash  := ByteArray.empty }

/-- Tests for the migration-freeze semantics. -/
def tests : List TestCase :=
  [ -- ===== isMigrationActivation always returns false =====
    { name := "isMigrationActivation returns false on a generic entry"
    , body := do
        let result := isMigrationActivation trivialLogEntry
        assertEq (expected := false) (actual := result)
          "no L2 action records migration"
    }
  , { name := "isMigrationActivation returns false on every constructor"
    , body := do
        -- The classifier is by definition `_ => false`.  Verify
        -- that across all action constructors, the result is false.
        for action in [
          (Action.transfer 1 2 3 100 : Action),
          .mint 1 2 100,
          .burn 1 2 100,
          .freezeResource 1,
          .replaceKey 1 ByteArray.empty,
          .reward 1 2 100,
          .rollback 0,
          .registerIdentity 1 ByteArray.empty
        ] do
          let entry : LogEntry :=
            { prevHash       := ByteArray.empty
            , signedAction   :=
                { action := action
                , signer := 1
                , nonce  := 0
                , sig    := ByteArray.empty }
            , postStateHash  := ByteArray.empty }
          assertEq (expected := false)
                   (actual := isMigrationActivation entry)
                   s!"action constructor produces no migration marker"
    }
  , -- ===== noMigrationActivationInLog is universally true =====
    { name := "noMigrationActivationInLog on empty log"
    , body := do
        let result := decide (noMigrationActivationInLog [])
        assert result "empty log satisfies vacuously"
    }
  , { name := "noMigrationActivationInLog on 3-element log"
    , body := do
        let log := [trivialLogEntry, trivialLogEntry₂, trivialLogEntry]
        let result := decide (noMigrationActivationInLog log)
        assert result "every log satisfies"
    }
  , -- ===== Substantive theorem: every_log_lacks_migration_activation =====
    { name := "every_log_lacks_migration_activation is universally provable"
    , body := do
        let log := [trivialLogEntry, trivialLogEntry₂]
        let _ := every_log_lacks_migration_activation log
        assert true "theorem applicable to any log"
    }
  , -- ===== Corollary: migration_activation_count_zero =====
    { name := "migration_activation_count_zero on empty log"
    , body := do
        let log : List LogEntry := []
        let n := (log.filter (fun e => isMigrationActivation e)).length
        assertEq (expected := 0) (actual := n)
          "empty log filters to length 0"
    }
  , { name := "migration_activation_count_zero on 5-element log"
    , body := do
        let log := [trivialLogEntry, trivialLogEntry₂,
                    trivialLogEntry, trivialLogEntry₂, trivialLogEntry]
        let n := (log.filter (fun e => isMigrationActivation e)).length
        assertEq (expected := 0) (actual := n)
          "5-element log filters to length 0"
    }
  , -- ===== Decidability =====
    { name := "instDecidableNoMigrationActivationInLog synthesises"
    , body := do
        let log := [trivialLogEntry]
        let _ := instDecidableNoMigrationActivationInLog log
        assert true "decidable instance present"
    }
  ]

end LegalKernel.Test.FaultProof.MigrationFreeze

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.LawClassification — runtime tests for the
Phase-6 incentive-integration amendment's dispute-action
classification.

Exercises:

  * The four `_compileTransition_eq_freezeResource_zero` lemmas as
    `rfl` checks.
  * Typeclass resolution for the eight `IsConservative` /
    `IsMonotonic` instances.
  * Term-level API stability for the composite summary theorem.
-/

import LegalKernel.Disputes.LawClassification
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.LawClassificationTests

/-! ## Test fixtures -/

/-- A trivial Dispute fixture for the typeclass-resolution probes. -/
def fixtureDispute : Dispute :=
  { challenger := 1
    claim      := .preconditionFalse 0
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- A trivial Verdict fixture. -/
def fixtureVerdict : Verdict :=
  { disputeId := 0, outcome := .upheld
    rationale := ⟨#[]⟩, signatures := [] }

/-! ## `_compileTransition_eq_freezeResource_zero` API stability -/

/-- Sub-suite: identification lemmas. -/
def identificationLemmaTests : List TestCase :=
  [ { name := "dispute_compileTransition_eq_freezeResource_zero rfl"
    , body := do
        let _proof : Action.compileTransition (.dispute fixtureDispute) =
                     Laws.freezeResource 0 :=
          dispute_compileTransition_eq_freezeResource_zero fixtureDispute
        pure ()
    }
  , { name := "disputeWithdraw_compileTransition_eq_freezeResource_zero rfl"
    , body := do
        let _proof : Action.compileTransition (.disputeWithdraw 5) =
                     Laws.freezeResource 0 :=
          disputeWithdraw_compileTransition_eq_freezeResource_zero 5
        pure ()
    }
  , { name := "verdict_compileTransition_eq_freezeResource_zero rfl"
    , body := do
        let _proof : Action.compileTransition (.verdict fixtureVerdict) =
                     Laws.freezeResource 0 :=
          verdict_compileTransition_eq_freezeResource_zero fixtureVerdict
        pure ()
    }
  , { name := "rollback_compileTransition_eq_freezeResource_zero rfl"
    , body := do
        let _proof : Action.compileTransition (.rollback 7) =
                     Laws.freezeResource 0 :=
          rollback_compileTransition_eq_freezeResource_zero 7
        pure ()
    }
  ]

/-! ## Typeclass-resolution checks

Each test below confirms that `inferInstance` resolves the
`IsConservative` and `IsMonotonic` instances for the four dispute
action constructors. -/

/-- Sub-suite: typeclass resolution. -/
def typeclassResolutionTests : List TestCase :=
  [ { name := "IsConservative resolves for .dispute"
    , body := do
        let _ : IsConservative (Action.compileTransition (.dispute fixtureDispute)) :=
          inferInstance
        pure ()
    }
  , { name := "IsConservative resolves for .disputeWithdraw"
    , body := do
        let _ : IsConservative (Action.compileTransition (.disputeWithdraw 0)) :=
          inferInstance
        pure ()
    }
  , { name := "IsConservative resolves for .verdict"
    , body := do
        let _ : IsConservative (Action.compileTransition (.verdict fixtureVerdict)) :=
          inferInstance
        pure ()
    }
  , { name := "IsConservative resolves for .rollback"
    , body := do
        let _ : IsConservative (Action.compileTransition (.rollback 0)) :=
          inferInstance
        pure ()
    }
  , { name := "IsMonotonic resolves for .dispute"
    , body := do
        let _ : IsMonotonic (Action.compileTransition (.dispute fixtureDispute)) :=
          inferInstance
        pure ()
    }
  , { name := "IsMonotonic resolves for .disputeWithdraw"
    , body := do
        let _ : IsMonotonic (Action.compileTransition (.disputeWithdraw 0)) :=
          inferInstance
        pure ()
    }
  , { name := "IsMonotonic resolves for .verdict"
    , body := do
        let _ : IsMonotonic (Action.compileTransition (.verdict fixtureVerdict)) :=
          inferInstance
        pure ()
    }
  , { name := "IsMonotonic resolves for .rollback"
    , body := do
        let _ : IsMonotonic (Action.compileTransition (.rollback 0)) :=
          inferInstance
        pure ()
    }
  ]

/-! ## Composite summary API stability -/

/-- Sub-suite: composite summary. -/
def compositeSummaryTests : List TestCase :=
  [ { name := "dispute_pipeline_actions_classification API stability"
    , body := do
        let _proof :
            (∀ d : Dispute,    IsConservative (Action.compileTransition (.dispute d))) ∧
            (∀ idx : LogIndex, IsConservative (Action.compileTransition (.disputeWithdraw idx))) ∧
            (∀ v : Verdict,    IsConservative (Action.compileTransition (.verdict v))) ∧
            (∀ idx : LogIndex, IsConservative (Action.compileTransition (.rollback idx))) ∧
            (∀ d : Dispute,    IsMonotonic    (Action.compileTransition (.dispute d))) ∧
            (∀ idx : LogIndex, IsMonotonic    (Action.compileTransition (.disputeWithdraw idx))) ∧
            (∀ v : Verdict,    IsMonotonic    (Action.compileTransition (.verdict v))) ∧
            (∀ idx : LogIndex, IsMonotonic    (Action.compileTransition (.rollback idx))) :=
          dispute_pipeline_actions_classification
        pure ()
    }
  ]

/-! ## Aggregate -/

/-- All Phase-6 incentive-integration law-classification tests. -/
def tests : List TestCase :=
  identificationLemmaTests ++ typeclassResolutionTests ++ compositeSummaryTests

end LegalKernel.Test.Disputes.LawClassificationTests

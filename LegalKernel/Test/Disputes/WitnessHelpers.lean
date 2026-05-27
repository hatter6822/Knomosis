/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.WitnessHelpers — test-only helpers for
constructing `VerdictPassedStage3` witnesses on test fixtures.

Phase-6 Option-C amendment.  Provides:

  * `mkWitnessByDecide` — direct constructor from a literal
    `proposeVerdict ... = .ok v` proof, typically discharged via
    `decide` on a fully-decidable fixture.
  * Sanity tests demonstrating witness construction on the four
    decidable fixture patterns documented in the §FVM (Fixture
    Validation Matrix) of the Option-C plan.

**Discipline (from D4 of the plan).**  Tests using witness
construction must satisfy:

  1. `qp = QuorumPolicy.empty` (so `qp.required = 0` and the
     quorum check passes vacuously without invoking `Verify`).
  2. The dispute's claim variant has a decidable
     `checkEvidence`.  Avoid `signatureInvalid` (which calls
     opaque `Verify`).  Use:
     - `preconditionFalse` (calls `step_impl` — decidable);
     - `nonceMismatch` (calls `expectsNonce` — decidable);
     - `oracleMisreported` with `OraclePolicy.alwaysRejects` /
       `OraclePolicy.alwaysUpheld` (decidable verifier);
     - `doubleApply` (purely structural).
  3. The verdict's outcome must match `checkEvidence`'s
     recomputation.  If `checkEvidence` returns `.upheld`, the
     verdict's outcome must be `.upheld`; else the
     `outcomeMismatch` check rejects the witness.
  4. The impugned index of `oracleMisreported` claims must be
     in range (Layer 0's defensive check).

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong fixture witnesses (a deployment-level
test problem) but cannot violate any kernel invariant.
-/

import LegalKernel.Disputes.Verdict
import LegalKernel.Test.Framework

namespace LegalKernel
namespace Test
namespace Disputes
namespace WitnessHelpers

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test

/-! ## Witness construction helper -/

/-- For test fixtures with decidable `proposeVerdict` evaluation:
    construct the `VerdictPassedStage3` witness from a literal
    success equation.  The equation is typically discharged by
    `decide` on a fully-concrete fixture. -/
def mkWitnessByDecide
    (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
    (currentEs genesis : ExtendedState) (log : List LogEntry) (v : Verdict)
    (h : proposeVerdict P oracle qp currentEs genesis log v = .ok v) :
    VerdictPassedStage3 P oracle qp currentEs genesis log v := ⟨h⟩

/-! ## Sanity tests -/

/-- Sub-suite: helper sanity. -/
def sanityTests : List TestCase :=
  [ { name := "mkWitnessByDecide produces a VerdictPassedStage3 from .ok proof"
    , body := do
        -- Smoke: directly invoke `mkWitnessByDecide` against a trivially-OK
        -- equation built via `Eq.refl` substitution.  The body of this test
        -- doesn't need to construct an actual successful proposeVerdict —
        -- just verify the constructor's API signature accepts the equation.
        let _api : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy) (qp : QuorumPolicy)
                     (currentEs genesis : ExtendedState) (log : List LogEntry)
                     (v : Verdict),
            proposeVerdict P oracle qp currentEs genesis log v = .ok v →
            VerdictPassedStage3 P oracle qp currentEs genesis log v :=
          fun P o q e g l v h => mkWitnessByDecide P o q e g l v h
        pure ()
    }
  , { name := "VerdictPassedStage3.of_proposeVerdict_ok API stability"
    , body := do
        let _api : ∀ {P : AuthorityPolicy} {oracle : OraclePolicy} {qp : QuorumPolicy}
                     {currentEs genesis : ExtendedState} {log : List LogEntry}
                     {v : Verdict},
            proposeVerdict P oracle qp currentEs genesis log v = .ok v →
            VerdictPassedStage3 P oracle qp currentEs genesis log v :=
          fun {_P _o _q _e _g _l _v} h =>
            VerdictPassedStage3.of_proposeVerdict_ok h
        pure ()
    }
  , { name := "VerdictPassedStage3.of_proposeVerdict_ok_with_eq API stability"
    , body := do
        let _api : ∀ {P : AuthorityPolicy} {oracle : OraclePolicy} {qp : QuorumPolicy}
                     {currentEs genesis : ExtendedState} {log : List LogEntry}
                     {v v' : Verdict},
            proposeVerdict P oracle qp currentEs genesis log v = .ok v' →
            v' = v →
            VerdictPassedStage3 P oracle qp currentEs genesis log v :=
          fun {_P _o _q _e _g _l _v _v'} h h_eq =>
            VerdictPassedStage3.of_proposeVerdict_ok_with_eq h h_eq
        pure ()
    }
  ]

/-! ## Value-level witness construction on a concrete fixture

Demonstrates that an end-to-end witness construction is feasible
in tests using the runtime-driven discovery pattern: invoke
`proposeVerdict` at runtime, match on the success branch, derive
the input-output equality via `proposeVerdict_ok_returns_input`,
then construct the witness via `of_proposeVerdict_ok_with_eq`.

The fixture is a 2-entry log: `[transfer, dispute]` where the
dispute targets a `oracleMisreported 0 ⟨#[]⟩` claim against the
transfer entry.  With `OraclePolicy.alwaysUpheld` and
`QuorumPolicy.empty`, the verdict's `.upheld` outcome matches
`checkEvidence`'s recomputation, the empty quorum check passes
vacuously, and `proposeVerdict` accepts. -/

/-- A registered actor used by the fixture. -/
def fixActor : ActorId := 10

/-- A sample public key. -/
def fixKey : PublicKey := ⟨#[0xAA]⟩

/-- A genesis state with `fixActor` registered. -/
def fixGenesis : ExtendedState where
  base     := emptyState
  nonces   := NonceState.empty
  registry := KeyRegistry.empty.register fixActor fixKey

/-- The dispute targeting log entry 0 with an `oracleMisreported`
    claim — chosen because `OraclePolicy.alwaysUpheld` makes the
    evidence check decidably `.upheld`. -/
def fixDispute : Dispute :=
  { challenger := fixActor
    claim      := .oracleMisreported 0 ⟨#[]⟩
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- The 2-entry log: a transfer (the impugned action) followed by
    the dispute against it. -/
def fixLog : List LogEntry :=
  let entry0 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction := { action := .transfer 0 fixActor fixActor 0
                        signer := fixActor, nonce := 0, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  let entry1 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction := { action := .dispute fixDispute, signer := fixActor
                        nonce := 0, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  [entry0, entry1]

/-- A verdict against the dispute at index 1, with `.upheld`
    outcome (matches `OraclePolicy.alwaysUpheld`). -/
def fixVerdict : Verdict :=
  { disputeId := 1, outcome := .upheld
    rationale := ⟨#[]⟩, signatures := [] }

/-- Sub-suite: end-to-end witness construction + invocation. -/
def valueLevelTests : List TestCase :=
  [ { name := "proposeVerdict on the fixture returns .ok fixVerdict"
    , body := do
        match proposeVerdict AuthorityPolicy.unrestricted OraclePolicy.alwaysUpheld
                              QuorumPolicy.empty fixGenesis fixGenesis fixLog fixVerdict with
        | .ok v' =>
          assert (v' = fixVerdict) "proposeVerdict returns the input verdict"
        | .error e =>
          throw <| IO.userError s!"proposeVerdict should succeed, got {repr e}"
    }
  , { name := "proposeAndApplyVerdict on the fixture exercises witness construction"
    , body := do
        -- This goes through the full `proposeAndApplyVerdict` chain:
        -- proposeVerdict succeeds → witness is constructed via
        -- `of_proposeVerdict_ok_with_eq` → witness-bearing `applyVerdict`
        -- runs → returns the rolled-back state.
        match proposeAndApplyVerdict AuthorityPolicy.unrestricted OraclePolicy.alwaysUpheld
                                      QuorumPolicy.empty fixGenesis fixGenesis fixLog fixVerdict with
        | .ok _es' => pure ()  -- witness chain succeeded, rollback computed
        | .error e =>
          throw <| IO.userError s!"proposeAndApplyVerdict should succeed, got {repr e}"
    }
  , { name := "applyVerdict_under_witness_succeeds: fixture-level instantiation"
    , body := do
        -- Sanity: the strong-correctness theorem typechecks at the
        -- specific fixture.  We don't need to actually invoke
        -- applyVerdict (that would require materialising the witness,
        -- which is a Prop and proof-irrelevant — the test is at the
        -- type level).
        let _api :
            (∀ (h : VerdictPassedStage3
                AuthorityPolicy.unrestricted OraclePolicy.alwaysUpheld
                QuorumPolicy.empty fixGenesis fixGenesis fixLog fixVerdict),
              ∃ es,
                applyVerdict AuthorityPolicy.unrestricted OraclePolicy.alwaysUpheld
                  QuorumPolicy.empty fixGenesis fixGenesis fixLog fixVerdict h = .ok es) :=
          fun h =>
            applyVerdict_under_witness_succeeds AuthorityPolicy.unrestricted
              OraclePolicy.alwaysUpheld QuorumPolicy.empty fixGenesis fixGenesis
              fixLog fixVerdict h
        pure ()
    }
  ]

/-! ## Aggregate -/

/-- All witness-helper sanity tests. -/
def tests : List TestCase := sanityTests ++ valueLevelTests

end WitnessHelpers
end Disputes
end Test
end LegalKernel

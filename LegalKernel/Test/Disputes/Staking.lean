/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.Staking — runtime tests for the Phase-6
incentive-integration amendment's anti-fraud staking infrastructure.

Exercises:

  * `StakingPolicy.canStake` predicate.
  * `stakeFilingActions` (filing-time emission) + disabled
    short-circuit.
  * `stakeResolutionActions` (resolution-time emission) — per-D1
    upheld returns no actions, rejected/inconclusive emits
    treasury transfer.
  * `fileDisputeStaked` wrapper (sufficient stake → ok;
    insufficient → error; underlying filing error propagation).
  * Sanity theorems on emit-only-transfers + monotonicity.
-/

import LegalKernel.Disputes.Staking
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.StakingTests

/-! ## Test fixtures -/

/-- A non-trivial staking policy: 30 stake units in resource 0,
    escrow actor 99, treasury actor 100. -/
def fixturePolicy : StakingPolicy where
  stakeResource := 0
  stakeAmount   := 30
  escrowActor   := 99
  treasuryActor := 100

/-- Test challenger. -/
def challenger1 : ActorId := 1

/-- A funded ExtendedState with `challenger1` holding 100 in
    resource 0. -/
def fundedEs : ExtendedState where
  base     := setBalance emptyState 0 challenger1 100
  nonces   := NonceState.empty
  registry := KeyRegistry.empty.register challenger1 ⟨#[0xAA]⟩

/-- A poor ExtendedState (challenger1 has only 10). -/
def poorEs : ExtendedState where
  base     := setBalance emptyState 0 challenger1 10
  nonces   := NonceState.empty
  registry := KeyRegistry.empty.register challenger1 ⟨#[0xAA]⟩

/-- A trivial dispute fixture by `challenger1`. -/
def fixtureDispute : Dispute :=
  { challenger := challenger1
    claim      := .preconditionFalse 0
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- A minimal log fixture (one entry, so disputeIdx 0 is in range). -/
def fixtureLog : List LogEntry :=
  [{ prevHash := ⟨#[]⟩
     signedAction := { action := .transfer 0 1 2 0
                       signer := 1, nonce := 0, sig := ⟨#[]⟩ }
     postStateHash := ⟨#[]⟩ }]

/-- A trivial verdict fixture. -/
def upheldVerdict : Verdict :=
  { disputeId := 0, outcome := .upheld
    rationale := ⟨#[]⟩, signatures := [] }

/-- A rejected variant of `upheldVerdict`, for the per-D1
    "stake forfeit" branch. -/
def rejectedVerdict : Verdict :=
  { upheldVerdict with outcome := .rejected }

/-- An inconclusive variant of `upheldVerdict`. -/
def inconclusiveVerdict : Verdict :=
  { upheldVerdict with outcome := .inconclusive }

/-! ## canStake predicate -/

/-- Sub-suite: canStake. -/
def canStakeTests : List TestCase :=
  [ { name := "canStake: funded challenger passes"
    , body := do
        assert (fixturePolicy.canStake fundedEs challenger1)
          "funded challenger should pass canStake"
    }
  , { name := "canStake: underfunded challenger fails"
    , body := do
        -- poorEs has 10, policy requires 30.
        assert (! fixturePolicy.canStake poorEs challenger1)
          "underfunded should fail canStake"
    }
  , { name := "canStake: disabled policy always passes"
    , body := do
        assert (StakingPolicy.disabled.canStake poorEs challenger1)
          "disabled policy should always pass"
    }
  ]

/-! ## stakeFilingActions -/

/-- Sub-suite: stakeFilingActions. -/
def stakeFilingTests : List TestCase :=
  [ { name := "stakeFilingActions: enabled emits 1 transfer"
    , body := do
        let actions := stakeFilingActions fixturePolicy challenger1
        assertEq (1 : Nat) actions.length "filing emits 1 action"
    }
  , { name := "stakeFilingActions: disabled emits no actions"
    , body := do
        let actions := stakeFilingActions StakingPolicy.disabled challenger1
        assertEq (0 : Nat) actions.length "disabled emits []"
    }
  , { name := "stakeFilingActions: emits a transfer to escrow"
    , body := do
        let actions := stakeFilingActions fixturePolicy challenger1
        match actions with
        | [Action.transfer r s r' amt] =>
          assert (r = fixturePolicy.stakeResource) "stake resource"
          assert (s = challenger1) "sender = challenger"
          assert (r' = fixturePolicy.escrowActor) "receiver = escrow"
          assert (amt = fixturePolicy.stakeAmount) "amount = stakeAmount"
        | _ => throw <| IO.userError s!"unexpected actions: {repr actions}"
    }
  , { name := "stakeFilingActions_emits_only_transfers API stability"
    , body := do
        let _proof : ∀ (sp : StakingPolicy) (challenger : ActorId),
            ∀ a ∈ stakeFilingActions sp challenger,
              ∃ r s r' amt, a = Action.transfer r s r' amt :=
          fun sp ch => stakeFilingActions_emits_only_transfers sp ch
        pure ()
    }
  ]

/-! ## stakeResolutionActions (per D1 of the plan) -/

/-- Sub-suite: stakeResolutionActions. -/
def stakeResolutionTests : List TestCase :=
  [ { name := "stakeResolutionActions: upheld emits no actions (D1)"
    , body := do
        let actions := stakeResolutionActions fixturePolicy upheldVerdict
        assertEq (0 : Nat) actions.length "upheld → []"
    }
  , { name := "stakeResolutionActions: rejected emits treasury transfer"
    , body := do
        let actions := stakeResolutionActions fixturePolicy rejectedVerdict
        match actions with
        | [Action.transfer r s r' amt] =>
          assert (r = fixturePolicy.stakeResource) "stake resource"
          assert (s = fixturePolicy.escrowActor) "sender = escrow"
          assert (r' = fixturePolicy.treasuryActor) "receiver = treasury"
          assert (amt = fixturePolicy.stakeAmount) "amount = stakeAmount"
        | _ => throw <| IO.userError s!"unexpected actions: {repr actions}"
    }
  , { name := "stakeResolutionActions: inconclusive emits treasury transfer"
    , body := do
        let actions := stakeResolutionActions fixturePolicy inconclusiveVerdict
        assertEq (1 : Nat) actions.length "inconclusive emits 1"
    }
  , { name := "stakeResolutionActions: disabled emits no actions"
    , body := do
        let actions := stakeResolutionActions StakingPolicy.disabled rejectedVerdict
        assertEq (0 : Nat) actions.length "disabled emits []"
    }
  , { name := "stakeResolutionActions_upheld_no_actions API stability"
    , body := do
        let _proof : ∀ (sp : StakingPolicy) (v : Verdict),
            v.outcome = .upheld → stakeResolutionActions sp v = [] :=
          fun sp v h => stakeResolutionActions_upheld_no_actions sp v h
        pure ()
    }
  ]

/-! ## fileDisputeStaked -/

/-- Sub-suite: fileDisputeStaked. -/
def fileDisputeStakedTests : List TestCase :=
  [ { name := "fileDisputeStaked: sufficient stake → ok + 1 staking action"
    , body := do
        match fileDisputeStaked fixturePolicy fundedEs fixtureLog fixtureDispute with
        | .ok (rec, actions) =>
          assert (rec.dispute.challenger = challenger1) "challenger preserved"
          assertEq (1 : Nat) actions.length "1 staking action"
        | .error e => throw <| IO.userError s!"expected .ok, got .error {repr e}"
    }
  , { name := "fileDisputeStaked: insufficient stake → error"
    , body := do
        match fileDisputeStaked fixturePolicy poorEs fixtureLog fixtureDispute with
        | .error (.insufficientStake have_ need) =>
          assertEq (10 : Amount) have_ "have_ = 10"
          assertEq (30 : Amount) need "need = 30"
        | other => throw <| IO.userError s!"expected insufficientStake, got {repr other}"
    }
  , { name := "fileDisputeStaked: disabled policy → ok + no staking action"
    , body := do
        match fileDisputeStaked StakingPolicy.disabled fundedEs fixtureLog
                                fixtureDispute with
        | .ok (_, actions) => assertEq (0 : Nat) actions.length "no staking action"
        | .error e => throw <| IO.userError s!"unexpected {repr e}"
    }
  , { name := "fileDisputeStaked: filing-error propagation"
    , body := do
        -- fileDispute will reject on out-of-range claim.  fixtureLog
        -- has 1 entry, so disputeIdx=99 is out of range; sufficient
        -- stake should still be checked first per the design.
        let badDispute : Dispute :=
          { fixtureDispute with claim := .preconditionFalse 99 }
        match fileDisputeStaked fixturePolicy fundedEs fixtureLog badDispute with
        | .error (.filing (.indexOutOfRange _ _)) => pure ()
        | other => throw <| IO.userError s!"expected filing.indexOutOfRange, got {repr other}"
    }
  , { name := "fileDisputeStaked_rejects_underfunded API stability"
    , body := do
        let _proof : ∀ (sp : StakingPolicy) (es : ExtendedState)
                       (_log : List LogEntry) (d : Dispute),
            sp.canStake es d.challenger = false →
            fileDisputeStaked sp es _log d =
            .error (.insufficientStake
                      (getBalance es.base sp.stakeResource d.challenger)
                      sp.stakeAmount) :=
          fun sp es _log d h =>
            fileDisputeStaked_rejects_underfunded sp es _log d h
        pure ()
    }
  ]

/-! ## Aggregate -/

/-- All Phase-6 incentive-integration staking tests. -/
def tests : List TestCase :=
  canStakeTests ++ stakeFilingTests ++ stakeResolutionTests ++ fileDisputeStakedTests

end LegalKernel.Test.Disputes.StakingTests

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Trust — API stability tests for the
Workstream-H trust-model upgrade composite theorems
(`#232 / #233 / #257 / #266`).
-/

import LegalKernel.FaultProof.Trust
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Trust

/-- A `truth` function pinned at every index to a fixed
    32-byte commit (used as fixture in the API-stability tests). -/
private def constantTruth : LogIndex → StateCommit :=
  fun _ => ByteArray.empty

/-- A `truth` function returning a 1-byte commit at index 5 and
    empty otherwise (asymmetric fixture). -/
private def asymmetricTruth : LogIndex → StateCommit :=
  fun idx => if idx = 5 then ByteArray.mk #[0xAB] else ByteArray.empty

/-- A trivial `gs₀` for term-level checks. -/
private def trivialGameState : LegalKernel.FaultProof.GameState := {
  sequencer       := 1,
  challenger      := 2,
  range           := { low  := { idx := 0, commit := ByteArray.empty },
                       high := { idx := 0, commit := ByteArray.empty } },
  pendingMidpoint := none,
  depth           := 0,
  turn            := .sequencer,
  sequencerBond   := 1_000,
  challengerBond  := 50,
  status          := .inProgress,
  deploymentId    := ByteArray.empty,
  actionsRoot     := ByteArray.empty
}

/-- A `gs` with disagreement between the high commit and
    `asymmetricTruth` at index 5. -/
private def disagreeingGameState : LegalKernel.FaultProof.GameState := {
  sequencer       := 1,
  challenger      := 2,
  range           := { low  := { idx := 0, commit := ByteArray.empty },
                       high := { idx := 5, commit := ByteArray.mk #[0xCD] } },
  pendingMidpoint := none,
  depth           := 0,
  turn            := .sequencer,
  sequencerBond   := 1_000,
  challengerBond  := 50,
  status          := .inProgress,
  deploymentId    := ByteArray.empty,
  actionsRoot     := ByteArray.empty
}

/-- API-stability tests for the trust-model upgrade composite
    theorems. -/
def tests : List TestCase :=
  [ { name := "#266: terminal_disagreement_implies_sequencer_claim_wrong API stable"
    , body := do
        let _api : ∀ truth gs,
                    inDisagreementWithTruth truth gs →
                    gs.range.high.commit ≠ truth gs.range.high.idx :=
          terminal_disagreement_implies_sequencer_claim_wrong
        assert true "API exists"
    }
  , { name := "#266: sequencer_high_truthful_breaks_disagreement API stable"
    , body := do
        let _api : ∀ truth gs,
                    gs.range.high.commit = truth gs.range.high.idx →
                    ¬ inDisagreementWithTruth truth gs :=
          sequencer_high_truthful_breaks_disagreement
        assert true "API exists"
    }
  , { name := "honesty hypothesis is satisfiable (not vacuous)"
    , body := do
        -- The point of `HonestResponseTrace`.  The predicate it
        -- replaced quantified honesty over EVERY transition
        -- applicable at a node; since both `respondAgree` and
        -- `respondDisagree` apply at any in-progress node with a
        -- pending midpoint, it demanded `mp.commit = truth mp.idx`
        -- and `mp.commit ≠ truth mp.idx` for the same `mp` — so the
        -- theorems carrying it were vacuously true.  Exhibit an
        -- inhabitant rather than assume one exists.
        let _witness : ∀ (truth : LogIndex → StateCommit)
            (gs : LegalKernel.FaultProof.GameState),
            HonestResponseTrace truth gs 0 gs :=
          honestResponseTrace_refl_exists
        -- And an honest trace really does erase to a response trace,
        -- so the narrowing results still apply to it.
        let _erase : ∀ {truth : LogIndex → StateCommit}
            {gs₀ gs_k : LegalKernel.FaultProof.GameState} {k : Nat},
            HonestResponseTrace truth gs₀ k gs_k → ResponseTrace gs₀ k gs_k :=
          HonestResponseTrace.toResponseTrace
        pure ()
    }
  , { name := "#256: disagreement_persists_along_trace takes an HONEST trace"
    , body := do
        -- Pin the signature: the honesty obligation must live in the
        -- trace, not in a separate universally-quantified hypothesis.
        let _proof : ∀ (truth : LogIndex → StateCommit)
            (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat),
            HonestResponseTrace truth gs₀ k gs_k →
            inDisagreementWithTruth truth gs₀ →
            inDisagreementWithTruth truth gs_k :=
          disagreement_persists_along_trace
        pure ()
    }
  , { name := "#257: single_honest_challenger_narrows_with_disagreement API stable"
    , body := do
        -- Just verify the function signature is callable; the
        -- conclusion type-checks.
        let _name :
            ∀ (truth : LogIndex → StateCommit)
              (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
              (h_trace : HonestResponseTrace truth gs₀ k gs_k)
              (h_disagree₀ : inDisagreementWithTruth truth gs₀)
              (h_k : k ≥ gs₀.range.high.idx - gs₀.range.low.idx),
              inDisagreementWithTruth truth gs_k ∧
              gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 :=
          single_honest_challenger_narrows_with_disagreement
        assert true "API exists"
    }
  , { name := "#232: trust_model_upgrade_composite API stable"
    , body := do
        let _name :
            ∀ (truth : LogIndex → StateCommit)
              (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
              (h_trace : HonestResponseTrace truth gs₀ k gs_k)
              (h_disagree₀ : inDisagreementWithTruth truth gs₀)
              (h_k : k ≥ gs₀.range.high.idx - gs₀.range.low.idx),
              -- The trifecta: disagreement persists, range narrows, and
              -- the sequencer's high-commit at termination is wrong.
              inDisagreementWithTruth truth gs_k ∧
              gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 ∧
              gs_k.range.high.commit ≠ truth gs_k.range.high.idx :=
          trust_model_upgrade_composite
        assert true "API exists"
    }
  , { name := "#233: state_root_invalidity_inequality API stable"
    , body := do
        let _api : ∀ (truth : LogIndex → StateCommit) (idx : LogIndex)
                     (claim : StateCommit),
                    claim ≠ truth idx → truth idx ≠ claim :=
          state_root_invalidity_inequality
        assert true "API exists"
    }
  , { name := "#233: disagreement_to_state_root_invalidity API stable"
    , body := do
        let _api : ∀ truth gs,
                    inDisagreementWithTruth truth gs →
                    truth gs.range.high.idx ≠ gs.range.high.commit :=
          disagreement_to_state_root_invalidity
        assert true "API exists"
    }
  , { name := "value-level: disagreement on disagreeingGameState"
    , body := do
        -- disagreeingGameState's high.commit is 0xCD; truth at 5 is 0xAB.
        -- So inDisagreementWithTruth holds vacuously on low and on high.
        -- low.idx = 0; truth 0 = empty; low.commit = empty.  ✓
        -- high.idx = 5; truth 5 = #[0xAB]; high.commit = #[0xCD].  ≠.  ✓
        let h_disagree : inDisagreementWithTruth asymmetricTruth disagreeingGameState := by
          refine ⟨?_, ?_⟩
          · -- low.commit = empty, truth 0 = empty.
            rfl
          · -- high.commit = #[0xCD] ≠ truth 5 = #[0xAB].
            decide
        -- terminal_disagreement_implies_sequencer_claim_wrong should fire.
        let h_wrong :=
          terminal_disagreement_implies_sequencer_claim_wrong
            asymmetricTruth disagreeingGameState h_disagree
        let _ := h_wrong
        assert true "value-level disagreement-to-wrong-claim works"
    }
  , { name := "value-level: trivialGameState has no disagreement (low = high)"
    , body := do
        -- Both low and high commit are empty; truth function constant.
        -- inDisagreement requires high.commit ≠ truth high.idx.
        -- truthfully, empty ≠ empty fails, so the invariant doesn't hold.
        -- We verify it via `decide`.
        let res := decide (inDisagreementWithTruth constantTruth trivialGameState)
        assertEq (expected := false) (actual := res)
          "trivialGameState has no disagreement against constantTruth"
    }
  ]

end LegalKernel.Test.FaultProof.Trust

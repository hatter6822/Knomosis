/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Observer — off-chain prover/observer
reference specification (Workstream H WU H.10.5 Lean side).

The Workstream-H plan §10.5 describes three off-chain tools the
challenger needs:

  * **State-root verifier** — given a Knomosis node + an L1
    state-root submission, recompute `commitExtendedState` and
    detect mismatches.
  * **Cell-proof generator** — given a state + cell-tag list,
    generate the corresponding `CellProof` bundle.
  * **Bisection-game player** — given an in-progress game +
    canonical truth, compute the next honest move.

The Rust observer crate (`runtime/knomosis-faultproof-observer`)
implements these as runtime adaptors.  This module is the
*Lean reference specification* — production observers are
expected to produce byte-identical results.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Disputes.Evidence
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Coherence
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.Strategy
import LegalKernel.FaultProof.Verify
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace FaultProof
namespace Observer

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## State-root verification -/

/-- Detect whether a sequencer's state-root submission is
    correct, given the runtime's canonical view.  Returns
    `true` iff the runtime detects a fault (sequencer's commit
    differs from the truthful commit at the claimed log
    index). -/
def detectFault
    (genesis : ExtendedState) (log : List LogEntry)
    (sequencerCommit : StateCommit) (logIndex : LogIndex) : Bool :=
  let truthCommit :=
    commitExtendedState (kernelOnlyReplay genesis (log.take logIndex))
  decide (truthCommit ≠ sequencerCommit)

/-- Determinism of `detectFault`. -/
theorem detectFault_deterministic
    (g₁ g₂ : ExtendedState) (l₁ l₂ : List LogEntry)
    (s₁ s₂ : StateCommit) (i₁ i₂ : LogIndex)
    (h_g : g₁ = g₂) (h_l : l₁ = l₂)
    (h_s : s₁ = s₂) (h_i : i₁ = i₂) :
    detectFault g₁ l₁ s₁ i₁ = detectFault g₂ l₂ s₂ i₂ := by
  rw [h_g, h_l, h_s, h_i]

/-! ## Cell-proof generation -/

/-- Build the cell-proof bundle for a given action's required
    cells from the runtime's `ExtendedState`.  Wraps
    `buildCellProof` over the `requiredCells` list. -/
def buildObserverCellProofs
    (es : ExtendedState) (action : Action) (signer : ActorId) :
    CellProofBundle :=
  { proofs := (Action.requiredCells action signer).map
                (fun t => buildCellProof es t) }

/-- The observer's bundle verifies against the state's commit
    by `verifyCellProofs_complete_for_canonical_bundle`. -/
theorem buildObserverCellProofs_verifies
    (es : ExtendedState) (action : Action) (signer : ActorId) :
    verifyCellProofs (commitExtendedState es)
      (buildObserverCellProofs es action signer) = true := by
  unfold buildObserverCellProofs
  exact verifyCellProofs_complete_for_canonical_bundle es _

/-! ## Honest-strategy game player -/

/-- Compute the next honest move in a game.  Wraps
    `honestStrategy` (Strategy.lean) with deployment-config-
    aware behaviour: uses the deployment's truth function +
    the player's identity. -/
def computeNextMove
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState) (me : TurnSide) :
    Option GameTransition :=
  honestStrategy truth gs me

/-- The computed move is the unique honest move (per
    `honest_strategy_unique`). -/
theorem computeNextMove_is_honest
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState) (me : TurnSide) :
    computeNextMove truth gs me = honestStrategy truth gs me := rfl

/-! ## Smoke checks -/

/-- The observer's cell-proof bundle has the expected size for
    a transfer action (4 cells: registry, balance×2, nonce). -/
example (es : ExtendedState) (s rcv : ActorId) (a : Amount) :
    (buildObserverCellProofs es (.transfer 1 s rcv a) s).proofs.length = 4 := by
  unfold buildObserverCellProofs
  simp [Action.requiredCells, Action.readOnlyCells, Action.writeCells]

end Observer
end FaultProof
end LegalKernel

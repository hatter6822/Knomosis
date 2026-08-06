-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.AxiomFootprint — the mechanical gate for CLAUDE.md's
"No custom axioms (ABSOLUTE)" convention.

**Why this module exists.**  The project states, in CLAUDE.md and in
eleven separate module docstrings, that `#print axioms` on every
kernel theorem returns a subset of `[propext, Classical.choice,
Quot.sound]` and that no custom axiom exists.  Six mechanical gates
ship alongside that claim — `count_sorries`, `tcb_audit`,
`stub_audit`, `naming_audit`, `deferral_audit`, `mock_import_audit` —
and **none of them checked it**.  The claim was true, but it was true
by inspection, re-established by hand on each audit pass.

`count_sorries` says so itself: "A full check would invoke Lean's
elaborator and inspect `sorryAx` axiom usage; the present tool catches
the common-case violations".  This module is that full check for the
headline surface.

**What it catches that the textual gates cannot.**

  * a custom `axiom` declaration reached transitively by a headline
    theorem — `count_sorries` and `stub_audit` scan for `sorry`-shaped
    text and for placeholder bodies, neither of which an `axiom` is;
  * a `sorry` in a spelling the four `count_sorries` patterns miss.
    Any `sorry`, however written, introduces `sorryAx` into the
    footprint, so the elaborator sees it whether or not the regex did;
  * a proof that silently acquires a dependency when a lemma it uses
    is rewritten.

**How it runs.**  `#assert_canonical_axioms` is a *command*, so the
check happens at elaboration time and a violation is a BUILD ERROR,
not a test failure.  CI's existing `lake build` therefore gates it
with no new workflow step, and the failure names the offending axiom
and the theorem that reached it.

**Scope.**  The list below is the headline-theorem table from
CLAUDE.md plus the TCB core.  It is deliberately a curated list rather
than "every theorem in the project": the guarantee the project makes
is about these, checking all ~2000 declarations would cost build time
for no added assurance, and a theorem important enough to name in the
table is important enough to pin here.
-/

import Lean.Elab.Command
import Lean.Util.CollectAxioms
import LegalKernel
import LegalKernel.Test.Framework

open Lean Elab Command

namespace LegalKernel.Test.AxiomFootprint

/-- The three axioms Lean's own logic supplies.  A dependency on any
    of these is expected; a dependency on anything else — a custom
    `axiom`, or `sorryAx` from a `sorry` — is a policy violation. -/
def canonicalAxioms : List Name :=
  [``propext, ``Classical.choice, ``Quot.sound]

/-- Assert that every constant named by the identifier depends only on
    `canonicalAxioms`.

    Fails elaboration — and therefore `lake build`, and therefore CI —
    naming both the rogue axiom and the declaration that reached it.
    A strict subset is fine and common: several settlement theorems
    depend only on `[propext, Quot.sound]`. -/
elab "#assert_canonical_axioms " id:ident : command => do
  let cs ← liftCoreM <| realizeGlobalConstWithInfos id
  for c in cs do
    let axs ← collectAxioms c
    let rogue := axs.filter (fun a => !canonicalAxioms.contains a)
    unless rogue.isEmpty do
      throwError
        "axiom-footprint violation: '{c}' depends on {rogue.toList}, \
         which is outside the canonical set {canonicalAxioms}.  \
         Adding a custom axiom is a Genesis-Plan amendment (CLAUDE.md, \
         \"No custom axioms (ABSOLUTE)\") and triggers the two-reviewer \
         gate.  If this is `sorryAx`, a `sorry` reached a headline \
         theorem in a spelling `count_sorries` does not match."

/-! ## TCB core (`Kernel.lean`) -/

#assert_canonical_axioms LegalKernel.impl_refines_spec
#assert_canonical_axioms LegalKernel.impl_noop_if_not_pre
#assert_canonical_axioms LegalKernel.invariant_preservation
#assert_canonical_axioms LegalKernel.invariants_compose
#assert_canonical_axioms LegalKernel.apply_certified_eq_step_impl
#assert_canonical_axioms LegalKernel.invariant_preservation_via_laws
#assert_canonical_axioms LegalKernel.total_supply_global

/-! ## Laws and conservation -/

#assert_canonical_axioms LegalKernel.Laws.transfer_conserves

/-! ## Authority: nonces, replay, compilation -/

#assert_canonical_axioms LegalKernel.Authority.nonce_uniqueness
#assert_canonical_axioms LegalKernel.Authority.replay_impossible
#assert_canonical_axioms LegalKernel.Authority.Action.compile_injective

/-! ## The C-3 amount ceiling -/

#assert_canonical_axioms LegalKernel.FaultProof.balancesBounded_apply_impl
#assert_canonical_axioms LegalKernel.FaultProof.canonicalBounds_base_amt_of_reachable
#assert_canonical_axioms LegalKernel.FaultProof.expectsNonce_le_of_reachableIn

/-! ## Fault proof: the published root and its injectivity -/

#assert_canonical_axioms LegalKernel.FaultProof.smtRootListAux_perm_of_eq_under_collision_free
#assert_canonical_axioms LegalKernel.FaultProof.commitExtendedState_determines_cells
#assert_canonical_axioms LegalKernel.FaultProof.smtUpdateRoot_proof_independent
#assert_canonical_axioms LegalKernel.FaultProof.updateStateCellRoot_eq_commit_of_canonical
#assert_canonical_axioms LegalKernel.FaultProof.commitExtendedState_eq_of_cells_agree

/-! ## Fault proof: the multiproof and the terminal step -/

#assert_canonical_axioms LegalKernel.FaultProof.multiWalk_eq_smtRootListAux
#assert_canonical_axioms LegalKernel.FaultProof.stepMultiFold_eq_commit_post
#assert_canonical_axioms LegalKernel.FaultProof.writeSetComplete_productionApplyBudget
#assert_canonical_axioms LegalKernel.FaultProof.expandMultiProof_buildMultiProof
#assert_canonical_axioms LegalKernel.FaultProof.pathSorted_frontierOf

/-! ## Fault proof: the game -/

#assert_canonical_axioms LegalKernel.FaultProof.bisection_converges_in_log_rounds
#assert_canonical_axioms LegalKernel.FaultProof.honest_challenger_wins_against_invalid_state_root
#assert_canonical_axioms LegalKernel.FaultProof.honest_challenger_wins_of_turn_aligned
#assert_canonical_axioms LegalKernel.FaultProof.turn_aligned_preserved
#assert_canonical_axioms LegalKernel.FaultProof.terminate_owner_is_sequencer

/-! ## Fault proof: the batch actions root (Workstream SB) -/

#assert_canonical_axioms LegalKernel.FaultProof.actionProof_canonical_walks_to_root
#assert_canonical_axioms LegalKernel.FaultProof.actionProof_no_value_substitution
#assert_canonical_axioms LegalKernel.FaultProof.actionProof_binds_action
#assert_canonical_axioms LegalKernel.FaultProof.actionLeafPreimage_inj
#assert_canonical_axioms LegalKernel.FaultProof.StepVMCoherence.uint64BE_inj

/-! ## The user-facing L2 swap (Workstream SB) -/

#assert_canonical_axioms LegalKernel.Laws.reserveSwap_no_reserve_drain
#assert_canonical_axioms LegalKernel.Laws.reserveSwap_k_nondecreasing
#assert_canonical_axioms LegalKernel.Laws.reserveSwap_conserves_from
#assert_canonical_axioms LegalKernel.Laws.reserveSwap_conserves_to
#assert_canonical_axioms LegalKernel.FaultProof.deriveReserveSwapBalances_correct

/-! ## Bridge and chain-level accounting -/

#assert_canonical_axioms LegalKernel.Bridge.bridge_chain_conserves
#assert_canonical_axioms LegalKernel.Bridge.bridgeReachable_solvent
#assert_canonical_axioms LegalKernel.Bridge.bridge_chain_accounting_equation
#assert_canonical_axioms LegalKernel.Bridge.receiptVerifiedClaim_capped_and_backed

/-! ## Encoding: the injectivity ladder -/

#assert_canonical_axioms LegalKernel.Encoding.cellTag_roundtrip

/-! ## Test-suite surface

The assertions above are the gate; they have already run by the time
this module finishes elaborating.  The single case below exists so
that a `lake test` transcript RECORDS that the gate is present — a
silent gate and an absent one look identical in the log, and this
project's audit history is largely a record of checks that were
believed to be running.

The gate's own negative controls cannot live here: a rogue `axiom` or
a `sorry` written to trip it would fail the build for real, which is
exactly what it is for.  They are exercised out-of-tree instead, and
both were confirmed to fail with the message above — one on a custom
`axiom`, one on a transitive `sorryAx` written as `first | sorry`, a
spelling `count_sorries`' four patterns do not match. -/

/-- The axiom-footprint gate's presence marker. -/
def tests : List LegalKernel.Test.TestCase :=
  [ { name := "axiom footprint: headline theorems gated at build time"
    , body := do
        LegalKernel.Test.assertEq
          (expected := 3) (actual := canonicalAxioms.length)
          "the canonical axiom set is propext / Classical.choice / Quot.sound"
    }
  ]

end LegalKernel.Test.AxiomFootprint

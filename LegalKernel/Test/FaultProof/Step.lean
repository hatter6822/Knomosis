-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Step — value-level tests for the
`KernelStep` type and `kernelStepApply` semantics.

These used to run on a hand-built step with an EMPTY opening bundle,
which the old `kernelStepApply` accepted (`verifyCellProofs` is
`List.all`, vacuously true on `[]`).  The verifier re-derives the cell
list and every one of the twenty-five variants writes the signer's
nonce and epoch budget, so an empty bundle now fails the shape check —
and a step has to be a REAL one, over a real state, to be applied at
all.  That is what makes the chain tests below thread genuine roots
rather than values the test put there itself.
-/

import LegalKernel.FaultProof.Step
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Step

/-- A populated state with a policy whose free tier admits a consume. -/
private def base : ExtendedState :=
  let st : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    ((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 9 25) }
  { base          := st
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , bridge        := { LegalKernel.Bridge.BridgeState.empty with nextWdId := 5 }
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 100 1 2 }

private def someSignedAction : SignedAction :=
  { action := .transfer 1 7 8 30, signer := 7, nonce := 3, sig := ByteArray.empty }

/-- The canonical step from `base`, and the state it advances to. -/
private def firstStep : KernelStep := buildKernelStep base someSignedAction 0

private def afterFirst : ExtendedState :=
  productionApplyBudget base someSignedAction 0

/-- ...and the step that follows it, from the state the first reaches. -/
private def secondStep : KernelStep :=
  buildKernelStep afterFirst
    { someSignedAction with nonce := 4 } 1

/-- Tests for the `KernelStep` data type and `kernelStepApply`. -/
def tests : List TestCase :=
  [ { name := "chainKernelStepApply on empty list returns initial commit"
    , body := do
        let c := commitExtendedState base
        match chainKernelStepApply c [] with
        | some c' => assertEq (expected := c.toList) (actual := c'.toList) "empty chain"
        | none    => assert false "empty chain returned none"
    }
  , { name := "kernelStepApply computes the canonical step's post-root"
    , body := do
        -- The step VM's whole job, on a real step.  It is `some`, and
        -- it is the root the honest sequencer publishes.
        match kernelStepApply firstStep with
        | none   => assert false "the canonical step must apply"
        | some c =>
          assertEq (expected := (commitExtendedState afterFirst).toList)
            (actual := c.toList)
            "kernelStepApply lands on the published post-root"
    }
  , { name := "kernelStepApply does NOT return the claim"
    , body := do
        -- The regression for the original vacuity: the body used to
        -- return `step.postStateCommit` verbatim, so a responder could
        -- carry any claim and win.  Feed it a step whose claim is
        -- nonsense and check the output ignores it.
        let lying : KernelStep := { firstStep with
          postStateCommit := ByteArray.mk (Array.replicate 32 (0xEE : UInt8)) }
        assertEq (expected := kernelStepApply firstStep |>.map ByteArray.toList)
          (actual := kernelStepApply lying |>.map ByteArray.toList)
          "the claim must not influence the computed root"
    }
  , { name := "an empty opening bundle is REFUSED"
    , body := do
        -- It used to verify vacuously.  Every variant writes the
        -- signer's nonce and epoch budget, so the re-derived cell list
        -- is never empty and a bundle that is fails the shape check.
        let empty : KernelStep := { firstStep with writeOpenings := [] }
        assertEq (expected := true) (actual := (kernelStepApply empty).isNone)
          "an empty bundle must not apply"
    }
  , { name := "kernelStepApply is deterministic"
    , body := do
        assertEq (expected := (kernelStepApply firstStep).map ByteArray.toList)
          (actual := (kernelStepApply firstStep).map ByteArray.toList)
          "determinism"
    }
  , { name := "chainKernelStepApply rejects mismatched preStateCommit"
    , body := do
        let mismatched : KernelStep := { firstStep with
          preStateCommit := ByteArray.mk (Array.replicate 32 (0x11 : UInt8)) }
        match chainKernelStepApply (commitExtendedState base) [mismatched] with
        | some _ => assert false "should reject mismatched preCommit"
        | none   => pure ()
    }
  , { name := "chainKernelStepApply threads the computed commit"
    , body := do
        -- Threading is real: the second step's `preStateCommit` must
        -- equal what the FIRST computed, not a value both steps happen
        -- to declare.  A chain of two identical steps does not verify
        -- — that is the point.
        match chainKernelStepApply (commitExtendedState base)
                [firstStep, secondStep] with
        | some c =>
          assertEq
            (expected := (commitExtendedState
              (productionApplyBudget afterFirst
                { someSignedAction with nonce := 4 } 1)).toList)
            (actual := c.toList)
            "two-step chain lands on the second advance's root"
        | none   => assert false "the honest two-step chain must verify"
        match chainKernelStepApply (commitExtendedState base)
                [firstStep, firstStep] with
        | some _ => assert false "a broken chain must not verify"
        | none   => pure ()
    }
  , { name := "chainKernelStepApply_split (concrete)"
    , body := do
        -- The split equation must hold on the SUCCEEDING path, which
        -- it could not be checked on while every step was a no-op.
        let steps := [firstStep, secondStep]
        let lhs := chainKernelStepApply (commitExtendedState base) steps
        let rhs :=
          (chainKernelStepApply (commitExtendedState base) [firstStep]).bind
            (fun c' => chainKernelStepApply c' [secondStep])
        assertEq (expected := lhs.map ByteArray.toList)
          (actual := rhs.map ByteArray.toList) "split equation holds"
    }
  , { name := "chainKernelStepApply_singleton_match (concrete)"
    , body := do
        let lhs := chainKernelStepApply (commitExtendedState base) [firstStep]
        let rhs := kernelStepApply firstStep
        assertEq (expected := lhs.map ByteArray.toList)
          (actual := rhs.map ByteArray.toList) "singleton match"
    }
  , { name := "API stability: kernelStepApply is the verifier"
    , body := do
        let _proof : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            kernelStepApply (buildKernelStep es st idx)
              = verifierPostRoot (commitExtendedState es) st.action st.signer idx
                  (policyOpening es) (stepOpenings es st idx) :=
          fun es st idx => kernelStepApply_canonical es st idx
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.Step

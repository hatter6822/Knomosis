/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Coherence — value-level tests for the
multi-step kernel-step chain coherence theorem (Workstream H
WU H.1.3d, theorem #253).

Exercises `foldStepApplyOverLog`, the per-step bridge to
`kernelOnlyApply`, and the chain-level coherence with
`kernelOnlyReplay`.
-/

import LegalKernel.FaultProof.Coherence
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Coherence

/-- A trivial signed action (freezeResource 0 — no-op at kernel
    level).  Used for shape tests. -/
private def trivialSignedAction : SignedAction :=
  { action := .freezeResource 0
  , signer := 1
  , nonce  := 0
  , sig    := ByteArray.empty }

/-- A trivial log entry wrapping the trivial signed action. -/
private def trivialLogEntry : LogEntry :=
  { prevHash       := ByteArray.empty
  , signedAction   := trivialSignedAction
  , postStateHash  := ByteArray.empty }

/-- Workstream GP fixture: a `depositWithFee` signed action with
    distinct recipient (10) and poolActor (99), under resource 1,
    crediting user 30 + pool 20 with a budget grant of 100,
    depositId 42.  Signed by `Bridge.bridgeActor` (= 0) per the
    admission gate's `depositWithFee_signerCheck`. -/
private def depositWithFeeSignedAction : SignedAction :=
  { action := .depositWithFee 1 10 99 30 20 100 42
  , signer := Bridge.bridgeActor
  , nonce  := 0
  , sig    := ByteArray.empty }

/-- Workstream GP fixture: a `topUpActionBudget` signed action
    transferring 15 units of gas-resource 2 from signer 50 to
    pool actor 99, with a budget increment of 30.  Signer (50)
    satisfies the admission gate's two-disjointness check:
    signer ≠ bridgeActor (= 0) AND signer ≠ poolActor (= 99). -/
private def topUpActionBudgetSignedAction : SignedAction :=
  { action := .topUpActionBudget 2 15 30 99
  , signer := 50
  , nonce  := 0
  , sig    := ByteArray.empty }

/-- Workstream GP: log entry wrapping the depositWithFee fixture. -/
private def depositWithFeeLogEntry : LogEntry :=
  { prevHash       := ByteArray.empty
  , signedAction   := depositWithFeeSignedAction
  , postStateHash  := ByteArray.empty }

/-- Workstream GP: log entry wrapping the topUpActionBudget fixture. -/
private def topUpActionBudgetLogEntry : LogEntry :=
  { prevHash       := ByteArray.empty
  , signedAction   := topUpActionBudgetSignedAction
  , postStateHash  := ByteArray.empty }

/-- Tests for the `foldStepApplyOverLog` chain function and its
    coherence with `kernelOnlyReplay`. -/
def tests : List TestCase :=
  [ -- ===== Reduction lemmas =====
    { name := "foldStepApplyOverLog on empty log is identity"
    , body := do
        let es := ExtendedState.empty
        let result := foldStepApplyOverLog es []
        -- `result = es` definitionally (per `foldStepApplyOverLog_nil`).
        let _ := foldStepApplyOverLog_nil es
        let _ := result
        assert true "empty log is identity by definition"
    }
  , { name := "foldStepApplyOverLog cons reduction is sequential"
    , body := do
        let es := ExtendedState.empty
        let e := trivialLogEntry
        let rest : List LogEntry := []
        -- foldStepApplyOverLog es (e :: rest) =
        --   foldStepApplyOverLog (applyCellWrites_to_state es e.sa) rest
        let _ := foldStepApplyOverLog_cons es e rest
        assert true "cons reduction holds by definition"
    }
  , -- ===== Per-step bridge =====
    { name := "applyCellWrites_to_state agrees with kernelOnlyApply"
    , body := do
        let es := ExtendedState.empty
        let entry := trivialLogEntry
        -- The theorem says the two are equal.
        let _ :=
          applyCellWrites_to_state_eq_kernelOnlyApply es entry
        assert true "per-step bridge theorem provable"
    }
  , -- ===== Value-level chain coherence =====
    { name := "foldStepApplyOverLog empty equals kernelOnlyReplay empty"
    , body := do
        let es := ExtendedState.empty
        let log : List LogEntry := []
        -- foldStepApplyOverLog es [] = es = kernelOnlyReplay es []
        -- via foldStepApplyOverLog_eq_kernelOnlyReplay.
        let lhs := foldStepApplyOverLog es log
        let rhs := kernelOnlyReplay es log
        -- We can't BEq ExtendedState directly, but commits are
        -- canonical 32-byte arrays.  Compare via commits.
        assertEq (expected := commitExtendedState rhs)
                 (actual := commitExtendedState lhs)
                 "empty-log chain coherence at commit level"
    }
  , { name := "foldStepApplyOverLog singleton equals kernelOnlyReplay singleton"
    , body := do
        let es := ExtendedState.empty
        let log := [trivialLogEntry]
        let lhs := foldStepApplyOverLog es log
        let rhs := kernelOnlyReplay es log
        assertEq (expected := commitExtendedState rhs)
                 (actual := commitExtendedState lhs)
                 "singleton-log chain coherence at commit level"
    }
  , { name := "foldStepApplyOverLog 3-element chain equals kernelOnlyReplay"
    , body := do
        let es := ExtendedState.empty
        let log := [trivialLogEntry, trivialLogEntry, trivialLogEntry]
        let lhs := foldStepApplyOverLog es log
        let rhs := kernelOnlyReplay es log
        assertEq (expected := commitExtendedState rhs)
                 (actual := commitExtendedState lhs)
                 "3-element chain coherence at commit level"
    }
  , -- ===== Commit-level chain coherence theorem =====
    { name := "recomputeCommitment_chain_coherent_with_kernelOnlyReplay API stable"
    , body := do
        let _ := @recomputeCommitment_chain_coherent_with_kernelOnlyReplay
        pure ()
    }
  , -- ===== Per-step coherence theorem (#225) =====
    { name := "recomputeCommitment_coherent_with_kernelOnlyApply API stable"
    , body := do
        let _ := @recomputeCommitment_coherent_with_kernelOnlyApply
        pure ()
    }
  , -- ===== `recomputeCommitment` is deterministic =====
    { name := "recomputeCommitment is deterministic"
    , body := do
        let es := ExtendedState.empty
        let st := trivialSignedAction
        let r₁ := recomputeCommitment es st
        let r₂ := recomputeCommitment es st
        assertEq (expected := r₁) (actual := r₂)
                 "recomputeCommitment is deterministic"
    }
  , { name := "recomputeCommitment has 32-byte output"
    , body := do
        let es := ExtendedState.empty
        let st := trivialSignedAction
        let r := recomputeCommitment es st
        assertEq (expected := 32) (actual := r.size)
                 "recomputeCommitment is 32 bytes"
    }
    -- ===== Workstream GP (GP.3.3) coherence value-level tests =====
  , { name := "GP.3.3: kernelOnlyApply on depositWithFee mutates recipient balance"
    , body := do
        -- Pre-state: recipient (10) has balance 5; poolActor (99)
        -- has balance 0.  After kernelOnlyApply:
        --   recipient.balance = 5 + 30 = 35
        --   poolActor.balance = 0 + 20 = 20
        -- The signer (bridgeActor = 0) is exempt from balance
        -- mutation at the kernel-step level (Laws.depositWithFee
        -- only credits recipient + poolActor; bridgeActor is the
        -- signer but the source of funds is L1, not bridgeActor's
        -- balance).
        let es0 := ExtendedState.empty
        let baseWithRecipient :=
          LegalKernel.setBalance es0.base 1 10 5
        let es : ExtendedState := { es0 with base := baseWithRecipient }
        let es' := kernelOnlyApply es depositWithFeeLogEntry
        let recipientBal := LegalKernel.getBalance es'.base 1 10
        let poolBal := LegalKernel.getBalance es'.base 1 99
        assertEq (expected := 35) (actual := recipientBal)
                 "recipient credited userAmount = 30 (pre 5 → post 35)"
        assertEq (expected := 20) (actual := poolBal)
                 "poolActor credited poolAmount = 20 (pre 0 → post 20)"
    }
  , { name := "GP.3.3: kernelOnlyApply on topUpActionBudget transfers gas"
    , body := do
        -- Pre-state: signer (50) has gas-resource (2) balance 100;
        -- poolActor (99) has gas-resource balance 0.  After
        -- kernelOnlyApply:
        --   signer.balance(2) = 100 - 15 = 85
        --   poolActor.balance(2) = 0 + 15 = 15
        let es0 := ExtendedState.empty
        let baseWithSigner :=
          LegalKernel.setBalance es0.base 2 50 100
        let es : ExtendedState := { es0 with base := baseWithSigner }
        let es' := kernelOnlyApply es topUpActionBudgetLogEntry
        let signerBal := LegalKernel.getBalance es'.base 2 50
        let poolBal := LegalKernel.getBalance es'.base 2 99
        assertEq (expected := 85) (actual := signerBal)
                 "signer debited gasAmount = 15 (pre 100 → post 85)"
        assertEq (expected := 15) (actual := poolBal)
                 "poolActor credited gasAmount = 15 (pre 0 → post 15)"
    }
  , { name := "GP.3.3: recomputeCommitment agrees with commitExtendedState ∘ kernelOnlyApply on depositWithFee"
    , body := do
        let es0 := ExtendedState.empty
        let baseWithRecipient :=
          LegalKernel.setBalance es0.base 1 10 5
        let es : ExtendedState := { es0 with base := baseWithRecipient }
        let lhs := recomputeCommitment es depositWithFeeSignedAction
        let rhs := commitExtendedState
                     (kernelOnlyApply es depositWithFeeLogEntry)
        assertEq (expected := rhs) (actual := lhs)
                 "#225 universal lemma on depositWithFee"
    }
  , { name := "GP.3.3: recomputeCommitment agrees with commitExtendedState ∘ kernelOnlyApply on topUpActionBudget"
    , body := do
        let es0 := ExtendedState.empty
        let baseWithSigner :=
          LegalKernel.setBalance es0.base 2 50 100
        let es : ExtendedState := { es0 with base := baseWithSigner }
        let lhs := recomputeCommitment es topUpActionBudgetSignedAction
        let rhs := commitExtendedState
                     (kernelOnlyApply es topUpActionBudgetLogEntry)
        assertEq (expected := rhs) (actual := lhs)
                 "#225 universal lemma on topUpActionBudget"
    }
  , { name := "GP.3.3: kernelOnlyApply on depositWithFee advances signer nonce"
    , body := do
        -- Every action — including depositWithFee — advances the
        -- signer's nonce (Bridge.bridgeActor = 0 in this case).
        -- Pre-nonce = 0 → post-nonce = 1.
        let es0 := ExtendedState.empty
        let preNonce := Authority.expectsNonce es0 Bridge.bridgeActor
        let es' := kernelOnlyApply es0 depositWithFeeLogEntry
        let postNonce := Authority.expectsNonce es' Bridge.bridgeActor
        assertEq (expected := preNonce + 1) (actual := postNonce)
                 "signer nonce advances by 1"
    }
  , { name := "GP.3.3: kernelOnlyApply on topUpActionBudget advances signer nonce"
    , body := do
        let es0 := ExtendedState.empty
        let preNonce := Authority.expectsNonce es0 50
        let es' := kernelOnlyApply es0 topUpActionBudgetLogEntry
        let postNonce := Authority.expectsNonce es' 50
        assertEq (expected := preNonce + 1) (actual := postNonce)
                 "signer nonce advances by 1"
    }
  , { name := "GP.3.3: kernelOnlyApply on depositWithFee leaves recipient untouched at non-target resource"
    , body := do
        -- depositWithFee on resource 1 should leave balances at
        -- resource 2 unchanged.  This pins the kernel-level
        -- locality property (Laws.depositWithFee_other_resource_untouched).
        let es0 := ExtendedState.empty
        let baseWithBalanceAtR2 :=
          LegalKernel.setBalance es0.base 2 10 77
        let es : ExtendedState := { es0 with base := baseWithBalanceAtR2 }
        let es' := kernelOnlyApply es depositWithFeeLogEntry
        let postBalAtR2 := LegalKernel.getBalance es'.base 2 10
        assertEq (expected := 77) (actual := postBalAtR2)
                 "non-target resource untouched"
    }
  , { name := "GP.3.3: kernelOnlyApply on topUpActionBudget leaves balance untouched at non-gas resource"
    , body := do
        -- topUpActionBudget on gasResource 2 should leave balances
        -- at resource 1 unchanged.
        let es0 := ExtendedState.empty
        let baseWithBalanceAtR1 :=
          LegalKernel.setBalance es0.base 1 50 88
        let es : ExtendedState := { es0 with base := baseWithBalanceAtR1 }
        let es' := kernelOnlyApply es topUpActionBudgetLogEntry
        let postBalAtR1 := LegalKernel.getBalance es'.base 1 50
        assertEq (expected := 88) (actual := postBalAtR1)
                 "non-gas resource untouched"
    }
  , { name := "GP.3.3: kernelOnlyApply on depositWithFee self-credit (recipient = poolActor)"
    , body := do
        -- Self-credit edge case: recipient = poolActor.  Both
        -- credits land on the same cell.  Pre-balance 100 →
        -- post-balance 100 + 30 + 20 = 150.
        let selfAction : Action :=
          .depositWithFee 1 10 10 30 20 100 99
        let selfSigned : SignedAction :=
          { action := selfAction, signer := Bridge.bridgeActor,
            nonce := 0, sig := ByteArray.empty }
        let selfEntry : LogEntry :=
          { prevHash := ByteArray.empty, signedAction := selfSigned,
            postStateHash := ByteArray.empty }
        let es0 := ExtendedState.empty
        let baseWithSelf := LegalKernel.setBalance es0.base 1 10 100
        let es : ExtendedState := { es0 with base := baseWithSelf }
        let es' := kernelOnlyApply es selfEntry
        let postBal := LegalKernel.getBalance es'.base 1 10
        assertEq (expected := 150) (actual := postBal)
                 "self-credit: pre + userAmount + poolAmount"
    }
  -- Bridge-scope invariant: kernelOnlyApply (the fault-proof per-step
  -- reference) never mutates the bridge ledger, even on a deposit.
  , { name := "kernelOnlyApply leaves the bridge consumed map unchanged on a deposit"
    , body := do
        -- Pre-state carrying one already-consumed deposit (non-empty bridge).
        let es0 := ExtendedState.empty
        let bridge0 := Bridge.BridgeState.empty.markConsumed 7
          ({ resource := 1, userAmount := 50, poolAmount := 0, budgetGrant := 0 })
        let es : ExtendedState := { es0 with bridge := bridge0 }
        -- Apply a FRESH deposit (depositId 99) via the fault-proof
        -- reference kernel step.
        let depSigned : SignedAction :=
          { action := .deposit 1 10 25 99, signer := Bridge.bridgeActor,
            nonce := 0, sig := ByteArray.empty }
        let entry : LogEntry :=
          { prevHash := ByteArray.empty, signedAction := depSigned,
            postStateHash := ByteArray.empty }
        let es' := kernelOnlyApply es entry
        -- The bridge ledger is UNCHANGED: the prior entry survives and
        -- depositId 99 is NOT marked consumed (bridge-scope boundary —
        -- bridge mutation happens only at the admission layer).
        assertEq (expected := true) (actual := es'.bridge.isConsumed 7)
          "prior consumed entry preserved"
        assertEq (expected := false) (actual := es'.bridge.isConsumed 99)
          "deposit NOT marked consumed by kernelOnlyApply"
        assertEq (expected := bridge0.consumed.size) (actual := es'.bridge.consumed.size)
          "consumed map size unchanged"
        -- But the kernel effect DID happen: recipient credited.
        assertEq (expected := 25) (actual := LegalKernel.getBalance es'.base 1 10)
          "kernel-level credit applied"
    }
  , { name := "kernelOnlyApply_preserves_bridge: term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (entry : LogEntry),
                   (kernelOnlyApply es entry).bridge = es.bridge :=
          kernelOnlyApply_preserves_bridge
        pure ()
    }
  , { name := "kernelOnlyReplay_preserves_bridge: term-level API"
    , body := do
        let _t : ∀ (genesis : ExtendedState) (entries : List LogEntry),
                   (kernelOnlyReplay genesis entries).bridge = genesis.bridge :=
          kernelOnlyReplay_preserves_bridge
        pure ()
    }
  , { name := "applyCellWrites_to_state_preserves_bridge: term-level API"
    , body := do
        let _t : ∀ (es : ExtendedState) (st : SignedAction),
                   (applyCellWrites_to_state es st).bridge = es.bridge :=
          applyCellWrites_to_state_preserves_bridge
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.Coherence

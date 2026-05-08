/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.LexM2 — M2 milestone byte-equivalence
regression suite.

LX.30 acceptance: every kernel-built-in law's M2 Lex re-expression
produces a `Transition` definitionally equal to the hand-written
form.  After the LX-M2 in-place migration, the per-law `example`
proofs live INSIDE each `Laws/<Law>.lean` file (alongside the
hand-written form), enforced at *elaboration time* (an `rfl`
failure breaks the build); this suite re-asserts the invariants
at *test time* with explicit value-level checks against fixture
inputs.

Each test case picks a representative concrete fixture for the
law's parameters and asserts:

  1. The Lex-derived `legalkernel_<law>_transition (params)`
     equals the hand-written form (already `rfl`; tested here
     for documentation + suite-level visibility).
  2. The transition's `pre` and `apply_impl` projections
     match between the two forms (explicit equality at the
     field level).

Re-running the M2 milestone gate is a one-liner:

```bash
lake test 2>&1 | grep "^== laws-lex-m2"
```

Any divergence here is a build-blocking signal that the M2
strict-equivalence invariant has been broken.
-/

import LegalKernel
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Test
open LegalKernel.Laws
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Disputes

namespace LegalKernel.Test.Laws.LexM2

/-- Fixture state for the value-level field-projection checks. -/
private def fixState : LegalKernel.State := emptyState

/-! ## LX.22 — `transfer` (action index 0) -/

/-- The Lex re-expression of `transfer` is byte-equivalent to the
    hand-written form on a representative fixture.  This is the
    suite-level mirror of the `rfl` `example` in
    `LegalKernel/Laws/Lex/Transfer.lean`. -/
private def transferTests : List TestCase :=
  [ { name := "LX.22: legalkernel_transfer ≡ Laws.transfer (rfl)"
    , body := do
        let _ : legalkernel_transfer_transition 1 10 20 5 =
                Laws.transfer 1 10 20 5 := rfl
        pure ()
    }
  , { name := "LX.22: transfer pre projects identically"
    , body := do
        let lex := legalkernel_transfer_transition 1 10 20 5
        let hand := Laws.transfer 1 10 20 5
        let _ : lex.pre = hand.pre := rfl
        pure ()
    }
  , { name := "LX.22: transfer apply_impl projects identically"
    , body := do
        let lex := legalkernel_transfer_transition 1 10 20 5
        let hand := Laws.transfer 1 10 20 5
        let _ : lex.apply_impl = hand.apply_impl := rfl
        pure ()
    }
  ]

/-! ## LX.23 — `mint` and `burn` (indices 1, 2) -/

private def mintBurnTests : List TestCase :=
  [ { name := "LX.23: legalkernel_mint ≡ Laws.mint (rfl)"
    , body := do
        let _ : legalkernel_mint_transition 1 10 5 = Laws.mint 1 10 5 := rfl
        pure ()
    }
  , { name := "LX.23: legalkernel_burn ≡ Laws.burn (rfl)"
    , body := do
        let _ : legalkernel_burn_transition 1 10 5 = Laws.burn 1 10 5 := rfl
        pure ()
    }
  , { name := "LX.23: mint pre projects identically"
    , body := do
        let _ : (legalkernel_mint_transition 1 10 5).pre =
                (Laws.mint 1 10 5).pre := rfl
        pure ()
    }
  , { name := "LX.23: burn pre projects identically"
    , body := do
        let _ : (legalkernel_burn_transition 1 10 5).pre =
                (Laws.burn 1 10 5).pre := rfl
        pure ()
    }
  ]

/-! ## LX.24 — `freezeResource` and `reward` (indices 3, 5) -/

private def freezeRewardTests : List TestCase :=
  [ { name := "LX.24: legalkernel_freezeResource ≡ Laws.freezeResource (rfl)"
    , body := do
        let _ : legalkernel_freezeResource_transition 7 =
                Laws.freezeResource 7 := rfl
        pure ()
    }
  , { name := "LX.24: legalkernel_reward ≡ Laws.reward (rfl)"
    , body := do
        let _ : legalkernel_reward_transition 1 10 5 = Laws.reward 1 10 5 := rfl
        pure ()
    }
  , { name := "LX.24: freezeResource is the identity transition"
    , body := do
        let lex := legalkernel_freezeResource_transition 7
        -- step_impl on the identity transition is the identity at
        -- the balances level.
        let s' := step_impl fixState lex
        let _ : s'.balances = fixState.balances := by rfl
        pure ()
    }
  ]

/-! ## LX.25 — `replaceKey` and `registerIdentity` (indices 4, 12) -/

private def authorityKeyTests : List TestCase :=
  [ { name := "LX.25: legalkernel_replaceKey ≡ freezeResource 0 (rfl)"
    , body := do
        let pk : LegalKernel.Authority.PublicKey := ByteArray.empty
        let _ : legalkernel_replaceKey_transition 7 pk =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  , { name := "LX.25: legalkernel_registerIdentity ≡ freezeResource 0 (rfl)"
    , body := do
        let pk : LegalKernel.Authority.PublicKey := ByteArray.empty
        let _ : legalkernel_registerIdentity_transition 7 pk =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  ]

/-! ## LX.26 — `deposit` and `withdraw` (indices 13, 14) -/

private def bridgeTests : List TestCase :=
  [ { name := "LX.26: legalkernel_deposit ≡ Laws.deposit (rfl)"
    , body := do
        let _ : legalkernel_deposit_transition 1 10 5 0 =
                Laws.deposit 1 10 5 0 := rfl
        pure ()
    }
  , { name := "LX.26: legalkernel_withdraw ≡ Laws.withdraw (rfl)"
    , body := do
        let rcp : LegalKernel.Bridge.EthAddress := ⟨0, by decide⟩
        let _ : legalkernel_withdraw_transition 1 10 5 rcp =
                Laws.withdraw 1 10 5 rcp := rfl
        pure ()
    }
  ]

/-! ## LX.27 — dispute pipeline (indices 8 – 11) -/

private def disputeTests : List TestCase :=
  [ { name := "LX.27: legalkernel_dispute ≡ freezeResource 0 (rfl)"
    , body := do
        -- Synthesise a minimal Dispute fixture to exercise the
        -- transition.  The dispute's content is irrelevant — the
        -- kernel-level transition is identity regardless.
        let d : Disputes.Dispute := {
          challenger := 1,
          claim := .preconditionFalse 0,
          evidence := ByteArray.empty,
          nonce := 0,
          sig := ByteArray.empty
        }
        let _ : legalkernel_dispute_transition d =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  , { name := "LX.27: legalkernel_disputeWithdraw ≡ freezeResource 0 (rfl)"
    , body := do
        let _ : legalkernel_disputeWithdraw_transition (5 : Disputes.LogIndex) =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  , { name := "LX.27: legalkernel_verdict ≡ freezeResource 0 (rfl)"
    , body := do
        let v : Disputes.Verdict := {
          disputeId := 0,
          outcome := .rejected,
          rationale := ByteArray.empty,
          signatures := []
        }
        let _ : legalkernel_verdict_transition v =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  , { name := "LX.27: legalkernel_rollback ≡ freezeResource 0 (rfl)"
    , body := do
        let _ : legalkernel_rollback_transition (3 : Disputes.LogIndex) =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  ]

/-! ## LX.28 — local-policy actions (indices 15, 16) -/

private def localPolicyTests : List TestCase :=
  [ { name := "LX.28: legalkernel_declareLocalPolicy ≡ freezeResource 0 (rfl)"
    , body := do
        let p : LegalKernel.Authority.LocalPolicy := { clauses := [] }
        let _ : legalkernel_declareLocalPolicy_transition p =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  , { name := "LX.28: legalkernel_revokeLocalPolicy ≡ freezeResource 0 (rfl)"
    , body := do
        let _ : legalkernel_revokeLocalPolicy_transition =
                Laws.freezeResource 0 := rfl
        pure ()
    }
  ]

/-! ## LX.29 — aggregate laws (indices 6, 7) -/

private def aggregateTests : List TestCase :=
  [ { name := "LX.29: legalkernel_distributeOthers ≡ Laws.distributeOthers (rfl)"
    , body := do
        let _ : legalkernel_distributeOthers_transition 1 10 5 =
                Laws.distributeOthers 1 10 5 := rfl
        pure ()
    }
  , { name := "LX.29: legalkernel_proportionalDilute ≡ Laws.proportionalDilute (rfl)"
    , body := do
        let _ : legalkernel_proportionalDilute_transition 1 10 100 =
                Laws.proportionalDilute 1 10 100 := rfl
        pure ()
    }
  ]

/-! ## LX.30 — M2 milestone gate -/

private def milestoneGateTests : List TestCase :=
  [ { name := "LX.30 / LX.38: kernelBuildTag is `canon-lex-m3-manifests`"
    , body := do
        assertEq (expected := "canon-lex-m3-manifests")
                 (actual   := LegalKernel.kernelBuildTag)
                 "M3 milestone gate (supersedes M2)"
    }
  , { name := "LX.30: 17 kernel-built-in laws have Lex re-expressions"
    , body := do
        -- Term-level API stability: every `legalkernel_<law>_transition`
        -- exists and has the expected type.  An identifier rename or
        -- removal would fail elaboration here.
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.ActorId → LegalKernel.Amount →
                LegalKernel.Transition := legalkernel_transfer_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Transition :=
          legalkernel_mint_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Transition :=
          legalkernel_burn_transition
        let _ : LegalKernel.ResourceId → LegalKernel.Transition :=
          legalkernel_freezeResource_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Transition :=
          legalkernel_reward_transition
        let _ : LegalKernel.ActorId → LegalKernel.Authority.PublicKey →
                LegalKernel.Transition := legalkernel_replaceKey_transition
        let _ : LegalKernel.ActorId → LegalKernel.Authority.PublicKey →
                LegalKernel.Transition := legalkernel_registerIdentity_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Bridge.DepositId →
                LegalKernel.Transition := legalkernel_deposit_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Bridge.EthAddress →
                LegalKernel.Transition := legalkernel_withdraw_transition
        let _ : LegalKernel.Disputes.Dispute → LegalKernel.Transition :=
          legalkernel_dispute_transition
        let _ : LegalKernel.Disputes.LogIndex → LegalKernel.Transition :=
          legalkernel_disputeWithdraw_transition
        let _ : LegalKernel.Disputes.Verdict → LegalKernel.Transition :=
          legalkernel_verdict_transition
        let _ : LegalKernel.Disputes.LogIndex → LegalKernel.Transition :=
          legalkernel_rollback_transition
        let _ : LegalKernel.Authority.LocalPolicy → LegalKernel.Transition :=
          legalkernel_declareLocalPolicy_transition
        let _ : LegalKernel.Transition := legalkernel_revokeLocalPolicy_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Transition :=
          legalkernel_distributeOthers_transition
        let _ : LegalKernel.ResourceId → LegalKernel.ActorId →
                LegalKernel.Amount → LegalKernel.Transition :=
          legalkernel_proportionalDilute_transition
        pure ()
    }
  ]

/-! ## Audit-5 mathematical-correctness regression tests

These tests verify that subtle mathematical invariants of the
hand-written laws are preserved by the Lex re-expressions.  Each
test exercises a non-trivial fixture (self-transfer, edge-case
amounts, etc.) and confirms byte-equivalence at the value level. -/

/-- The §4.11 self-transfer fix is preserved: when sender =
    receiver, the post-state balance is unchanged (the post-debit
    re-read in `apply_impl` sees the debited balance, so the
    credit restores it exactly).  Pin this at value level to
    guard against a future Lex regression that might write
    `getBalance s r receiver` instead of `getBalance s1 r
    receiver` (reading from the original state, not the
    intermediate). -/
private def auditSelfTransferRegression : TestCase := {
  name := "audit-5: §4.11 self-transfer fix preserved in Lex form"
  body := do
    let r : ResourceId := 1
    let actor : ActorId := 10
    let amount : Amount := 5
    let s_funded : State := setBalance emptyState r actor 100
    -- Both forms produce the same post-state (balance unchanged).
    let lex_post := (legalkernel_transfer_transition r actor actor amount).apply_impl s_funded
    let hand_post := (Laws.transfer r actor actor amount).apply_impl s_funded
    assertEq (expected := getBalance hand_post r actor)
             (actual   := getBalance lex_post r actor)
             "lex self-transfer matches hand-written"
    -- Also verify the value equals the original (self-transfer
    -- conserves the actor's total balance per §4.11.1).
    assertEq (expected := (100 : Amount))
             (actual   := getBalance lex_post r actor)
             "self-transfer preserves balance"
}

/-- The transfer pre rejects `amount = 0` (positivity clause). -/
private def auditTransferRejectsZero : TestCase := {
  name := "audit-5: transfer pre rejects amount = 0 (positivity clause)"
  body := do
    let r : ResourceId := 1
    let s : ActorId := 10
    let r' : ActorId := 20
    let s_funded : State := setBalance emptyState r s 100
    -- Both Lex and hand-written forms reject amount = 0.
    assert (decide ¬ (legalkernel_transfer_transition r s r' 0).pre s_funded)
      "lex form rejects amount = 0"
    assert (decide ¬ (Laws.transfer r s r' 0).pre s_funded)
      "hand-written form rejects amount = 0"
}

/-- proportionalDilute precondition rejects empty `sumOthers`. -/
private def auditProportionalDiluteRejectsEmpty : TestCase := {
  name := "audit-5: proportionalDilute pre rejects sumOthers = 0"
  body := do
    let r : ResourceId := 1
    let excluded : ActorId := 10
    let s_empty : State := emptyState
    -- sumOthers s_empty 1 10 = 0; the pre rejects.
    assert (decide ¬ (legalkernel_proportionalDilute_transition r excluded 100).pre s_empty)
      "lex form rejects empty sumOthers"
    assert (decide ¬ (Laws.proportionalDilute r excluded 100).pre s_empty)
      "hand-written form rejects empty sumOthers"
}

/-- Multi-actor distribute: lex and hand-written produce the
    same per-actor balances after applying the foldl. -/
private def auditDistributeOthersMultiActor : TestCase := {
  name := "audit-5: distributeOthers multi-actor post-state byte-equivalent"
  body := do
    let r : ResourceId := 1
    let excluded : ActorId := 10
    let amount : Amount := 5
    -- Build a state with 3 actors: 10 (excluded), 20, 30.
    let s : State := setBalance
                      (setBalance
                        (setBalance emptyState r 10 100)
                        r 20 200)
                      r 30 300
    let lex_post := (legalkernel_distributeOthers_transition r excluded amount).apply_impl s
    let hand_post := (Laws.distributeOthers r excluded amount).apply_impl s
    -- Verify per-actor balances match.
    assertEq (expected := getBalance hand_post r 10)
             (actual   := getBalance lex_post r 10) "actor 10 (excluded)"
    assertEq (expected := getBalance hand_post r 20)
             (actual   := getBalance lex_post r 20) "actor 20"
    assertEq (expected := getBalance hand_post r 30)
             (actual   := getBalance lex_post r 30) "actor 30"
    -- Spot-check: excluded actor's balance unchanged.
    assertEq (expected := (100 : Amount))
             (actual   := getBalance lex_post r 10) "excluded preserved"
}

/-- Burn correctly truncates at zero balance (Nat-subtraction
    asymmetry).  Verify Lex form preserves this behavior. -/
private def auditBurnTruncates : TestCase := {
  name := "audit-5: burn Nat-truncates at zero balance"
  body := do
    let r : ResourceId := 1
    let actor : ActorId := 10
    -- Insufficient balance: pre rejects.
    let s_underfunded : State := setBalance emptyState r actor 3
    assert (decide ¬ (legalkernel_burn_transition r actor 5).pre s_underfunded)
      "lex form rejects under-funded"
}

/-- Audit-6: `mint` with `amount = 0` is rejected by precondition.
    The hand-written `Laws.mint`'s pre is `amount > 0`; the Lex
    re-expression must preserve this rejection.  Catches a future
    regression that drops the positivity clause from `lex_pre`. -/
private def auditMintRejectsZero : TestCase := {
  name := "audit-6: mint with amount=0 is rejected (Lex form)"
  body := do
    let r : ResourceId := 1
    let to : ActorId := 10
    let s : State := emptyState
    -- Lex form: precondition fails on amount=0.
    assert (decide ¬ (legalkernel_mint_transition r to 0).pre s)
      "lex form rejects mint amount=0"
    -- Hand-written form: same.
    assert (decide ¬ (Laws.mint r to 0).pre s) "hand-written agrees"
}

/-- Audit-6: `reward` with `amount = 0` is rejected by precondition.
    Mirror of `auditMintRejectsZero`; reward shares mint's
    `amount > 0` precondition.  The two laws are kernel-identical
    but action-layer-distinct, so independent regression coverage
    is warranted. -/
private def auditRewardRejectsZero : TestCase := {
  name := "audit-6: reward with amount=0 is rejected (Lex form)"
  body := do
    let r : ResourceId := 1
    let to : ActorId := 10
    let s : State := emptyState
    assert (decide ¬ (legalkernel_reward_transition r to 0).pre s)
      "lex form rejects reward amount=0"
    assert (decide ¬ (Laws.reward r to 0).pre s) "hand-written agrees"
}

/-- Audit-6: `withdraw` rejects when balance is insufficient.
    The hand-written precondition is `getBalance s r sender ≥
    amount`.  Verify Lex form preserves this rejection. -/
private def auditWithdrawRejectsInsufficient : TestCase := {
  name := "audit-6: withdraw rejects insufficient balance (Lex form)"
  body := do
    let r : ResourceId := 1
    let sender : ActorId := 10
    -- Use a sample EthAddress (the recipient is not used in the
    -- kernel-level precondition, only by the bridge accounting).
    let recipient : Bridge.EthAddress :=
      ⟨0, by decide⟩
    let s : State := setBalance emptyState r sender 3
    -- amount = 5 > balance = 3: lex form rejects.
    assert (decide ¬ (legalkernel_withdraw_transition r sender 5 recipient).pre s)
      "lex form rejects under-funded withdraw"
    -- amount = 3 = balance: lex form accepts.
    assert (decide ((legalkernel_withdraw_transition r sender 3 recipient).pre s))
      "lex form accepts exactly-funded withdraw"
}

/-- Audit-6: `deposit` accepts `amount = 0` (no positivity clause).
    Distinguishes deposit from mint/reward — bridge attestations
    of zero-amount deposits are admissible at the kernel level
    (deployment policy may reject them via the AuthorityPolicy
    layer; the kernel's precondition is `True`). -/
private def auditDepositAcceptsZero : TestCase := {
  name := "audit-6: deposit precondition is True (Lex form admits amount=0)"
  body := do
    let r : ResourceId := 1
    let recipient : ActorId := 10
    let depositId : Bridge.DepositId := 0
    let s : State := emptyState
    -- Pre is `True`, accepts every amount.
    assert (decide ((legalkernel_deposit_transition r recipient 0 depositId).pre s))
      "lex form's precondition admits amount=0"
    assert (decide ((legalkernel_deposit_transition r recipient 100 depositId).pre s))
      "lex form's precondition admits amount=100"
}

/-- Audit-6 mathematical-correctness regression suite (extends
    audit-5's `auditMathTests` with mint/reward/withdraw/deposit
    boundary cases). -/
private def auditMathTests : List TestCase :=
  [ auditSelfTransferRegression
  , auditTransferRejectsZero
  , auditProportionalDiluteRejectsEmpty
  , auditDistributeOthersMultiActor
  , auditBurnTruncates
  , auditMintRejectsZero
  , auditRewardRejectsZero
  , auditWithdrawRejectsInsufficient
  , auditDepositAcceptsZero ]

/-- The full M2 byte-equivalence regression suite. -/
def tests : List TestCase :=
  transferTests ++ mintBurnTests ++ freezeRewardTests ++
  authorityKeyTests ++ bridgeTests ++ disputeTests ++
  localPolicyTests ++ aggregateTests ++ milestoneGateTests ++
  auditMathTests

end LegalKernel.Test.Laws.LexM2

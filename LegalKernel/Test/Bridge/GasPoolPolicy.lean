-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.GasPoolPolicy — Workstream GP.7.2 test suite.

Exercises the canonical `gasPoolPolicy`
(`LegalKernel/Bridge/GasPoolPolicy.lean`).  Coverage:

  * **Deny-list shape.**  `gasPoolDeniedTags = [1, 2, …, 22]`
    (every Action tag except `transfer`), `0 ∉` it, every non-zero
    tag in range `∈` it, and `Action.tag_lt_denyListBound`.
  * **Only-transfer outflow.**  `gasPoolPolicy_denies_all_non_transfer`
    across a representative sample of EVERY non-transfer Action tag
    (1..21), value-level via `decide` plus term-level API stability.
  * **Per-leg recipient restriction (ETH + BOLD).**  A pool transfer
    to any actor other than `sequencerActor` is denied on each leg;
    a transfer to `sequencerActor` is permitted (cross-product over
    a set of recipient choices).
  * **Per-leg amount cap (ETH + BOLD).**  Boundary cases: at-cap
    permitted, over-cap denied, the positive `_amount_le`
    extraction, and the `maxDrainPerAction = 0` degenerate case
    (only a zero-amount transfer survives).
  * **Leg independence.**  An ETH-leg transfer passes the BOLD
    clauses vacuously and vice versa.
  * **Happy path.**  The legitimate capped sequencer claim is
    admitted on both legs.
  * **Term-level API stability** for every headline theorem.
-/

import LegalKernel
import LegalKernel.Bridge.GasPoolPolicy
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace GasPoolPolicyTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test

/-! ## Fixtures

Canonical per-leg caps for the value-level checks.  The BOLD cap
deliberately differs from the ETH cap so the per-resource
independence is genuinely exercised (a value passing one leg's cap
need not pass the other's). -/

/-- The ETH-leg per-action cap used by the value-level fixtures. -/
def mEth : Amount := 1000

/-- The BOLD-leg per-action cap used by the value-level fixtures.
    Distinct from `mEth` so the two legs are independently tested. -/
def mBold : Amount := 3_000_000

/-- The canonical policy instance under test. -/
def pol : LocalPolicy := gasPoolPolicy mEth mBold

/-- A non-sequencer recipient (any actor other than `sequencerActor`
    = 2; here a user-range id). -/
def someUser : ActorId := 7

/-- A minimal concrete `Verdict` for the `.verdict` fixture. -/
def sampleVerdict : Disputes.Verdict :=
  { disputeId := 0, outcome := .rejected, rationale := ⟨#[]⟩, signatures := [] }

/-- A representative non-transfer Action for every frozen tag 1..21.
    Used to drive `gasPoolPolicy_denies_all_non_transfer` across the
    whole non-transfer Action set. -/
def nonTransferSamples : List (Nat × Action) :=
  [ (1,  .mint 0 someUser 5)
  , (2,  .burn 0 someUser 5)
  , (3,  .freezeResource 0)
  , (4,  .replaceKey someUser ⟨#[0xAA]⟩)
  , (5,  .reward 0 someUser 5)
  , (6,  .distributeOthers 0 someUser 5)
  , (7,  .proportionalDilute 0 someUser 5)
  , (10, .verdict sampleVerdict)
  , (11, .rollback 0)
  , (12, .registerIdentity someUser ⟨#[0xBB]⟩)
  , (13, .deposit 0 someUser 5 0)
  , (14, .withdraw 0 someUser 5 EthAddress.zero)
  , (15, .declareLocalPolicy LocalPolicy.empty)
  , (16, .revokeLocalPolicy)
  , (17, .faultProofChallenge ⟨#[]⟩ 0 0 ⟨#[]⟩)
  , (18, .faultProofResolution ⟨#[]⟩ 0 someUser 0)
  , (19, .depositWithFee 0 someUser gasPoolActor 5 5 5 0)
  , (20, .topUpActionBudget 0 5 5 gasPoolActor)
  , (21, .topUpActionBudgetFor someUser 0 5 5 gasPoolActor) ]

/-! ## Test cases -/

/-- All GP.7.2 test cases. -/
def tests : List TestCase :=
  [ -- ## Deny-list shape
    { name := "GP.7.2: gasPoolDeniedTags = [1..22]"
    , body := do
        assertEq (expected := (List.range 23).filter (· ≠ 0))
          (actual := gasPoolDeniedTags) "deny-list contents"
    }
  , { name := "GP.7.2: gasPoolDeniedTags has 22 entries (1..22)"
    , body := do
        assertEq (expected := 22) (actual := gasPoolDeniedTags.length) "deny-list length"
    }
  , { name := "GP.7.2: 0 ∉ gasPoolDeniedTags (transfer survives)"
    , body := do
        assert (decide ((0 : Nat) ∉ gasPoolDeniedTags)) "0 should not be denied"
    }
  , { name := "GP.7.2: every tag 1..22 ∈ gasPoolDeniedTags"
    , body := do
        for t in List.range 23 do
          if t ≠ 0 then
            assert (decide (t ∈ gasPoolDeniedTags)) s!"tag {t} should be denied"
    }
  , { name := "GP.7.2: 22 ∈ gasPoolDeniedTags (reserved ammSwap slot)"
    , body := do
        -- Index 22 is reserved for the GP.11 `ammSwap`; the pool
        -- actor must be forbidden from signing it once it lands.
        assert (decide ((22 : Nat) ∈ gasPoolDeniedTags)) "ammSwap slot pre-denied"
    }
  , { name := "GP.7.2: zero_not_mem_gasPoolDeniedTags term-level API"
    , body := do
        let _f : (0 : Nat) ∉ gasPoolDeniedTags := zero_not_mem_gasPoolDeniedTags
        pure ()
    }
  , { name := "GP.7.2: Action.tag_lt_denyListBound term-level API"
    , body := do
        let _f : (a : Action) → Action.tag a < 23 := Action.tag_lt_denyListBound
        pure ()
    }
  , { name := "GP.7.2: mem_gasPoolDeniedTags_of_tag_ne_zero term-level API"
    , body := do
        let _f : (a : Action) → Action.tag a ≠ 0 → Action.tag a ∈ gasPoolDeniedTags :=
          mem_gasPoolDeniedTags_of_tag_ne_zero
        pure ()
    }
  , -- ## Only-transfer outflow: every non-transfer Action is denied.
    { name := "GP.7.2: gasPoolPolicy denies every non-transfer Action (tags 1..21)"
    , body := do
        for (tag, act) in nonTransferSamples do
          -- Sanity: the fixture's stated tag matches the Action's tag.
          assertEq (expected := tag) (actual := Action.tag act) s!"fixture tag {tag}"
          -- The policy denies it (value-level via decidability).
          if decide (pol.permits gasPoolActor act) then
            throw <| IO.userError s!"gasPoolPolicy admitted non-transfer Action tag {tag}"
    }
  , { name := "GP.7.2: gasPoolPolicy_denies_all_non_transfer term-level API"
    , body := do
        let _f : (a : Action) → Action.tag a ≠ 0 →
                 ¬ (gasPoolPolicy mEth mBold).permits gasPoolActor a :=
          gasPoolPolicy_denies_all_non_transfer mEth mBold
        pure ()
    }
  , -- ## ETH-leg recipient restriction
    { name := "GP.7.2 ETH: transfer to non-sequencer recipient denied"
    , body := do
        -- Cross-product over several non-sequencer recipients.
        for rcv in [0, 1, 3, 7, 99] do
          let rcv : ActorId := rcv
          if rcv ≠ sequencerActor then
            let act : Action := .transfer 0 gasPoolActor rcv 10
            if decide (pol.permits gasPoolActor act) then
              throw <| IO.userError s!"ETH transfer to non-sequencer {rcv} admitted"
    }
  , { name := "GP.7.2 ETH: transfer to sequencer (within cap) permitted"
    , body := do
        let act : Action := .transfer 0 gasPoolActor sequencerActor 10
        assert (decide (pol.permits gasPoolActor act)) "ETH sequencer transfer denied"
    }
  , { name := "GP.7.2 ETH: requires_sequencer_recipient_eth term-level API"
    , body := do
        let _f : (sender receiver : ActorId) → (amount : Amount) →
                 receiver ≠ sequencerActor →
                 ¬ (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 0 sender receiver amount) :=
          gasPoolPolicy_requires_sequencer_recipient_eth mEth mBold
        pure ()
    }
  , -- ## BOLD-leg recipient restriction
    { name := "GP.7.2 BOLD: transfer to non-sequencer recipient denied"
    , body := do
        for rcv in [0, 1, 3, 7, 99] do
          let rcv : ActorId := rcv
          if rcv ≠ sequencerActor then
            let act : Action := .transfer 1 gasPoolActor rcv 10
            if decide (pol.permits gasPoolActor act) then
              throw <| IO.userError s!"BOLD transfer to non-sequencer {rcv} admitted"
    }
  , { name := "GP.7.2 BOLD: transfer to sequencer (within cap) permitted"
    , body := do
        let act : Action := .transfer 1 gasPoolActor sequencerActor 10
        assert (decide (pol.permits gasPoolActor act)) "BOLD sequencer transfer denied"
    }
  , { name := "GP.7.2 BOLD: requires_sequencer_recipient_bold term-level API"
    , body := do
        let _f : (sender receiver : ActorId) → (amount : Amount) →
                 receiver ≠ sequencerActor →
                 ¬ (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 1 sender receiver amount) :=
          gasPoolPolicy_requires_sequencer_recipient_bold mEth mBold
        pure ()
    }
  , -- ## ETH-leg amount cap
    { name := "GP.7.2 ETH cap: at-boundary (amount = mEth) permitted"
    , body := do
        let act : Action := .transfer 0 gasPoolActor sequencerActor mEth
        assert (decide (pol.permits gasPoolActor act)) "ETH at-cap transfer denied"
    }
  , { name := "GP.7.2 ETH cap: over-cap (amount = mEth + 1) denied"
    , body := do
        let act : Action := .transfer 0 gasPoolActor sequencerActor (mEth + 1)
        if decide (pol.permits gasPoolActor act) then
          throw <| IO.userError "ETH over-cap transfer admitted"
    }
  , { name := "GP.7.2 ETH cap: caps_per_action_eth term-level API"
    , body := do
        let _f : (sender receiver : ActorId) → (amount : Amount) →
                 ¬ amount ≤ mEth →
                 ¬ (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 0 sender receiver amount) :=
          gasPoolPolicy_caps_per_action_eth mEth mBold
        pure ()
    }
  , { name := "GP.7.2 ETH cap: permits_transfer_eth_amount_le term-level API"
    , body := do
        let _f : (sender receiver : ActorId) → (amount : Amount) →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 0 sender receiver amount) →
                 amount ≤ mEth :=
          gasPoolPolicy_permits_transfer_eth_amount_le mEth mBold
        pure ()
    }
  , -- ## BOLD-leg amount cap
    { name := "GP.7.2 BOLD cap: at-boundary (amount = mBold) permitted"
    , body := do
        let act : Action := .transfer 1 gasPoolActor sequencerActor mBold
        assert (decide (pol.permits gasPoolActor act)) "BOLD at-cap transfer denied"
    }
  , { name := "GP.7.2 BOLD cap: over-cap (amount = mBold + 1) denied"
    , body := do
        let act : Action := .transfer 1 gasPoolActor sequencerActor (mBold + 1)
        if decide (pol.permits gasPoolActor act) then
          throw <| IO.userError "BOLD over-cap transfer admitted"
    }
  , { name := "GP.7.2 BOLD cap: independent of ETH cap (mEth < amount ≤ mBold permitted)"
    , body := do
        -- An amount that exceeds the ETH cap but is within the BOLD
        -- cap passes on the BOLD leg — proving the caps are genuinely
        -- per-resource.
        let amt : Amount := mEth + 1
        assert (decide (amt ≤ mBold)) "fixture: amt should be ≤ mBold"
        let act : Action := .transfer 1 gasPoolActor sequencerActor amt
        assert (decide (pol.permits gasPoolActor act)) "BOLD-leg over-ETH-cap denied"
    }
  , { name := "GP.7.2 BOLD cap: caps_per_action_bold term-level API"
    , body := do
        let _f : (sender receiver : ActorId) → (amount : Amount) →
                 ¬ amount ≤ mBold →
                 ¬ (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 1 sender receiver amount) :=
          gasPoolPolicy_caps_per_action_bold mEth mBold
        pure ()
    }
  , { name := "GP.7.2 BOLD cap: permits_transfer_bold_amount_le term-level API"
    , body := do
        let _f : (sender receiver : ActorId) → (amount : Amount) →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 1 sender receiver amount) →
                 amount ≤ mBold :=
          gasPoolPolicy_permits_transfer_bold_amount_le mEth mBold
        pure ()
    }
  , -- ## Degenerate cap = 0: pool cannot drain at all (except amount 0)
    { name := "GP.7.2 cap=0: ETH transfer of any positive amount denied"
    , body := do
        let p0 : LocalPolicy := gasPoolPolicy 0 0
        -- amount 1 over a zero cap fails.
        if decide (p0.permits gasPoolActor (.transfer 0 gasPoolActor sequencerActor 1)) then
          throw <| IO.userError "cap=0 admitted a positive ETH drain"
        -- amount 0 still passes (the legitimate no-op).
        assert (decide (p0.permits gasPoolActor (.transfer 0 gasPoolActor sequencerActor 0)))
          "cap=0 denied a zero-amount transfer"
    }
  , { name := "GP.7.2 cap=0: BOLD transfer of any positive amount denied"
    , body := do
        let p0 : LocalPolicy := gasPoolPolicy 0 0
        if decide (p0.permits gasPoolActor (.transfer 1 gasPoolActor sequencerActor 1)) then
          throw <| IO.userError "cap=0 admitted a positive BOLD drain"
        assert (decide (p0.permits gasPoolActor (.transfer 1 gasPoolActor sequencerActor 0)))
          "cap=0 denied a zero-amount BOLD transfer"
    }
  , -- ## Leg independence
    { name := "GP.7.2: eth_bold_independent term-level API"
    , body := do
        -- Instantiate the theorem at concrete arguments; the four
        -- conjuncts are `Prop`s, so binding the instance witnesses the
        -- theorem's full signature elaborates.
        let _h := gasPoolPolicy_eth_bold_independent gasPoolActor someUser 10 mEth mBold
        pure ()
    }
  , { name := "GP.7.2: ETH-leg transfer passes BOLD clauses vacuously (value-level)"
    , body := do
        -- A resource-0 transfer is unaffected by the resource-1
        -- clauses regardless of recipient / amount: pick a recipient
        -- and amount that would FAIL the BOLD clauses if they applied.
        let bigAmt : Amount := mBold + 999
        let cReq : LocalPolicyClause := .requireRecipientIn 1 [sequencerActor]
        let cCap : LocalPolicyClause := .capAmount 1 mBold
        let act : Action := .transfer 0 gasPoolActor someUser bigAmt
        assert (decide (cReq.permits gasPoolActor act)) "BOLD recipient clause not vacuous on ETH leg"
        assert (decide (cCap.permits gasPoolActor act)) "BOLD cap clause not vacuous on ETH leg"
    }
  , { name := "GP.7.2: BOLD-leg transfer passes ETH clauses vacuously (value-level)"
    , body := do
        let bigAmt : Amount := mEth + 999
        let cReq : LocalPolicyClause := .requireRecipientIn 0 [sequencerActor]
        let cCap : LocalPolicyClause := .capAmount 0 mEth
        let act : Action := .transfer 1 gasPoolActor someUser bigAmt
        assert (decide (cReq.permits gasPoolActor act)) "ETH recipient clause not vacuous on BOLD leg"
        assert (decide (cCap.permits gasPoolActor act)) "ETH cap clause not vacuous on BOLD leg"
    }
  , -- ## Happy path
    { name := "GP.7.2 happy path: ETH sequencer claim admitted (term + value)"
    , body := do
        let _f : (sender : ActorId) → (amount : Amount) → amount ≤ mEth →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 0 sender sequencerActor amount) :=
          gasPoolPolicy_permits_sequencer_transfer_eth mEth mBold
        -- A mid-range claim is admitted.
        assert (decide (pol.permits gasPoolActor (.transfer 0 gasPoolActor sequencerActor 500)))
          "ETH mid-range sequencer claim denied"
    }
  , { name := "GP.7.2 happy path: BOLD sequencer claim admitted (term + value)"
    , body := do
        let _f : (sender : ActorId) → (amount : Amount) → amount ≤ mBold →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer 1 sender sequencerActor amount) :=
          gasPoolPolicy_permits_sequencer_transfer_bold mEth mBold
        assert (decide (pol.permits gasPoolActor (.transfer 1 gasPoolActor sequencerActor 1_500_000)))
          "BOLD mid-range sequencer claim denied"
    }
  ]

end GasPoolPolicyTests
end LegalKernel.Test.Bridge

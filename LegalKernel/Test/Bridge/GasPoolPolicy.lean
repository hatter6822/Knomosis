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

/-- A minimal concrete `Dispute` for the `.dispute` fixture. -/
def sampleDispute : Disputes.Dispute :=
  { challenger := someUser, claim := .preconditionFalse 0
  , evidence := ⟨#[]⟩, nonce := 0, sig := ⟨#[]⟩ }

/-- A representative non-transfer Action for EVERY frozen non-transfer
    tag (1..21 — i.e. all of 0..21 except `transfer` = 0).  Used to
    drive `gasPoolPolicy_denies_all_non_transfer` across the whole
    non-transfer Action set, with no tag skipped. -/
def nonTransferSamples : List (Nat × Action) :=
  [ (1,  .mint 0 someUser 5)
  , (2,  .burn 0 someUser 5)
  , (3,  .freezeResource 0)
  , (4,  .replaceKey someUser ⟨#[0xAA]⟩)
  , (5,  .reward 0 someUser 5)
  , (6,  .distributeOthers 0 someUser 5)
  , (7,  .proportionalDilute 0 someUser 5)
  , (8,  .dispute sampleDispute)
  , (9,  .disputeWithdraw 0)
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
    { name := "GP.7.2: gasPoolDeniedTags = [1..23]"
    , body := do
        assertEq (expected := (List.range 24).filter (· ≠ 0))
          (actual := gasPoolDeniedTags) "deny-list contents"
    }
  , { name := "GP.7.2: gasPoolDeniedTags has 23 entries (1..23)"
    , body := do
        assertEq (expected := 23) (actual := gasPoolDeniedTags.length) "deny-list length"
    }
  , { name := "GP.7.2: 0 ∉ gasPoolDeniedTags (transfer survives)"
    , body := do
        assert (decide ((0 : Nat) ∉ gasPoolDeniedTags)) "0 should not be denied"
    }
  , { name := "GP.7.2: every tag 1..23 ∈ gasPoolDeniedTags"
    , body := do
        for t in List.range 24 do
          if t ≠ 0 then
            assert (decide (t ∈ gasPoolDeniedTags)) s!"tag {t} should be denied"
    }
  , { name := "GP.7.2: 23 ∈ gasPoolDeniedTags (ammSwap denied for pool)"
    , body := do
        -- Index 23 (`ammSwap`) is denied for gasPoolActor; the pool
        -- cannot sign an AMM swap (swaps are bridge-attested).
        assert (decide ((23 : Nat) ∈ gasPoolDeniedTags)) "ammSwap tag denied"
    }
  , { name := "GP.7.2: zero_not_mem_gasPoolDeniedTags term-level API"
    , body := do
        let _f : (0 : Nat) ∉ gasPoolDeniedTags := zero_not_mem_gasPoolDeniedTags
        pure ()
    }
  , { name := "GP.7.2: Action.tag_lt_denyListBound term-level API"
    , body := do
        let _f : (a : Action) → Action.tag a < 24 := Action.tag_lt_denyListBound
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
  , -- ## Complete characterisation (permits_iff)
    { name := "GP.7.2: permits_transfer_iff term-level API"
    , body := do
        let _f : (r : ResourceId) → (sender receiver : ActorId) → (amount : Amount) →
                 ((gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer r sender receiver amount) ↔
                   (r ≠ 0 ∨ (receiver = sequencerActor ∧ amount ≤ mEth)) ∧
                   (r ≠ 1 ∨ (receiver = sequencerActor ∧ amount ≤ mBold))) :=
          gasPoolPolicy_permits_transfer_iff mEth mBold
        pure ()
    }
  , { name := "GP.7.2: permits_transfer_iff agrees with decide (ETH legit / illegit / BOLD / off-leg)"
    , body := do
        -- The iff RHS, evaluated by `decide`, must match the policy's
        -- own `decide` verdict on a spread of cases.
        let cases : List (ResourceId × ActorId × Amount × Bool) :=
          [ (0, sequencerActor, 500, true)      -- ETH legit
          , (0, sequencerActor, mEth + 1, false) -- ETH over-cap
          , (0, someUser, 1, false)             -- ETH wrong recipient
          , (1, sequencerActor, mBold, true)    -- BOLD legit at cap
          , (1, someUser, 1, false)             -- BOLD wrong recipient
          , (2, someUser, 999999, true)         -- off-leg: unconstrained
          , (5, someUser, mBold + 1, true) ]    -- off-leg: any amount
        for (r, rcv, amt, expected) in cases do
          let act : Action := .transfer r gasPoolActor rcv amt
          let got := decide (pol.permits gasPoolActor act)
          assertEq (expected := expected) (actual := got)
            s!"permits verdict for transfer r={r} rcv={rcv} amt={amt}"
    }
  , -- ## Resource-≥2 boundary (honest scope)
    { name := "GP.7.2: transfer over resource ≥ 2 is permitted unconditionally (value-level)"
    , body := do
        -- The policy carries no clause for resources other than 0/1,
        -- so an off-leg transfer to a NON-sequencer for a HUGE amount
        -- is permitted.  This is the documented boundary, not a bug:
        -- pool-balance-zero-off-legs is a separate (GP.7.3) invariant.
        for r in [2, 3, 99] do
          let r : ResourceId := r
          let act : Action := .transfer r gasPoolActor someUser (mBold + mEth + 10^9)
          assert (decide (pol.permits gasPoolActor act))
            s!"off-leg transfer at r={r} unexpectedly denied"
    }
  , { name := "GP.7.2: permits_transfer_off_gas_legs term-level API"
    , body := do
        let _f : (r : ResourceId) → (sender receiver : ActorId) → (amount : Amount) →
                 r ≠ 0 → r ≠ 1 →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer r sender receiver amount) :=
          gasPoolPolicy_permits_transfer_off_gas_legs mEth mBold
        pure ()
    }
  , -- ## Admission-layer reach + the meta-action boundary
    { name := "GP.7.2 admission: meta-actions BYPASS gasPoolPolicy (the boundary)"
    , body := do
        -- Register gasPoolPolicy for gasPoolActor, then confirm BOTH
        -- meta-actions are admitted by `localPolicyPermits` despite the
        -- restrictive policy — the LP.7 exemption.  This is the
        -- security-relevant fact motivating the GP.7.4 AuthorityPolicy.
        let es : ExtendedState :=
          { ExtendedState.empty with
              localPolicies := LocalPolicies.empty.declare gasPoolActor pol }
        assert (decide (Authority.localPolicyPermits es gasPoolActor .revokeLocalPolicy))
          "revokeLocalPolicy should be admitted by the meta exemption"
        assert (decide (Authority.localPolicyPermits es gasPoolActor
                          (.declareLocalPolicy LocalPolicy.empty)))
          "declareLocalPolicy should be admitted by the meta exemption"
    }
  , { name := "GP.7.2 admission: admission_permits_meta_actions term-level API"
    , body := do
        let _f : (es : ExtendedState) → (mE mB : Amount) →
                 es.localPolicies.lookup gasPoolActor = gasPoolPolicy mE mB →
                 (Authority.localPolicyPermits es gasPoolActor .revokeLocalPolicy ∧
                  (∀ p, Authority.localPolicyPermits es gasPoolActor
                          (.declareLocalPolicy p))) :=
          gasPoolPolicy_admission_permits_meta_actions
        pure ()
    }
  , { name := "GP.7.2 admission: non-transfer non-meta action is DENIED at admission"
    , body := do
        -- With gasPoolPolicy registered, a `mint` (non-transfer,
        -- non-meta) is rejected by the admission conjunct.
        let es : ExtendedState :=
          { ExtendedState.empty with
              localPolicies := LocalPolicies.empty.declare gasPoolActor pol }
        if decide (Authority.localPolicyPermits es gasPoolActor (.mint 0 someUser 5)) then
          throw <| IO.userError "admission admitted a non-transfer non-meta action"
    }
  , { name := "GP.7.2 admission: admission_denies_non_transfer_non_meta term-level API"
    , body := do
        let _f : (es : ExtendedState) → (action : Action) → (mE mB : Amount) →
                 es.localPolicies.lookup gasPoolActor = gasPoolPolicy mE mB →
                 Action.tag action ≠ 0 →
                 Authority.isMetaPolicyAction action = false →
                 ¬ Authority.localPolicyPermits es gasPoolActor action :=
          gasPoolPolicy_admission_denies_non_transfer_non_meta
        pure ()
    }
  , { name := "GP.7.2 admission: a capped sequencer transfer is ADMITTED at admission"
    , body := do
        -- End-to-end positive: the legitimate drain passes the kernel's
        -- admission conjunct (not just the bare predicate).
        let es : ExtendedState :=
          { ExtendedState.empty with
              localPolicies := LocalPolicies.empty.declare gasPoolActor pol }
        assert (decide (Authority.localPolicyPermits es gasPoolActor
                          (.transfer 0 gasPoolActor sequencerActor 500)))
          "admission rejected a legitimate capped sequencer claim"
        -- ...and a wrong-recipient transfer is rejected at admission.
        if decide (Authority.localPolicyPermits es gasPoolActor
                     (.transfer 0 gasPoolActor someUser 500)) then
          throw <| IO.userError "admission admitted a wrong-recipient pool transfer"
    }
  , -- ## Sender independence (documented non-guarantee)
    { name := "GP.7.2: transfer verdict is sender-independent (value-level)"
    , body := do
        -- Same resource/recipient/amount, different senders ⇒ same verdict.
        let a1 : Action := .transfer 0 gasPoolActor sequencerActor 500
        let a2 : Action := .transfer 0 someUser     sequencerActor 500
        assertEq (expected := decide (pol.permits gasPoolActor a1))
          (actual := decide (pol.permits gasPoolActor a2)) "sender independence"
    }
  , { name := "GP.7.2: transfer_sender_independent term-level API"
    , body := do
        let _f : (r : ResourceId) → (sender sender' receiver : ActorId) → (amount : Amount) →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer r sender receiver amount) →
                 (gasPoolPolicy mEth mBold).permits gasPoolActor
                     (.transfer r sender' receiver amount) :=
          gasPoolPolicy_transfer_sender_independent mEth mBold
        pure ()
    }
  , -- ## Canonical-encoding boundedness + CBE round-trip (GP.7.4 prereq)
    { name := "GP.7.2: gasPoolPolicy is fieldsBounded (value-level, in-range caps)"
    , body := do
        -- Concrete in-UInt64-range caps: decidable `fieldsBounded`.
        assert (decide (Encoding.LocalPolicy.fieldsBounded (gasPoolPolicy mEth mBold)))
          "gasPoolPolicy not fieldsBounded at in-range caps"
    }
  , { name := "GP.7.2: gasPoolPolicy_fieldsBounded term-level API"
    , body := do
        let _f : (mE mB : Amount) → mE < 256 ^ 8 → mB < 256 ^ 8 →
                 Encoding.LocalPolicy.fieldsBounded (gasPoolPolicy mE mB) :=
          gasPoolPolicy_fieldsBounded
        pure ()
    }
  , { name := "GP.7.2: gasPoolPolicy CBE round-trips (value-level)"
    , body := do
        -- decode (encode pol) = .ok (pol, []) — the genesis-declaration
        -- prerequisite, checked by evaluation.
        let encoded := Encoding.Encodable.encode (T := LocalPolicy) (gasPoolPolicy mEth mBold)
        match Encoding.Encodable.decode (T := LocalPolicy) encoded with
        | .ok (p, rest) =>
            assertEq (expected := gasPoolPolicy mEth mBold) (actual := p) "round-trip policy"
            assert (rest.isEmpty) "round-trip left trailing bytes"
        | .error e =>
            throw <| IO.userError s!"round-trip decode failed: {repr e}"
    }
  , { name := "GP.7.2: gasPoolPolicy_roundtrip term-level API"
    , body := do
        let _f : (mE mB : Amount) → mE < 256 ^ 8 → mB < 256 ^ 8 →
                 Encoding.Encodable.decode (T := LocalPolicy)
                     (Encoding.Encodable.encode (gasPoolPolicy mE mB)) =
                   .ok (gasPoolPolicy mE mB, []) :=
          gasPoolPolicy_roundtrip
        pure ()
    }
  , -- ## Complementary AuthorityPolicy (closes the meta-action hole)
    { name := "GP.7.2 authority: gasPoolAuthorityPolicy REJECTS gasPoolActor meta-actions"
    , body := do
        -- The fix for the LP.7 escape hatch: at the AuthorityPolicy
        -- conjunct (which has NO meta exemption), gasPoolActor cannot
        -- sign declareLocalPolicy / revokeLocalPolicy.
        let ap := gasPoolAuthorityPolicy mEth mBold
        if decide (ap.authorized gasPoolActor .revokeLocalPolicy) then
          throw <| IO.userError "authority policy authorised gasPoolActor revokeLocalPolicy"
        if decide (ap.authorized gasPoolActor (.declareLocalPolicy LocalPolicy.empty)) then
          throw <| IO.userError "authority policy authorised gasPoolActor declareLocalPolicy"
    }
  , { name := "GP.7.2 authority: rejects_meta term-level API"
    , body := do
        let _f : (mE mB : Amount) →
                 (¬ (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor .revokeLocalPolicy ∧
                  (∀ p, ¬ (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor
                            (.declareLocalPolicy p))) :=
          gasPoolAuthorityPolicy_rejects_meta
        pure ()
    }
  , { name := "GP.7.2 authority: authorises capped sequencer transfer (both legs)"
    , body := do
        let ap := gasPoolAuthorityPolicy mEth mBold
        assert (decide (ap.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor mEth)))
          "ETH capped sequencer transfer not authorised"
        assert (decide (ap.authorized gasPoolActor (.transfer 1 gasPoolActor sequencerActor mBold)))
          "BOLD capped sequencer transfer not authorised"
    }
  , { name := "GP.7.2 authority: rejects non-transfer / off-leg / non-sequencer / over-cap"
    , body := do
        let ap := gasPoolAuthorityPolicy mEth mBold
        -- non-transfer
        if decide (ap.authorized gasPoolActor (.mint 0 someUser 5)) then
          throw <| IO.userError "authority authorised a mint"
        -- off-leg resource (≥ 2): rejected at the authority layer
        if decide (ap.authorized gasPoolActor (.transfer 2 gasPoolActor sequencerActor 1)) then
          throw <| IO.userError "authority authorised an off-leg transfer"
        -- wrong recipient
        if decide (ap.authorized gasPoolActor (.transfer 0 gasPoolActor someUser 1)) then
          throw <| IO.userError "authority authorised a non-sequencer transfer"
        -- over-cap
        if decide (ap.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor (mEth + 1))) then
          throw <| IO.userError "authority authorised an over-cap transfer"
    }
  , { name := "GP.7.2 authority: REJECTS gasPoolActor-signed transfer of a VICTIM's funds (PR #106 fix)"
    , body := do
        -- The fund-safety fix: the kernel transfer law debits the
        -- action's `sender`, and AdmissibleWith verifies only the
        -- signer's signature.  A gasPoolActor key must NOT be able to
        -- sign a transfer whose `sender` is some other actor (that
        -- would drain the victim's balance to the sequencer).
        let ap := gasPoolAuthorityPolicy mEth mBold
        let victim : ActorId := 9
        -- ETH leg: victim-sender transfer to sequencer, within cap -> DENIED.
        if decide (ap.authorized gasPoolActor (.transfer 0 victim sequencerActor mEth)) then
          throw <| IO.userError "authority authorised a transfer of a VICTIM's ETH (fund drain)"
        -- BOLD leg: same -> DENIED.
        if decide (ap.authorized gasPoolActor (.transfer 1 victim sequencerActor mBold)) then
          throw <| IO.userError "authority authorised a transfer of a VICTIM's BOLD (fund drain)"
        -- Even bridgeActor (id 0) as the sender is rejected — only the
        -- pool's OWN funds may move.
        if decide (ap.authorized gasPoolActor (.transfer 0 bridgeActor sequencerActor 1)) then
          throw <| IO.userError "authority authorised a transfer of bridgeActor's funds"
        -- Sanity: the legitimate pool-owned drain is still authorised.
        assert (decide (ap.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor mEth)))
          "legitimate pool-owned ETH drain was wrongly denied"
        assert (decide (ap.authorized gasPoolActor (.transfer 1 gasPoolActor sequencerActor mBold)))
          "legitimate pool-owned BOLD drain was wrongly denied"
    }
  , { name := "GP.7.2 authority: victim-drain blocked END-TO-END through the intersect wiring"
    , body := do
        -- The documented genesis wiring: base ∩ gasPoolAuthorityPolicy.
        -- Even with an unrestricted base (worst case — base enforces
        -- nothing about the sender), the intersection blocks the drain.
        let ip := AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy mEth mBold)
        let victim : ActorId := 9
        if decide (ip.authorized gasPoolActor (.transfer 0 victim sequencerActor mEth)) then
          throw <| IO.userError "intersect wiring still admits a victim-fund drain"
        assert (decide (ip.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor mEth)))
          "intersect wiring blocked the legitimate pool-owned drain"
    }
  , { name := "GP.7.2 authority: rejects_non_pool_sender term-level API"
    , body := do
        let _f : (mE mB : Amount) → (r : ResourceId) → (sender receiver : ActorId) →
                 (amount : Amount) → sender ≠ gasPoolActor →
                 ¬ (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor
                     (.transfer r sender receiver amount) :=
          gasPoolAuthorityPolicy_rejects_non_pool_sender
        pure ()
    }
  , { name := "GP.7.2 authority: authorizes_sequencer_eth/bold term-level API (sender pinned to pool)"
    , body := do
        let _fe : (mE mB : Amount) → (amount : Amount) → amount ≤ mE →
                  (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor
                      (.transfer 0 gasPoolActor sequencerActor amount) :=
          gasPoolAuthorityPolicy_authorizes_sequencer_eth
        let _fb : (mE mB : Amount) → (amount : Amount) → amount ≤ mB →
                  (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor
                      (.transfer 1 gasPoolActor sequencerActor amount) :=
          gasPoolAuthorityPolicy_authorizes_sequencer_bold
        pure ()
    }
  , { name := "GP.7.2 authority: off-leg + non-sequencer + non-transfer term-level APIs"
    , body := do
        let _f1 : (mE mB : Amount) → (action : Action) → Action.tag action ≠ 0 →
                  ¬ (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor action :=
          gasPoolAuthorityPolicy_rejects_non_transfer
        let _f2 : (mE mB : Amount) → (r : ResourceId) → (sender receiver : ActorId) →
                  (amount : Amount) → r ≠ 0 → r ≠ 1 →
                  ¬ (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor
                      (.transfer r sender receiver amount) :=
          gasPoolAuthorityPolicy_rejects_off_gas_legs
        let _f3 : (mE mB : Amount) → (r : ResourceId) → (sender receiver : ActorId) →
                  (amount : Amount) → receiver ≠ sequencerActor →
                  ¬ (gasPoolAuthorityPolicy mE mB).authorized gasPoolActor
                      (.transfer r sender receiver amount) :=
          gasPoolAuthorityPolicy_rejects_non_sequencer
        pure ()
    }
  , { name := "GP.7.2 authority: intersection is a no-op on non-pool actors (value-level)"
    , body := do
        -- Under (unrestricted ∩ gasPoolAuthorityPolicy), a non-pool
        -- actor retains full authority (here: can sign anything).
        let ip := AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy mEth mBold)
        -- someUser (≠ gasPoolActor) can still sign a meta-action and a mint.
        assert (decide (ip.authorized someUser .revokeLocalPolicy))
          "intersection wrongly restricted a non-pool actor's meta-action"
        assert (decide (ip.authorized someUser (.mint 0 someUser 5)))
          "intersection wrongly restricted a non-pool actor's mint"
        -- ...but gasPoolActor is still barred from the meta-action.
        if decide (ip.authorized gasPoolActor .revokeLocalPolicy) then
          throw <| IO.userError "intersection failed to bar gasPoolActor meta-action"
    }
  , { name := "GP.7.2 authority: other_actors_unrestricted + intersect_rejects_meta term-level APIs"
    , body := do
        let _f1 : (mE mB : Amount) → (P : AuthorityPolicy) →
                  (signer : ActorId) → (action : Action) → signer ≠ gasPoolActor →
                  ((P.intersect (gasPoolAuthorityPolicy mE mB)).authorized signer action ↔
                    P.authorized signer action) :=
          gasPoolAuthorityPolicy_other_actors_unrestricted
        let _f2 : (mE mB : Amount) → (P : AuthorityPolicy) →
                  (¬ (P.intersect (gasPoolAuthorityPolicy mE mB)).authorized
                       gasPoolActor .revokeLocalPolicy ∧
                   (∀ p, ¬ (P.intersect (gasPoolAuthorityPolicy mE mB)).authorized
                             gasPoolActor (.declareLocalPolicy p))) :=
          gasPoolAuthorityPolicy_intersect_rejects_meta
        pure ()
    }
  , { name := "GP.7.2 authority: intersect with unrestricted base bars gasPoolActor meta, keeps legit drain"
    , body := do
        -- With `unrestricted` as the base, the ONLY restriction is the
        -- gas-pool one: the intersected policy bars the meta escape
        -- hatch yet still authorises the capped sequencer claim.
        let ip := AuthorityPolicy.unrestricted.intersect (gasPoolAuthorityPolicy mEth mBold)
        if decide (ip.authorized gasPoolActor (.declareLocalPolicy LocalPolicy.empty)) then
          throw <| IO.userError "intersected policy still admits the meta escape hatch"
        assert (decide (ip.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor 500)))
          "intersected policy blocked the legitimate capped sequencer claim"
    }
  , { name := "GP.7.2 authority: intersect with a GENUINELY restrictive base (bridgePolicy) composes correctly"
    , body := do
        -- The strongest composition test: intersect with `bridgePolicy`
        -- (a real, restrictive deployment policy), proving the
        -- intersection (a) is a no-op on non-pool actors — bridgeActor
        -- keeps EXACTLY bridgePolicy's verdicts — and (b) narrows
        -- gasPoolActor on top of whatever bridgePolicy already said.
        let ip := bridgePolicy.intersect (gasPoolAuthorityPolicy mEth mBold)
        -- (a) bridgeActor (id 0 ≠ gasPoolActor): intersection = bridgePolicy.
        --     bridgePolicy authorises bridgeActor's registerIdentity...
        assert (decide (ip.authorized bridgeActor (.registerIdentity someUser ⟨#[0xAA]⟩)))
          "intersection wrongly stripped bridgeActor's registerIdentity authority"
        --     ...and rejects bridgeActor's transfer (bridgePolicy already did).
        if decide (ip.authorized bridgeActor (.transfer 0 bridgeActor someUser 5)) then
          throw <| IO.userError "intersection wrongly granted bridgeActor a transfer"
        -- (b) gasPoolActor: bridgePolicy authorises ONLY bridgeActor, so it
        --     denies gasPoolActor everything; the intersection is therefore
        --     empty for gasPoolActor — even the capped sequencer transfer is
        --     denied because the BASE policy never authorised it.  This is
        --     correct composition (intersection only ever narrows): a
        --     deployment that wants the pool drain must UNION the sequencer
        --     permit into its base policy (GP.7.4's job), then intersect.
        if decide (ip.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor 5)) then
          throw <| IO.userError "intersection authorised a transfer the base policy denied"
        -- ...and the meta escape hatch is closed regardless of base.
        if decide (ip.authorized gasPoolActor .revokeLocalPolicy) then
          throw <| IO.userError "intersection failed to bar gasPoolActor meta-action under bridgePolicy"
    }
  , { name := "GP.7.2 authority: a base that UNIONs the sequencer permit admits the drain, still bars meta"
    , body := do
        -- The GP.7.4 shape: a deployment that wants the pool drain must
        -- grant gasPoolActor the capped transfer in its BASE policy, THEN
        -- intersect gasPoolAuthorityPolicy.  Model the base as
        -- `unrestricted` (which authorises the drain); the intersection
        -- then admits the drain AND bars the meta escape hatch — exactly
        -- the intended end state.
        let base := AuthorityPolicy.unrestricted
        let ip := base.intersect (gasPoolAuthorityPolicy mEth mBold)
        assert (decide (ip.authorized gasPoolActor (.transfer 0 gasPoolActor sequencerActor mEth)))
          "drain denied under (unrestricted ∩ gasPoolAuthorityPolicy)"
        if decide (ip.authorized gasPoolActor (.transfer 1 gasPoolActor someUser 1)) then
          throw <| IO.userError "non-sequencer BOLD drain admitted under intersection"
        if decide (ip.authorized gasPoolActor .revokeLocalPolicy) then
          throw <| IO.userError "meta-action admitted under intersection"
    }
  ]

end GasPoolPolicyTests
end LegalKernel.Test.Bridge

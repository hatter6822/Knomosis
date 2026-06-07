-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.AmmReservePolicy — Workstream GP.11.6 test suite.

Exercises the canonical `ammReservePolicy`
(`LegalKernel/Bridge/AmmReservePolicy.lean`).  Coverage:

  * **Deny-list shape.**  `ammReserveDeniedTags = [0, 1, …, 22]`
    (every Action tag except `ammSwap`), `23 ∉` it, every non-23
    tag in range `∈` it, and `Action.tag_lt_denyListBound`.
  * **Only-`ammSwap` outflow.**  `ammReservePolicy_denies_all_non_ammSwap`
    across a representative sample of EVERY non-`ammSwap` Action tag
    (0..22), value-level via `decide` plus term-level API stability.
  * **`ammSwap` permitted.**  The sole legitimate action is admitted.
  * **Complete characterisation.**  `ammReservePolicy_permits_iff`
    term-level API.
  * **LP.7 meta-action escape hatch.**  Documents the structural
    limitation and confirms the authority policy closes it.
  * **Authority policy.**  `ammReserveAuthorityPolicy` bars every
    non-`ammSwap` action including meta-actions; admits `ammSwap`;
    is a no-op on other actors.
  * **Genesis wiring.**  `ammReserveGenesisState` declares the policy,
    `ammReserveGenesisPolicy` intersects the authority, the bundle is
    atomic, and composition with `gasPoolGenesis` is non-interfering.
  * **Term-level API stability** for every headline theorem.
-/

import LegalKernel
import LegalKernel.Bridge.AmmReservePolicy
import LegalKernel.Bridge.GasPoolPolicy
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace AmmReservePolicyTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding (Encodable)
open LegalKernel.Test

/-! ## Fixtures -/

/-- A non-reserve actor (any actor other than `ammReserveActor` = 3). -/
def someUser : ActorId := 7

/-- A minimal concrete `Verdict` for the `.verdict` fixture. -/
def sampleVerdict : Disputes.Verdict :=
  { disputeId := 0, outcome := .rejected, rationale := ⟨#[]⟩, signatures := [] }

/-- A minimal concrete `Dispute` for the `.dispute` fixture. -/
def sampleDispute : Disputes.Dispute :=
  { challenger := someUser, claim := .preconditionFalse 0
  , evidence := ⟨#[]⟩, nonce := 0, sig := ⟨#[]⟩ }

/-- A representative non-`ammSwap` Action for EVERY frozen non-ammSwap
    tag (0..22 — all of 0..23 except `ammSwap` = 23).  Used to drive
    `ammReservePolicy_denies_all_non_ammSwap` across the whole
    non-ammSwap Action set, with no tag skipped. -/
def nonAmmSwapSamples : List (Nat × Action) :=
  [ (0,  .transfer 0 someUser someUser 5)
  , (1,  .mint 0 someUser 5)
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
  , (21, .topUpActionBudgetFor someUser 0 5 5 gasPoolActor)
  , (22, .claimBudgetRefund 0 5 5 gasPoolActor) ]

/-! ## Test cases -/

/-- All GP.11.6 test cases. -/
def tests : List TestCase :=
  [ -- ## Deny-list shape
    { name := "GP.11.6: ammReserveDeniedTags = [0..22]"
    , body := do
        assertEq (expected := (List.range 24).filter (· ≠ 23))
          (actual := ammReserveDeniedTags) "deny-list contents"
    }
  , { name := "GP.11.6: ammReserveDeniedTags has 23 entries (0..22)"
    , body := do
        assertEq (expected := 23) (actual := ammReserveDeniedTags.length) "deny-list length"
    }
  , { name := "GP.11.6: 23 ∉ ammReserveDeniedTags (ammSwap survives)"
    , body := do
        assert (decide ((23 : Nat) ∉ ammReserveDeniedTags)) "23 should not be denied"
    }
  , { name := "GP.11.6: every tag 0..22 ∈ ammReserveDeniedTags"
    , body := do
        for t in List.range 24 do
          if t ≠ 23 then
            assert (decide (t ∈ ammReserveDeniedTags)) s!"tag {t} should be denied"
    }
  , { name := "GP.11.6: 0 ∈ ammReserveDeniedTags (transfer denied for reserve)"
    , body := do
        assert (decide ((0 : Nat) ∈ ammReserveDeniedTags)) "transfer tag denied"
    }
  , { name := "GP.11.6: ammSwap_tag_not_mem_ammReserveDeniedTags term-level API"
    , body := do
        let _f : (23 : Nat) ∉ ammReserveDeniedTags := ammSwap_tag_not_mem_ammReserveDeniedTags
        pure ()
    }
  , { name := "GP.11.6: mem_ammReserveDeniedTags_of_tag_ne_ammSwap term-level API"
    , body := do
        let _f : (a : Action) → Action.tag a ≠ 23 →
                 Action.tag a ∈ ammReserveDeniedTags :=
          mem_ammReserveDeniedTags_of_tag_ne_ammSwap
        pure ()
    }
  , -- ## Only-ammSwap outflow: every non-ammSwap Action is denied.
    { name := "GP.11.6: ammReservePolicy denies every non-ammSwap Action (tags 0..22)"
    , body := do
        for (tag, act) in nonAmmSwapSamples do
          assertEq (expected := tag) (actual := Action.tag act) s!"fixture tag {tag}"
          if decide (ammReservePolicy.permits ammReserveActor act) then
            throw <| IO.userError s!"ammReservePolicy admitted non-ammSwap Action tag {tag}"
    }
  , { name := "GP.11.6: ammReservePolicy_denies_all_non_ammSwap term-level API"
    , body := do
        let _f : (a : Action) → Action.tag a ≠ 23 →
                 ¬ ammReservePolicy.permits ammReserveActor a :=
          ammReservePolicy_denies_all_non_ammSwap
        pure ()
    }
  , -- ## ammSwap is permitted
    { name := "GP.11.6: ammReservePolicy permits ammSwap (value-level)"
    , body := do
        let act : Action := .ammSwap 0 1 100 95 ammReserveActor
        assert (decide (ammReservePolicy.permits ammReserveActor act))
          "ammSwap should be permitted"
    }
  , { name := "GP.11.6: ammReservePolicy permits ammSwap (various params)"
    , body := do
        for (fr, tr, ai, ao) in [(0, 1, 1, 1), (1, 0, 999, 500), (0, 1, 0, 0)] do
          let act : Action := .ammSwap fr tr ai ao ammReserveActor
          assert (decide (ammReservePolicy.permits ammReserveActor act))
            s!"ammSwap ({fr},{tr},{ai},{ao}) should be permitted"
    }
  , { name := "GP.11.6: ammReservePolicy_permits_ammSwap term-level API"
    , body := do
        let _f : (fr tr : ResourceId) → (ai ao : Amount) → (ra : ActorId) →
                 ammReservePolicy.permits ammReserveActor (.ammSwap fr tr ai ao ra) :=
          ammReservePolicy_permits_ammSwap
        pure ()
    }
  , -- ## Complete characterisation
    { name := "GP.11.6: ammReservePolicy_permits_iff term-level API"
    , body := do
        let _f : (action : Action) →
                 (ammReservePolicy.permits ammReserveActor action ↔
                  Action.tag action = 23) :=
          ammReservePolicy_permits_iff
        pure ()
    }
  , { name := "GP.11.6: permits_iff forward (ammSwap passes)"
    , body := do
        let act : Action := .ammSwap 0 1 100 95 ammReserveActor
        assertEq (expected := 23) (actual := Action.tag act) "ammSwap has tag 23"
        assert (decide (ammReservePolicy.permits ammReserveActor act))
          "ammSwap admitted per iff forward"
    }
  , { name := "GP.11.6: permits_iff backward (tag≠23 is denied)"
    , body := do
        let act : Action := .transfer 0 ammReserveActor someUser 5
        assert (decide (Action.tag act ≠ 23)) "transfer has tag ≠ 23"
        if decide (ammReservePolicy.permits ammReserveActor act) then
          throw <| IO.userError "transfer should be denied per iff backward"
    }
  , -- ## LP.7 meta-action escape hatch documentation
    { name := "GP.11.6: meta-action escape hatch (tag-value documentation)"
    , body := do
        assertEq (expected := 16) (actual := Action.tag .revokeLocalPolicy)
          "revokeLocalPolicy tag"
        assertEq (expected := 15) (actual := Action.tag (.declareLocalPolicy LocalPolicy.empty))
          "declareLocalPolicy tag"
        assert (decide ((16 : Nat) ≠ 23)) "16 ≠ 23"
        assert (decide ((15 : Nat) ≠ 23)) "15 ≠ 23"
    }
  , -- ## Authority policy: bars non-ammSwap
    { name := "GP.11.6: ammReserveAuthorityPolicy rejects transfer"
    , body := do
        let act : Action := .transfer 0 ammReserveActor someUser 5
        if decide (ammReserveAuthorityPolicy.authorized ammReserveActor act) then
          throw <| IO.userError "authority policy should reject transfer"
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy rejects meta-actions"
    , body := do
        if decide (ammReserveAuthorityPolicy.authorized ammReserveActor .revokeLocalPolicy) then
          throw <| IO.userError "authority policy should reject revokeLocalPolicy"
        if decide (ammReserveAuthorityPolicy.authorized ammReserveActor
            (.declareLocalPolicy LocalPolicy.empty)) then
          throw <| IO.userError "authority policy should reject declareLocalPolicy"
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy_rejects_meta term-level API"
    , body := do
        let _f : ¬ ammReserveAuthorityPolicy.authorized ammReserveActor .revokeLocalPolicy ∧
                 (∀ p, ¬ ammReserveAuthorityPolicy.authorized ammReserveActor
                           (.declareLocalPolicy p)) :=
          ammReserveAuthorityPolicy_rejects_meta
        pure ()
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy_rejects_non_ammSwap term-level API"
    , body := do
        let _f : (action : Action) → Action.tag action ≠ 23 →
                 ¬ ammReserveAuthorityPolicy.authorized ammReserveActor action :=
          ammReserveAuthorityPolicy_rejects_non_ammSwap
        pure ()
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy admits ammSwap"
    , body := do
        let act : Action := .ammSwap 0 1 100 95 ammReserveActor
        assert (decide (ammReserveAuthorityPolicy.authorized ammReserveActor act))
          "authority policy should admit ammSwap"
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy_authorizes_ammSwap term-level API"
    , body := do
        let _f : (fr tr : ResourceId) → (ai ao : Amount) →
                 ammReserveAuthorityPolicy.authorized ammReserveActor
                   (.ammSwap fr tr ai ao ammReserveActor) :=
          ammReserveAuthorityPolicy_authorizes_ammSwap
        pure ()
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy is no-op on other actors"
    , body := do
        for actor in [bridgeActor, gasPoolActor, sequencerActor, someUser] do
          let act : Action := .transfer 0 actor someUser 5
          let base : AuthorityPolicy := .unrestricted
          let combined := base.intersect ammReserveAuthorityPolicy
          if decide (actor ≠ ammReserveActor) then
            assert (decide (combined.authorized actor act))
              s!"authority policy should be no-op on actor {actor}"
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy_other_actors_unrestricted term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (signer : ActorId) → (action : Action) →
                 signer ≠ ammReserveActor →
                 ((P.intersect ammReserveAuthorityPolicy).authorized signer action ↔
                   P.authorized signer action) :=
          ammReserveAuthorityPolicy_other_actors_unrestricted
        pure ()
    }
  , -- ## Genesis wiring
    { name := "GP.11.6: ammReserveGenesisState declares ammReservePolicy"
    , body := do
        let es := ExtendedState.empty
        let gs := ammReserveGenesisState es
        let looked := gs.localPolicies.lookup ammReserveActor
        assertEq (expected := ammReservePolicy) (actual := looked)
          "genesis state should declare ammReservePolicy"
    }
  , { name := "GP.11.6: ammReserveGenesisState_declares_policy term-level API"
    , body := do
        let _f : (es : ExtendedState) →
                 (ammReserveGenesisState es).localPolicies.lookup ammReserveActor =
                   ammReservePolicy :=
          ammReserveGenesisState_declares_policy
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisState preserves other actors"
    , body := do
        let es := ExtendedState.empty
        let gs := ammReserveGenesisState es
        for actor in [bridgeActor, gasPoolActor, sequencerActor, someUser] do
          if decide (actor ≠ ammReserveActor) then
            let looked := gs.localPolicies.lookup actor
            assertEq (expected := es.localPolicies.lookup actor) (actual := looked)
              s!"other actor {actor} should be unchanged"
    }
  , { name := "GP.11.6: ammReserveGenesisState_preserves_other_localPolicies term-level API"
    , body := do
        let _f : (es : ExtendedState) → (a : ActorId) → ammReserveActor ≠ a →
                 (ammReserveGenesisState es).localPolicies.lookup a =
                   es.localPolicies.lookup a :=
          ammReserveGenesisState_preserves_other_localPolicies
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisState_preserves_kernel_substates term-level API"
    , body := do
        let _f : (es : ExtendedState) →
                 (ammReserveGenesisState es).base = es.base ∧
                 (ammReserveGenesisState es).registry = es.registry ∧
                 (ammReserveGenesisState es).nonces = es.nonces ∧
                 (ammReserveGenesisState es).bridge = es.bridge ∧
                 (ammReserveGenesisState es).epochBudgets = es.epochBudgets ∧
                 (ammReserveGenesisState es).budgetPolicy = es.budgetPolicy :=
          ammReserveGenesisState_preserves_kernel_substates
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy rejects non-ammSwap"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let gp := ammReserveGenesisPolicy base
        let act : Action := .transfer 0 ammReserveActor someUser 5
        if decide (gp.authorized ammReserveActor act) then
          throw <| IO.userError "genesis policy should reject transfer for reserve"
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_rejects_meta term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) →
                 ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
                     .revokeLocalPolicy ∧
                 (∀ p, ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
                           (.declareLocalPolicy p)) :=
          ammReserveGenesisPolicy_rejects_meta
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_rejects_non_ammSwap term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (action : Action) →
                 Action.tag action ≠ 23 →
                 ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor action :=
          ammReserveGenesisPolicy_rejects_non_ammSwap
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy admits ammSwap (value-level)"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let gp := ammReserveGenesisPolicy base
        let act : Action := .ammSwap 0 1 100 95 ammReserveActor
        assert (decide (gp.authorized ammReserveActor act))
          "genesis policy should admit ammSwap"
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_authorizes_ammSwap term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) →
                 (fr tr : ResourceId) → (ai ao : Amount) →
                 P.authorized ammReserveActor (.ammSwap fr tr ai ao ammReserveActor) →
                 (ammReserveGenesisPolicy P).authorized ammReserveActor
                   (.ammSwap fr tr ai ao ammReserveActor) :=
          ammReserveGenesisPolicy_authorizes_ammSwap
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_other_actors_unrestricted term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (signer : ActorId) → (action : Action) →
                 signer ≠ ammReserveActor →
                 ((ammReserveGenesisPolicy P).authorized signer action ↔
                   P.authorized signer action) :=
          ammReserveGenesisPolicy_other_actors_unrestricted
        pure ()
    }
  , -- ## Bundle
    { name := "GP.11.6: ammReserveGenesis_wires_both_halves term-level API"
    , body := do
        let _f : (base : ExtendedState) → (P : AuthorityPolicy) →
                 (ammReserveGenesis base P).state = ammReserveGenesisState base ∧
                 (ammReserveGenesis base P).policy = ammReserveGenesisPolicy P :=
          ammReserveGenesis_wires_both_halves
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_bars_self_declaration term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (p : LocalPolicy) →
                 ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
                     (.declareLocalPolicy p) :=
          ammReserveGenesisPolicy_bars_self_declaration
        pure ()
    }
  , -- ## Composition with gasPoolGenesis
    { name := "GP.11.6: ammReserveGenesisPolicy preserves gasPoolActor authority"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let gp := ammReserveGenesisPolicy base
        let act : Action := .transfer 0 gasPoolActor sequencerActor 100
        assert (decide (gp.authorized gasPoolActor act))
          "gasPoolActor transfer should still be admitted"
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_preserves_gasPool_authority term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (action : Action) →
                 ((ammReserveGenesisPolicy P).authorized gasPoolActor action ↔
                   P.authorized gasPoolActor action) :=
          ammReserveGenesisPolicy_preserves_gasPool_authority
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisState preserves gasPoolActor localPolicy"
    , body := do
        let es := ExtendedState.empty
        let gs := ammReserveGenesisState es
        assertEq (expected := es.localPolicies.lookup gasPoolActor)
          (actual := gs.localPolicies.lookup gasPoolActor)
          "gasPoolActor local policy should be unchanged"
    }
  , { name := "GP.11.6: ammReserveGenesisState_preserves_gasPool_localPolicy term-level API"
    , body := do
        let _f : (es : ExtendedState) →
                 (ammReserveGenesisState es).localPolicies.lookup gasPoolActor =
                   es.localPolicies.lookup gasPoolActor :=
          ammReserveGenesisState_preserves_gasPool_localPolicy
        pure ()
    }
  , -- ## Exhaustive non-ammSwap rejection via authority policy
    { name := "GP.11.6: authority policy rejects ALL non-ammSwap actions (tags 0..22)"
    , body := do
        for (tag, act) in nonAmmSwapSamples do
          assertEq (expected := tag) (actual := Action.tag act) s!"fixture tag {tag}"
          if decide (ammReserveAuthorityPolicy.authorized ammReserveActor act) then
            throw <| IO.userError
              s!"ammReserveAuthorityPolicy admitted non-ammSwap Action tag {tag}"
    }
  , -- ## CBE encoding prerequisites
    { name := "GP.11.6: ammReservePolicy_fieldsBounded"
    , body := do
        if ¬ decide (Encoding.LocalPolicy.fieldsBounded ammReservePolicy) then
          throw <| IO.userError "ammReservePolicy fails fieldsBounded"
    }
  , { name := "GP.11.6: ammReservePolicy CBE round-trip"
    , body := do
        let encoded := Encoding.Encodable.encode (T := LocalPolicy) ammReservePolicy
        match Encoding.Encodable.decode (T := LocalPolicy) encoded with
        | .ok (p, rest) =>
          if ¬ decide (p = ammReservePolicy) then
            throw <| IO.userError "round-trip decoded a different policy"
          if ¬ rest.isEmpty then
            throw <| IO.userError "round-trip had leftover bytes"
        | .error e =>
          throw <| IO.userError s!"round-trip decode failed: {repr e}"
    }
  , { name := "GP.11.6: ammReservePolicy_fieldsBounded term-level API"
    , body := do
        let _f : Encoding.LocalPolicy.fieldsBounded ammReservePolicy :=
          ammReservePolicy_fieldsBounded
        pure ()
    }
  , { name := "GP.11.6: ammReservePolicy_roundtrip term-level API"
    , body := do
        let _f : Encoding.Encodable.decode (T := LocalPolicy)
                   (Encoding.Encodable.encode ammReservePolicy) =
                   .ok (ammReservePolicy, []) :=
          ammReservePolicy_roundtrip
        pure ()
    }
  , -- ## Sender-binding (ra = ammReserveActor defence-in-depth)
    { name := "GP.11.6: authority policy rejects ammSwap targeting different actor"
    , body := do
        let act : Action := .ammSwap 0 1 100 95 someUser
        if decide (ammReserveAuthorityPolicy.authorized ammReserveActor act) then
          throw <| IO.userError "authority policy should reject ammSwap targeting non-reserve"
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy_rejects_non_reserve_target term-level API"
    , body := do
        let _f : (fr tr : ResourceId) → (ai ao : Amount) → (ra : ActorId) →
                 ra ≠ ammReserveActor →
                 ¬ ammReserveAuthorityPolicy.authorized ammReserveActor
                     (.ammSwap fr tr ai ao ra) :=
          ammReserveAuthorityPolicy_rejects_non_reserve_target
        pure ()
    }
  , { name := "GP.11.6: ammReserveAuthorityPolicy_authorized_ammSwap_target term-level API"
    , body := do
        let _f : (fr tr : ResourceId) → (ai ao : Amount) → (ra : ActorId) →
                 ammReserveAuthorityPolicy.authorized ammReserveActor
                   (.ammSwap fr tr ai ao ra) →
                 ra = ammReserveActor :=
          ammReserveAuthorityPolicy_authorized_ammSwap_target
        pure ()
    }
  , -- ## Genesis policy rejects non-reserve target
    { name := "GP.11.6: genesis policy rejects ammSwap targeting different actor"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let gp := ammReserveGenesisPolicy base
        let act : Action := .ammSwap 0 1 100 95 someUser
        if decide (gp.authorized ammReserveActor act) then
          throw <| IO.userError "genesis policy should reject ammSwap targeting non-reserve"
    }
  , { name := "GP.11.6: ammReserveGenesisPolicy_rejects_non_reserve_target term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) →
                 (fr tr : ResourceId) → (ai ao : Amount) → (ra : ActorId) →
                 ra ≠ ammReserveActor →
                 ¬ (ammReserveGenesisPolicy P).authorized ammReserveActor
                     (.ammSwap fr tr ai ao ra) :=
          ammReserveGenesisPolicy_rejects_non_reserve_target
        pure ()
    }
  , -- ## Admission-layer theorems
    { name := "GP.11.6: ammReservePolicy_admission_permits_meta_actions term-level API"
    , body := do
        let _f : (es : ExtendedState) →
                 es.localPolicies.lookup ammReserveActor = ammReservePolicy →
                 Authority.localPolicyPermits es ammReserveActor .revokeLocalPolicy ∧
                 (∀ p, Authority.localPolicyPermits es ammReserveActor
                         (.declareLocalPolicy p)) :=
          ammReservePolicy_admission_permits_meta_actions
        pure ()
    }
  , { name := "GP.11.6: ammReservePolicy_admission_permits_iff term-level API"
    , body := do
        let _f : (es : ExtendedState) → (action : Action) →
                 es.localPolicies.lookup ammReserveActor = ammReservePolicy →
                 (Authority.localPolicyPermits es ammReserveActor action ↔
                   (Authority.isMetaPolicyAction action = true ∨
                     ammReservePolicy.permits ammReserveActor action)) :=
          ammReservePolicy_admission_permits_iff
        pure ()
    }
  , -- ## Reverse composition (gasPoolGenesis preserves AMM reserve)
    { name := "GP.11.6: gasPoolGenesisState preserves ammReserveActor localPolicy"
    , body := do
        let es := ExtendedState.empty
        let gps := gasPoolGenesisState es 1000 500
        assertEq (expected := es.localPolicies.lookup ammReserveActor)
          (actual := gps.localPolicies.lookup ammReserveActor)
          "ammReserveActor local policy unchanged after gasPoolGenesisState"
    }
  , { name := "GP.11.6: gasPoolGenesisState_preserves_ammReserve_localPolicy term-level API"
    , body := do
        let _f : (es : ExtendedState) → (mEth mBold : Amount) →
                 (gasPoolGenesisState es mEth mBold).localPolicies.lookup ammReserveActor =
                   es.localPolicies.lookup ammReserveActor :=
          gasPoolGenesisState_preserves_ammReserve_localPolicy
        pure ()
    }
  , { name := "GP.11.6: gasPoolGenesisPolicy preserves ammReserveActor authority"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let gpp := gasPoolGenesisPolicy base 1000 500
        let act : Action := .ammSwap 0 1 100 95 ammReserveActor
        assert (decide (gpp.authorized ammReserveActor act))
          "ammReserveActor ammSwap should still be admitted under gasPoolGenesisPolicy"
    }
  , { name := "GP.11.6: gasPoolGenesisPolicy_preserves_ammReserve_authority term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (mEth mBold : Amount) → (action : Action) →
                 ((gasPoolGenesisPolicy P mEth mBold).authorized ammReserveActor action ↔
                   P.authorized ammReserveActor action) :=
          gasPoolGenesisPolicy_preserves_ammReserve_authority
        pure ()
    }
  , -- ## Option-gated configuration
    { name := "GP.11.6: ammReserveGenesisStateOfConfig none leaves localPolicies unchanged"
    , body := do
        let es := ExtendedState.empty
        let gs := ammReserveGenesisStateOfConfig es none
        assertEq (expected := es.localPolicies.lookup ammReserveActor)
          (actual := gs.localPolicies.lookup ammReserveActor)
          "none config should leave ammReserveActor policy unchanged"
    }
  , { name := "GP.11.6: ammReserveGenesisPolicyOfConfig none admits ammSwap for reserve"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let gp := ammReserveGenesisPolicyOfConfig base none
        let act : Action := .ammSwap 0 1 100 95 ammReserveActor
        assert (decide (gp.authorized ammReserveActor act))
          "none config policy should still admit ammSwap (it is just the base)"
    }
  , { name := "GP.11.6: ammReserveGenesisStateOfConfig some declares policy"
    , body := do
        let es := ExtendedState.empty
        let cfg : AmmReserveConfig := {}
        let gs := ammReserveGenesisStateOfConfig es (some cfg)
        let looked := gs.localPolicies.lookup ammReserveActor
        assertEq (expected := ammReservePolicy) (actual := looked)
          "some config should declare ammReservePolicy"
    }
  , { name := "GP.11.6: ammReserveGenesisPolicyOfConfig some rejects meta"
    , body := do
        let base : AuthorityPolicy := .unrestricted
        let cfg : AmmReserveConfig := {}
        let gp := ammReserveGenesisPolicyOfConfig base (some cfg)
        if decide (gp.authorized ammReserveActor .revokeLocalPolicy) then
          throw <| IO.userError "some config genesis policy should reject revokeLocalPolicy"
    }
  , { name := "GP.11.6: ammReserveGenesisStateOfConfig_none term-level API"
    , body := do
        let _f : (es : ExtendedState) →
                 ammReserveGenesisStateOfConfig es none = es :=
          ammReserveGenesisStateOfConfig_none
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicyOfConfig_none term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) →
                 ammReserveGenesisPolicyOfConfig P none = P :=
          ammReserveGenesisPolicyOfConfig_none
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisStateOfConfig_some_declares_policy term-level API"
    , body := do
        let _f : (es : ExtendedState) → (cfg : AmmReserveConfig) →
                 (ammReserveGenesisStateOfConfig es (some cfg)).localPolicies.lookup
                     ammReserveActor =
                   ammReservePolicy :=
          ammReserveGenesisStateOfConfig_some_declares_policy
        pure ()
    }
  , { name := "GP.11.6: ammReserveGenesisPolicyOfConfig_some_rejects_meta term-level API"
    , body := do
        let _f : (P : AuthorityPolicy) → (cfg : AmmReserveConfig) →
                 ¬ (ammReserveGenesisPolicyOfConfig P (some cfg)).authorized ammReserveActor
                     .revokeLocalPolicy ∧
                 (∀ p, ¬ (ammReserveGenesisPolicyOfConfig P (some cfg)).authorized
                           ammReserveActor (.declareLocalPolicy p)) :=
          ammReserveGenesisPolicyOfConfig_some_rejects_meta
        pure ()
    }
  ]

end AmmReservePolicyTests
end LegalKernel.Test.Bridge

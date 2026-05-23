/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.LocalPolicy — runtime tests for the
LP.1 LocalPolicy data layer.

Workstream LP work unit LP.1.  Exercises:

  * `LocalPolicyClause.permits` per-variant positive / negative cases
    on representative `Action` fixtures.
  * Decidability sanity (`decide (clause.permits ...)`).
  * `LocalPolicy.permits` lifting (vacuous on empty, conjunctive on
    multi-clause).
  * `LocalPolicies` declare / revoke look-up semantics.
  * `Action.tag` agreement with the constructor index for the
    pre-LP-4 set (15 ctors at indices 0..14).
-/

import LegalKernel.Authority.LocalPolicy
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.LocalPolicyTests

/-! ## Action fixtures

A handful of representative actions for the per-clause checks. -/

/-- Transfer 50 from actor 1 to actor 2 at resource 1. -/
def actTransfer : Action := .transfer 1 1 2 50

/-- Mint 100 to actor 3 at resource 1. -/
def actMint : Action := .mint 1 3 100

/-- Burn 10 from actor 1 at resource 1. -/
def actBurn : Action := .burn 1 1 10

/-- Freeze resource 1. -/
def actFreeze : Action := .freezeResource 1

/-! ## LP.1 test cases -/

/-- All LP.1 test cases. -/
def tests : List TestCase :=
  [ -- Action.tag agreement (4 cases, spot-checking the 15-constructor table).
    { name := "Action.tag of transfer is 0"
    , body := do
        assertEq (expected := 0) (actual := Action.tag actTransfer)
    }
  , { name := "Action.tag of mint is 1"
    , body := do
        assertEq (expected := 1) (actual := Action.tag actMint)
    }
  , { name := "Action.tag of burn is 2"
    , body := do
        assertEq (expected := 2) (actual := Action.tag actBurn)
    }
  , { name := "Action.tag of freezeResource is 3"
    , body := do
        assertEq (expected := 3) (actual := Action.tag actFreeze)
    }
  , -- denyTags positive cases.
    { name := "denyTags [0] denies transfer (tag 0)"
    , body := do
        let c : LocalPolicyClause := .denyTags [0]
        if decide (c.permits 1 actTransfer) then
          throw <| IO.userError "denyTags [0] permitted transfer (tag 0)"
        else pure ()
    }
  , { name := "denyTags [1] permits transfer (tag 0 ≠ 1)"
    , body := do
        let c : LocalPolicyClause := .denyTags [1]
        if decide (c.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "denyTags [1] denied transfer (tag 0)"
    }
  , { name := "denyTags [] permits everything (vacuous)"
    , body := do
        let c : LocalPolicyClause := .denyTags []
        if decide (c.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "denyTags [] denied an action"
    }
  , -- requireRecipientIn positive / negative / vacuous cases.
    { name := "requireRecipientIn permits transfer to allowed recipient"
    , body := do
        let c : LocalPolicyClause := .requireRecipientIn 1 [2, 3]
        if decide (c.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "permitted recipient was rejected"
    }
  , { name := "requireRecipientIn denies transfer to non-allowed recipient"
    , body := do
        let c : LocalPolicyClause := .requireRecipientIn 1 [3, 4]
        if decide (c.permits 1 actTransfer) then
          throw <| IO.userError "non-allowed recipient was permitted"
        else pure ()
    }
  , { name := "requireRecipientIn permits transfer on different resource"
    , body := do
        -- Cross-resource isolation: clause is for resource 2,
        -- transfer is at resource 1.
        let c : LocalPolicyClause := .requireRecipientIn 2 [99]
        if decide (c.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "cross-resource isolation violated"
    }
  , { name := "requireRecipientIn permits freezeResource (vacuously)"
    , body := do
        let c : LocalPolicyClause := .requireRecipientIn 1 []
        if decide (c.permits 1 actFreeze) then pure ()
        else throw <| IO.userError "freezeResource was denied vacuously"
    }
  , -- capAmount positive / negative / vacuous cases.
    { name := "capAmount permits transfer at boundary"
    , body := do
        -- amount = 50, max = 50; 50 ≤ 50 holds.
        let c : LocalPolicyClause := .capAmount 1 50
        if decide (c.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "capAmount denied at-boundary transfer"
    }
  , { name := "capAmount denies transfer over cap"
    , body := do
        -- amount = 50, max = 30; 50 ≤ 30 fails.
        let c : LocalPolicyClause := .capAmount 1 30
        if decide (c.permits 1 actTransfer) then
          throw <| IO.userError "over-cap transfer was permitted"
        else pure ()
    }
  , { name := "capAmount permits proportionalDilute (vacuously)"
    , body := do
        let c : LocalPolicyClause := .capAmount 1 0
        let act : Action := .proportionalDilute 1 1 1000
        if decide (c.permits 1 act) then pure ()
        else throw <| IO.userError "proportionalDilute should be vacuously permitted"
    }
  , -- LocalPolicy lifting.
    { name := "LocalPolicy.empty permits all"
    , body := do
        if decide (LocalPolicy.empty.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "empty policy denied an action"
    }
  , { name := "LocalPolicy.permits is conjunctive (both clauses must permit)"
    , body := do
        let p : LocalPolicy :=
          { clauses := [.denyTags [1], .capAmount 1 100] }
        -- transfer (tag 0, amount 50): denyTags [1] permits, capAmount permits.
        if decide (p.permits 1 actTransfer) then pure ()
        else throw <| IO.userError "all-permit policy denied"
        -- mint (tag 1): denyTags [1] denies.
        if decide (p.permits 1 actMint) then
          throw <| IO.userError "denyTags-blocked action was permitted"
        else pure ()
    }
  , -- LocalPolicies look-up semantics.
    { name := "LocalPolicies.empty.lookup returns LocalPolicy.empty"
    , body := do
        assertEq (expected := LocalPolicy.empty)
          (actual := LocalPolicies.empty.lookup 1)
    }
  , { name := "LocalPolicies.declare-then-lookup returns the declared policy"
    , body := do
        let p : LocalPolicy := { clauses := [.denyTags [0]] }
        let lp := LocalPolicies.empty.declare 1 p
        assertEq (expected := p) (actual := lp.lookup 1)
    }
  , { name := "LocalPolicies.declare other actor: lookup is unchanged"
    , body := do
        let p : LocalPolicy := { clauses := [.denyTags [0]] }
        let lp := LocalPolicies.empty.declare 1 p
        -- Lookup at actor 2 returns empty.
        assertEq (expected := LocalPolicy.empty) (actual := lp.lookup 2)
    }
  , { name := "LocalPolicies.revoke restores empty"
    , body := do
        let p : LocalPolicy := { clauses := [.denyTags [0]] }
        let lp1 := LocalPolicies.empty.declare 1 p
        let lp2 := lp1.revoke 1
        assertEq (expected := LocalPolicy.empty) (actual := lp2.lookup 1)
    }
  , { name := "LocalPolicies.declare overwrites prior declaration"
    , body := do
        let p1 : LocalPolicy := { clauses := [.denyTags [0]] }
        let p2 : LocalPolicy := { clauses := [.denyTags [1]] }
        let lp := (LocalPolicies.empty.declare 1 p1).declare 1 p2
        assertEq (expected := p2) (actual := lp.lookup 1)
    }
  , -- Look-up theorem API stability (term-level checks).
    { name := "lookup_declare_self API stability"
    , body := do
        let _proof :
          ∀ (lp : LocalPolicies) (a : ActorId) (p : LocalPolicy),
            (lp.declare a p).lookup a = p :=
          LocalPolicies.lookup_declare_self
        pure ()
    }
  , { name := "lookup_revoke_self API stability"
    , body := do
        let _proof :
          ∀ (lp : LocalPolicies) (a : ActorId),
            (lp.revoke a).lookup a = LocalPolicy.empty :=
          LocalPolicies.lookup_revoke_self
        pure ()
    }
  , -- Bound constants.
    { name := "MAX_CLAUSES_PER_POLICY = 64"
    , body := do
        assertEq (expected := 64) (actual := LocalPolicy.MAX_CLAUSES_PER_POLICY)
    }
  , { name := "MAX_TAGS_PER_DENY = 64"
    , body := do
        assertEq (expected := 64) (actual := LocalPolicy.MAX_TAGS_PER_DENY)
    }
  , { name := "MAX_RECIPIENTS_PER_REQUIRE = 64"
    , body := do
        assertEq (expected := 64) (actual := LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE)
    }
  , { name := "MAX_POLICY_ENCODE_BYTES = 16384"
    , body := do
        assertEq (expected := 16384) (actual := LocalPolicy.MAX_POLICY_ENCODE_BYTES)
    }
  ]

end LegalKernel.Test.Authority.LocalPolicyTests

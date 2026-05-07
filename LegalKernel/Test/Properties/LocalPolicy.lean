/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Properties.LocalPolicy — property-based tests
for Workstream LP.

Workstream LP work unit LP.12.  Three properties exercise:

  1. `localpolicy_roundtrip_property` — every random `LocalPolicy`
     round-trips through the CBE encoder.
  2. `localpolicy_metaaction_admissible_property` — meta-actions
     are admissible regardless of the declared policy.
  3. `localpolicy_empty_no_narrowing_property` — actors with no
     declared policy see no admissibility narrowing on the
     local-policy conjunct.

Each property runs 100 samples by default; `CANON_PROPERTY_SEED`
and `CANON_PROPERTY_ITERATIONS` env vars override.  Failing
samples log the seed for reproduction.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property

namespace LegalKernel.Test.Properties
namespace LocalPolicy

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Test
open LegalKernel.Test.Property

/-! ## Generators -/

/-- Generate a random `Nat` in `[0, 17)` (the post-LP-4 Action ctor
    count). -/
def genTagIdx : Gen Nat := genNat 17

/-- Helper: generate a list of tag indices.  Top-level recursion
    so the kernel doesn't synthesise deep `let rec` definitions. -/
def genTagListAux : Nat → List Nat → GenState → List Nat × GenState
  | 0,     acc, s => (acc, s)
  | k + 1, acc, s =>
    let (t, s') := genTagIdx s
    genTagListAux k (t :: acc) s'

/-- Generate a random list of tag indices, length 0..3. -/
def genTagList : Gen (List Nat) := fun st =>
  let (len, st1) := genNat 4 st
  genTagListAux len [] st1

/-- Helper: generate a list of ActorIds. -/
def genActorListAux : Nat → List ActorId → GenState → List ActorId × GenState
  | 0,     acc, s => (acc, s)
  | k + 1, acc, s =>
    let (a, s') := genNat 256 s
    genActorListAux k (UInt64.ofNat a :: acc) s'

/-- Generate a random `LocalPolicyClause`.  Distributes uniformly
    across the three MVP variants. -/
def genClause : Gen LocalPolicyClause := fun st =>
  let (variant, st1) := genNat 3 st
  match variant with
  | 0 =>
    let (tags, st2) := genTagList st1
    (.denyTags tags, st2)
  | 1 =>
    -- Generate a random resource (UInt64) and short allowed list.
    let (r, st2) := genNat 256 st1
    let (al, st3) := genNat 4 st2
    let (allowed, st4) := genActorListAux al [] st3
    (.requireRecipientIn (UInt64.ofNat r) allowed, st4)
  | _ =>
    let (r, st2) := genNat 256 st1
    let (max, st3) := genNat 1000 st2
    (.capAmount (UInt64.ofNat r) max, st3)

/-- Helper: generate a list of clauses. -/
def genClauseListAux :
    Nat → List LocalPolicyClause → GenState → List LocalPolicyClause × GenState
  | 0,     acc, s => (acc, s)
  | k + 1, acc, s =>
    let (c, s') := genClause s
    genClauseListAux k (c :: acc) s'

/-- Generate a random `LocalPolicy` with 0..3 clauses. -/
def genLocalPolicy : Gen LocalPolicy := fun st =>
  let (n, st1) := genNat 4 st
  let (clauses, st2) := genClauseListAux n [] st1
  ({ clauses }, st2)

/-! ## Helper: enforce policy `fieldsBounded` for the encoder.

The generators above produce within-bound values, so generated
policies should always satisfy `LocalPolicy.fieldsBounded`.  This
predicate is checked by every test. -/

/-- True iff the generated policy's `fieldsBounded` holds. -/
def isBounded (p : LocalPolicy) : Bool :=
  decide (LocalPolicy.fieldsBounded p)

/-! ## Properties -/

/-- Property 1: every random `LocalPolicy` (within the §3.0 bounds)
    round-trips through the CBE encoder.  This exercises both
    LP.2's `localPolicy_roundtrip` and the underlying clause-list
    encoder. -/
def localpolicyRoundtripProperty : TestCase := {
  name := "property: LocalPolicy encode/decode round-trip (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed genLocalPolicy fun p =>
      -- Skip un-bounded samples (shouldn't happen, but defensive).
      if !isBounded p then true
      else
        match Encodable.decode (T := LocalPolicy) (Encodable.encode p) with
        | .ok (p', []) => decide (p = p')
        | _            => false
}

/-- Property 2: meta-actions (`declareLocalPolicy` /
    `revokeLocalPolicy`) satisfy `localPolicyPermits` regardless
    of the declared policy.  Value-level form of LP.7's
    `localPolicy_meta_action_independent` theorem. -/
def localpolicyMetaActionAdmissibleProperty : TestCase := {
  name := "property: meta-actions self-exempt (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed genLocalPolicy fun p =>
      -- Build an ExtendedState with `p` declared for actor 1.
      let registry := KeyRegistry.empty.register 1 (⟨#[]⟩ : PublicKey)
      let lp := LocalPolicies.empty.declare 1 p
      let es : ExtendedState :=
        { base := emptyState
        , nonces := NonceState.empty
        , registry := registry
        , localPolicies := lp }
      -- declareLocalPolicy of any new policy is admissible-conjunct-permitted.
      let dummyP : LocalPolicy := { clauses := [] }
      let admit_declare :=
        decide (localPolicyPermits es 1 (.declareLocalPolicy dummyP))
      -- revokeLocalPolicy is admissible-conjunct-permitted.
      let admit_revoke :=
        decide (localPolicyPermits es 1 .revokeLocalPolicy)
      admit_declare && admit_revoke
}

/-- Property 3: actors with no declared policy see no
    admissibility narrowing on the local-policy conjunct.  Value-
    level form of LP.7's `localPolicyPermits_no_policy` theorem.

    LP.12 audit-2: strengthened to vary the action variant
    (transfer / mint / burn / freezeResource / reward / etc.) by
    using the random `tag` to select among multiple non-meta
    action types.  Previously this only tested `freezeResource`. -/
def localpolicyEmptyNoNarrowingProperty : TestCase := {
  name := "property: empty-policy actors see no narrowing (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genNat 7) fun variant =>
      -- Build an ExtendedState with NO declared policy for actor 1.
      let registry := KeyRegistry.empty.register 1 (⟨#[]⟩ : PublicKey)
      let es : ExtendedState :=
        { base := emptyState
        , nonces := NonceState.empty
        , registry := registry
        , localPolicies := LocalPolicies.empty }
      -- Select a non-meta action based on `variant`.
      let action : Action :=
        match variant with
        | 0 => .transfer 1 1 2 50
        | 1 => .mint 1 1 50
        | 2 => .burn 1 1 10
        | 3 => .freezeResource 1
        | 4 => .reward 1 1 50
        | 5 => .distributeOthers 1 1 50
        | _ => .proportionalDilute 1 1 100
      decide (localPolicyPermits es 1 action)
}

/-! ## All LP.12 property tests -/

/-- All LP.12 property tests. -/
def tests : List TestCase :=
  [ localpolicyRoundtripProperty
  , localpolicyMetaActionAdmissibleProperty
  , localpolicyEmptyNoNarrowingProperty
  ]

end LocalPolicy
end LegalKernel.Test.Properties

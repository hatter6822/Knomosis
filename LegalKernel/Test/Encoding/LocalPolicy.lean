/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.LocalPolicy — runtime tests for the
LP.2 LocalPolicy encoding.

Workstream LP work unit LP.2.  Exercises round-trip and
distinguishability properties of the CBE codec for
`LocalPolicyClause`, `LocalPolicy`, and `LocalPolicies`.
-/

import LegalKernel.Encoding.LocalPolicy
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Encoding.LocalPolicyTests

/-! ## Test fixtures -/

/-- `denyTags [0, 1]` clause. -/
def cDeny : LocalPolicyClause := .denyTags [0, 1]

/-- `requireRecipientIn 1 [42]` clause. -/
def cRequire : LocalPolicyClause := .requireRecipientIn 1 [42]

/-- `capAmount 1 100` clause. -/
def cCap : LocalPolicyClause := .capAmount 1 100

/-- An empty policy. -/
def pEmpty : LocalPolicy := LocalPolicy.empty

/-- A 1-clause policy. -/
def pSingle : LocalPolicy := { clauses := [cDeny] }

/-- A 3-clause policy with all three variants. -/
def pTriple : LocalPolicy := { clauses := [cDeny, cRequire, cCap] }

/-! ## LP.2 test cases -/

/-- All LP.2 test cases. -/
def tests : List TestCase :=
  [ -- Round-trip per clause.
    { name := "denyTags round-trip"
    , body := do
        match Encodable.decode (T := LocalPolicyClause)
                (Encodable.encode (T := LocalPolicyClause) cDeny) with
        | .ok (c', []) =>
          if c' = cDeny then pure ()
          else throw <| IO.userError "denyTags round-trip mismatch"
        | _ => throw <| IO.userError "denyTags round-trip failed to decode"
    }
  , { name := "requireRecipientIn round-trip"
    , body := do
        match Encodable.decode (T := LocalPolicyClause)
                (Encodable.encode (T := LocalPolicyClause) cRequire) with
        | .ok (c', []) =>
          if c' = cRequire then pure ()
          else throw <| IO.userError "requireRecipientIn round-trip mismatch"
        | _ => throw <| IO.userError "requireRecipientIn round-trip failed to decode"
    }
  , { name := "capAmount round-trip"
    , body := do
        match Encodable.decode (T := LocalPolicyClause)
                (Encodable.encode (T := LocalPolicyClause) cCap) with
        | .ok (c', []) =>
          if c' = cCap then pure ()
          else throw <| IO.userError "capAmount round-trip mismatch"
        | _ => throw <| IO.userError "capAmount round-trip failed to decode"
    }
  , -- Round-trip per policy.
    { name := "empty policy round-trip"
    , body := do
        match Encodable.decode (T := LocalPolicy)
                (Encodable.encode (T := LocalPolicy) pEmpty) with
        | .ok (p, []) =>
          if p = pEmpty then pure ()
          else throw <| IO.userError "empty policy round-trip mismatch"
        | _ => throw <| IO.userError "empty policy round-trip failed"
    }
  , { name := "single-clause policy round-trip"
    , body := do
        match Encodable.decode (T := LocalPolicy)
                (Encodable.encode (T := LocalPolicy) pSingle) with
        | .ok (p, []) =>
          if p = pSingle then pure ()
          else throw <| IO.userError "single-clause policy round-trip mismatch"
        | _ => throw <| IO.userError "single-clause policy round-trip failed"
    }
  , { name := "3-clause policy round-trip"
    , body := do
        match Encodable.decode (T := LocalPolicy)
                (Encodable.encode (T := LocalPolicy) pTriple) with
        | .ok (p, []) =>
          if p = pTriple then pure ()
          else throw <| IO.userError "3-clause policy round-trip mismatch"
        | _ => throw <| IO.userError "3-clause policy round-trip failed"
    }
  , -- Cross-clause distinguishability.
    { name := "denyTags vs capAmount produce different bytes"
    , body := do
        let b1 := Encodable.encode (T := LocalPolicyClause) cDeny
        let b2 := Encodable.encode (T := LocalPolicyClause) cCap
        if b1 = b2 then
          throw <| IO.userError "distinct clauses produced identical bytes"
        else pure ()
    }
  , -- Determinism.
    { name := "policy encoding is deterministic"
    , body := do
        let b1 := Encodable.encode (T := LocalPolicy) pTriple
        let b2 := Encodable.encode (T := LocalPolicy) pTriple
        if b1 = b2 then pure ()
        else throw <| IO.userError "encoding non-deterministic"
    }
  , -- Spot-check encoded length is positive.
    { name := "encoded clause is non-empty"
    , body := do
        let b := Encodable.encode (T := LocalPolicyClause) cCap
        if b.length > 0 then pure ()
        else throw <| IO.userError "empty encoding"
    }
  , -- Term-level API stability for headline theorems.
    { name := "localPolicyClause_roundtrip API stability"
    , body := do
        let _proof :
          ∀ (c : LocalPolicyClause) (rest : Stream),
            LocalPolicyClause.fieldsBounded c →
            Encodable.decode (T := LocalPolicyClause)
              (Encodable.encode c ++ rest) = .ok (c, rest) :=
          localPolicyClause_roundtrip
        pure ()
    }
  , { name := "localPolicy_roundtrip API stability"
    , body := do
        let _proof :
          ∀ (p : LocalPolicy) (rest : Stream),
            LocalPolicy.fieldsBounded p →
            Encodable.decode (T := LocalPolicy)
              (Encodable.encode p ++ rest) = .ok (p, rest) :=
          localPolicy_roundtrip
        pure ()
    }
  , { name := "localPolicyClause_encode_injective API stability"
    , body := do
        let _proof :
          ∀ (c₁ c₂ : LocalPolicyClause),
            LocalPolicyClause.fieldsBounded c₁ →
            LocalPolicyClause.fieldsBounded c₂ →
            Encodable.encode (T := LocalPolicyClause) c₁ =
            Encodable.encode (T := LocalPolicyClause) c₂ →
            c₁ = c₂ :=
          localPolicyClause_encode_injective
        pure ()
    }
  , -- LP.2 audit-1: DoS bound enforcement at decode time.
    -- These tests confirm the decoder rejects oversize inputs
    -- (otherwise an attacker could craft a 1000-clause policy
    -- and bypass the §3.0 bounds at the network boundary).
    { name := "LP.2 audit-1: decoder rejects oversize LocalPolicy (100 clauses)"
    , body := do
        let oversize : LocalPolicy :=
          { clauses := List.replicate 100 (.denyTags [0]) }
        let bytes := Encodable.encode (T := LocalPolicy) oversize
        match Encodable.decode (T := LocalPolicy) bytes with
        | .ok _ =>
          throw <| IO.userError "decoder accepted 100-clause policy (DoS gap)"
        | .error _ => pure ()
    }
  , { name := "LP.2 audit-1: decoder accepts at-boundary LocalPolicy (64 clauses)"
    , body := do
        let atBoundary : LocalPolicy :=
          { clauses := List.replicate 64 (.denyTags [0]) }
        let bytes := Encodable.encode (T := LocalPolicy) atBoundary
        match Encodable.decode (T := LocalPolicy) bytes with
        | .ok (p', []) =>
          if p' == atBoundary then pure ()
          else throw <| IO.userError "boundary policy round-trip mismatch"
        | _ => throw <| IO.userError "decoder rejected at-boundary policy"
    }
  , { name := "LP.2 audit-1: decoder rejects oversize denyTags (100 tags)"
    , body := do
        let oversize : LocalPolicyClause :=
          .denyTags (List.range 100)
        let bytes := Encodable.encode (T := LocalPolicyClause) oversize
        match Encodable.decode (T := LocalPolicyClause) bytes with
        | .ok _ =>
          throw <| IO.userError "decoder accepted 100-tag denyTags (DoS gap)"
        | .error _ => pure ()
    }
  , { name := "LP.2 audit-1: decoder rejects oversize requireRecipientIn (100 recipients)"
    , body := do
        let oversize : LocalPolicyClause :=
          .requireRecipientIn 1 ((List.range 100).map UInt64.ofNat)
        let bytes := Encodable.encode (T := LocalPolicyClause) oversize
        match Encodable.decode (T := LocalPolicyClause) bytes with
        | .ok _ =>
          throw <| IO.userError "decoder accepted 100-recipient requireRecipientIn (DoS gap)"
        | .error _ => pure ()
    }
  , { name := "LP.2 audit-1: decoder accepts at-boundary denyTags (64 tags)"
    , body := do
        let atBoundary : LocalPolicyClause :=
          .denyTags (List.range 64)
        let bytes := Encodable.encode (T := LocalPolicyClause) atBoundary
        match Encodable.decode (T := LocalPolicyClause) bytes with
        | .ok (c', []) =>
          if c' == atBoundary then pure ()
          else throw <| IO.userError "boundary denyTags round-trip mismatch"
        | _ => throw <| IO.userError "decoder rejected at-boundary denyTags"
    }
  , { name := "LP.2 audit-1: outer LocalPolicies decoder cascades inner bound check"
    , body := do
        -- A LocalPolicies map containing an oversize inner policy should
        -- be rejected by decodeMap (because LocalPolicy.decode rejects).
        let oversizeP : LocalPolicy :=
          { clauses := List.replicate 100 (.denyTags [0]) }
        let lp := LocalPolicies.empty.declare 1 oversizeP
        let bytes := LocalPolicies.encodeMap lp
        match LocalPolicies.decodeMap bytes with
        | .ok _ =>
          throw <| IO.userError "decoder accepted oversize inner policy (DoS gap)"
        | .error _ => pure ()
    }
  ]

end LegalKernel.Test.Encoding.LocalPolicyTests

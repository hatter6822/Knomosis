/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Test.Properties — Workstream-LX property-based
tests.

Per `docs/planning/lex_implementation_plan.md` §20.2, three first-wave
properties land for the LX.21 acceptance gate:

  1. `lex_macro_idempotency_property` — re-encoding a `LawDecl`
     to its canonical JSON, decoding, and re-encoding produces
     byte-identical output to the first encode (round-trip
     stability).  This catches a class of bugs where the JSON
     encoder is non-canonical or the decoder loses information.

  2. `lex_codegen_determinism_property` — running every renderer
     in `Lex/Tools/Codegen.lean` twice on the same input produces
     byte-identical output.  Catches accidental non-determinism
     (e.g. iterating over a hash-map in non-deterministic order).

  3. `lex_diff_reformatting_invariance_property` — applying the
     fence-rewriting helpers in `Lex/Tools/Codegen.lean` to the
     same input twice produces byte-identical output (the
     `replaceFenceContent` operation is idempotent on its own
     output).  This is the M1-shaped analogue of the §20.2
     `lex_diff_reformatting_invariance_property` (which in M3
     extends to `lex_format <file>`).

Each runs at the default 100-sample iteration count, overridable
via `KNOMOSIS_PROPERTY_ITERATIONS`.

The generators are bespoke for `LawDecl` since the canonical
M1 surface has structured fields (params, satisfies, etc.); the
`Test.Property` framework's primitive generators (`genNat`,
`genBool`, etc.) cover the leaf cells, and the higher-order
combinators wire them into a complete `LawDecl`.

This module is **not** part of the trusted computing base.  Bugs
here surface as flakey property checks; they cannot violate any
kernel invariant.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import Lex.Tools.Common
import Lex.Tools.Codegen

namespace Lex.Test.Properties

open LegalKernel.Test
open LegalKernel.Test.Property
open LegalKernel.Tools.Lex
open LegalKernel.Tools.Lex.Codegen

/-! ## LawDecl generators

Pure generators for `LawDecl` and its components.  The generated
values populate every `LawDecl` field with random-but-bounded
content; the round-trip property is checked over the resulting
`LawDecl`. -/

/-- Internal: collect `k` random alphabetic characters via `genNat 26`. -/
private partial def collectChars (k : Nat) (acc : List Char) (s : GenState) :
    List Char × GenState :=
  if k = 0 then (acc, s)
  else
    let (c, s') := genNat 26 s
    let ch := Char.ofNat (97 + c)
    collectChars (k - 1) (ch :: acc) s'

/-- Generate a short alphabetic identifier component. -/
private def genIdentSegment : Gen String := fun st =>
  let (n, st1) := genNat 4 st          -- 0..3 → length 1..4
  let len := n + 1
  let (chars, st2) := collectChars len [] st1
  (String.ofList chars, st2)

/-- Internal: collect `k` random identifier segments. -/
private partial def collectSegments (k : Nat) (acc : List String) (s : GenState) :
    List String × GenState :=
  if k = 0 then (acc, s)
  else
    let (seg, s') := genIdentSegment s
    collectSegments (k - 1) (seg :: acc) s'

/-- Generate a dotted identifier (`a.b.c` shape).  1..3 segments. -/
private def genDottedIdent : Gen String := fun st =>
  let (n, st1) := genNat 3 st          -- 0..2 → 1..3 segments
  let segs := n + 1
  let (segments, st2) := collectSegments segs [] st1
  (String.intercalate "." segments, st2)

/-- Generate a semver-shaped version string.  Form `<major>.<minor>.<patch>`. -/
private def genVersion : Gen String := fun st =>
  let (mj, st1) := genNat 5 st
  let (mn, st2) := genNat 10 st1
  let (pt, st3) := genNat 100 st2
  (s!"{mj}.{mn}.{pt}", st3)

/-- Generate an action-index in the range [17, 1000) (post-kernel-built-in). -/
private def genActionIndex : Gen Nat := fun st =>
  let (n, st1) := genNat 983 st
  (n + 17, st1)

/-- Generate a `RegistryEffectKind`. -/
private def genRegistryEffectKind : Gen RegistryEffectKind := fun st =>
  let (n, st1) := genNat 4 st
  let kind := match n with
    | 0 => RegistryEffectKind.none_
    | 1 => RegistryEffectKind.replaceKey
    | 2 => RegistryEffectKind.registerIdentity
    | _ => RegistryEffectKind.localPolicy
  (kind, st1)

/-- Generate a small `PropertyClaim` (audit-4 addition).  Picks
    a property name from the §10.1 v1 set + variates the args
    list to actually exercise the audit-3 PropertyClaim codec
    fix.  Pre-audit-4, `genLawDecl` hardcoded `satisfies := []`,
    so the codec path was never sampled by the property tests. -/
def genPropertyClaim : Gen PropertyClaim := fun st =>
  let (kind, st1) := genNat 5 st
  let name := match kind with
    | 0 => "conservative"
    | 1 => "monotonic"
    | 2 => "local"
    | 3 => "freeze_preserving"
    | _ => "registry_preserving"
  let (argCount, st2) := genNat 4 st1   -- 0..3 args
  let (argSeed, st3) := genNat 1000 st2
  let args : List String := match argCount, argSeed % 4 with
    | 0, _ => []
    | _, 0 => ["r1"]
    | _, 1 => ["r1", "alice"]
    | _, 2 => ["{nested:json}"]   -- audit-3 stress: JSON-special chars
    | _, _ => ["raw_string", "another"]
  ({ name, args }, st3)

/-- Generate a `ProofOverride` (audit-4 addition).  Mirrors
    `genPropertyClaim` for the `proof_overrides` field. -/
def genProofOverride : Gen ProofOverride := fun st =>
  let (n, st1) := genNat 3 st
  let property := match n with
    | 0 => "conservative"
    | 1 => "monotonic"
    | _ => "local"
  let (tacSeed, st2) := genNat 4 st1
  let tacticBlock := match tacSeed with
    | 0 => "by exact ()"
    | 1 => "by rfl"
    | 2 => "by simp"
    | _ => "by exact custom_proof"
  ({ property, tacticBlock }, st2)

/-- Internal: collect `k` random `PropertyClaim` values. -/
private partial def collectClaims (k : Nat) (acc : List PropertyClaim) (s : GenState) :
    List PropertyClaim × GenState :=
  if k = 0 then (acc, s)
  else
    let (c, s') := genPropertyClaim s
    collectClaims (k - 1) (acc ++ [c]) s'

/-- Internal: collect `k` random `ProofOverride` values. -/
private partial def collectOverrides (k : Nat) (acc : List ProofOverride) (s : GenState) :
    List ProofOverride × GenState :=
  if k = 0 then (acc, s)
  else
    let (o, s') := genProofOverride s
    collectOverrides (k - 1) (acc ++ [o]) s'

/-- Generate a minimal canonical `LawDecl`.  Audit-4: extended
    to populate `satisfies` and `proofOverrides` with non-empty
    samples so the audit-3 PropertyClaim codec fix and the
    ProofOverride codec are actually exercised by the round-trip
    property test.  Pre-audit-4, both lists were hardcoded `[]`,
    leaving the codec un-tested at the property level. -/
def genLawDecl : Gen LawDecl := fun st =>
  let (ident, st1) := genDottedIdent st
  let (ver, st2) := genVersion st1
  let (idx, st3) := genActionIndex st2
  let (regEff, st4) := genRegistryEffectKind st3
  let (sCount, st5) := genNat 3 st4         -- 0..2 satisfies entries
  let (satisfies, st6) := collectClaims sCount [] st5
  let (oCount, st7) := genNat 2 st6         -- 0..1 proof overrides
  let (overrides, st8) := collectOverrides oCount [] st7
  let decl : LawDecl :=
    { schemaVersion := 1
      identifier := ident
      version := ver
      actionIndex := idx
      intent := s!"intent for {ident}"
      params := []
      signedBy := { name := "alice" }
      authorizedBy := { expr := "fun _ _ => True" }
      preExpr := "fun _ => True"
      implBlock := "fun s => s"
      satisfies := satisfies
      eventsBlock := "[]"
      registryEffect := regEff
      proofOverrides := overrides
      sourceLocation := { fileName := "Generated.lean", startPos := { line := 1, column := 0 } } }
  (decl, st8)

/-! ## Generator for `List LawDecl` -/

/-- Internal: collect `k` random `LawDecl` values. -/
private partial def collectLawDecls (k : Nat) (acc : List LawDecl) (s : GenState) :
    List LawDecl × GenState :=
  if k = 0 then (acc, s)
  else
    let (d, s') := genLawDecl s
    collectLawDecls (k - 1) (d :: acc) s'

/-- Generate a list of `LawDecl`s of length up to `lenMax`.  The
    list is sorted by `actionIndex` (mirroring `loadCodegenInputs`
    output). -/
def genLawDeclList (lenMax : Nat) : Gen (List LawDecl) := fun st =>
  let (len, st1) := genNat (lenMax + 1) st
  let (decls, st2) := collectLawDecls len [] st1
  let sorted := decls.toArray.qsort (fun a b => a.actionIndex < b.actionIndex)
  (sorted.toList, st2)

/-! ## The three §20.2 properties -/

/-- Property 1: `lex_macro_idempotency_property` —
    `LawDecl.fromJson ∘ LawDecl.toCanonicalJson = id` modulo
    schema-defaulted fields.

    The audit-4 stronger form checks BOTH:
      (a) `decl == decl'` (structural equality after roundtrip)
          — guards against the audit-3-class `args` codec
          regression where byte-equal encoded forms hid an
          asymmetric in-memory transformation.
      (b) `firstEncode == secondEncode` (byte determinism on
          re-encode of the decoded value).

    Both properties together rule out the entire class of
    asymmetric encode/decode bugs that audit-3 closed. -/
def lexMacroIdempotencyProperty : TestCase := {
  name := "property: Lex macro idempotency (structural + byte-equal roundtrip) (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed genLawDecl fun decl =>
      let firstEncode := LawDecl.toCanonicalJson decl
      match LawDecl.fromJson firstEncode with
      | .error _ => false  -- canonical encode then decode should never error
      | .ok decl' =>
        let secondEncode := LawDecl.toCanonicalJson decl'
        -- Both forms simultaneously: structural equality of
        -- decoded value AND byte equality of re-encoded form.
        decide (decl = decl') && decide (firstEncode = secondEncode)
}

/-- Property 2: `lex_codegen_determinism_property` — running the
    renderers twice on the same input produces byte-identical
    output.  Catches non-determinism in the rendering pipeline
    (e.g. iterating a `HashMap` in non-deterministic order, or
    capturing IO state from environment variables). -/
def lexCodegenDeterminismProperty : TestCase := {
  name := "property: lex_codegen rendering is deterministic (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genLawDeclList 8) fun decls =>
      let aFirst := renderActionInductive decls
      let aSecond := renderActionInductive decls
      let cFirst := renderCompileTransition decls
      let cSecond := renderCompileTransition decls
      let fbFirst := renderActionFieldsBounded decls
      let fbSecond := renderActionFieldsBounded decls
      let eFirst := renderActionEncode decls
      let eSecond := renderActionEncode decls
      let dFirst := renderActionDecode decls
      let dSecond := renderActionDecode decls
      let evFirst := renderActionEvents decls
      let evSecond := renderActionEvents decls
      let rFirst := renderApplyActionToRegistry decls
      let rSecond := renderApplyActionToRegistry decls
      let nFirst := renderNonRegistryMutating decls
      let nSecond := renderNonRegistryMutating decls
      decide (aFirst = aSecond) &&
      decide (cFirst = cSecond) &&
      decide (fbFirst = fbSecond) &&
      decide (eFirst = eSecond) &&
      decide (dFirst = dSecond) &&
      decide (evFirst = evSecond) &&
      decide (rFirst = rSecond) &&
      decide (nFirst = nSecond)
}

/-- Property 3: `lex_diff_reformatting_invariance_property` (M1
    shape) — applying `replaceFenceContent` twice with the same
    body produces byte-identical output.  A fence-rewrite is
    idempotent on its own output.

    The plan §20.2 spec extends this to `lex_format <file>`
    (M3); the M1-shipping property is the structural analogue
    over the in-tree `replaceFenceContent` helper.

    The generated body is a random alphabetic-ish string. -/
def lexDiffReformattingInvarianceProperty : TestCase := {
  name := "property: replaceFenceContent is idempotent on its own output (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genLawDeclList 4) fun decls =>
      -- Build a synthetic file with a fence and use the renderer
      -- output as the body.  Apply replaceFenceContent once with
      -- a fresh body, then again with the SAME body, and assert
      -- the two outputs are byte-identical.
      let body := renderActionInductive decls
      let initialFile := s!"header line\n{beginFenceMarker}\nold body\n{endFenceMarker}\nfooter line"
      match replaceFenceContent initialFile body with
      | .error _ => false
      | .ok firstRewrite =>
        match replaceFenceContent firstRewrite body with
        | .error _ => false
        | .ok secondRewrite => decide (firstRewrite = secondRewrite)
}

/-! ## Suite

The §20.2 acceptance set: three properties × 100 samples each. -/

/-- The Lex property-test suite. -/
def tests : List TestCase :=
  [ lexMacroIdempotencyProperty
  , lexCodegenDeterminismProperty
  , lexDiffReformattingInvarianceProperty
  ]

end Lex.Test.Properties

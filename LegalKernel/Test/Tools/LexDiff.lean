/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Tools.LexDiff — Workstream-LX (M3) tests for the
`lex_diff` binary.

Covers LX.34 / LX.35:

  * Per-clause structural diff detection.
  * Reformatting invariance (whitespace-only changes produce
    empty diffs).
  * Version-bump classifier: `patch` / `minor` / `major` /
    `none_` per the canonical scenarios in §14.2.
  * Refinement-proof obligation (L016).
  * Version-declaration mismatch (L007).
  * Deployment-level diff (added / removed / modified laws).
-/

import LegalKernel.Test.Framework
import Tools.LexDiff

namespace LegalKernel.Test.Tools
namespace LexDiffTests

open LegalKernel.Test
open LegalKernel.Tools.Lex
open LegalKernel.Tools.Lex.Diff

/-! ## Fixtures: hand-built `LawDecl` values -/

/-- A canonical `LawDecl` for testing.  Keep the fixture small so
    test assertions are easy to read. -/
def fixtureLawDecl : LawDecl := {
  schemaVersion := 1,
  identifier := "example.transfer",
  version := "1.0.0",
  actionIndex := 17,
  intent := "Move balance between actors at a resource.",
  params := [],
  signedBy := { name := "sender" },
  authorizedBy := { expr := "(fun _ _ => True)" },
  preExpr := "amount > 0",
  implBlock := "fun s => s",
  satisfies := [{ name := "conservative", args := [] }],
  eventsBlock := "[]",
  registryEffect := .none_,
  proofOverrides := [],
  sourceLocation := { fileName := "<test>", startPos := { line := 1, column := 0 } }
}

/-! ## LX.34 — clause-diff detection -/

/-- Two equal `LawDecl`s produce an empty clause-diff list. -/
def emptyDiffOnEqual : TestCase := {
  name := "LX.34: equal LawDecls produce empty clause-diff"
  body := do
    let diffs := computeClauseDiffs fixtureLawDecl fixtureLawDecl
    assertEq (expected := 0) (actual := diffs.length)
      "no diffs on equal inputs"
}

/-- A `pre` change produces exactly one clause-diff. -/
def preChangeDiff : TestCase := {
  name := "LX.34: pre change produces single clause-diff"
  body := do
    let after := { fixtureLawDecl with
      preExpr := "amount > 0 ∧ amount ≤ 2^32" }
    let diffs := computeClauseDiffs fixtureLawDecl after
    assertEq (expected := 1) (actual := diffs.length) "1 diff"
    let head := diffs.head!
    assertEq (expected := "pre") (actual := head.field) "field is pre"
}

/-- An `intent` change produces exactly one clause-diff. -/
def intentChangeDiff : TestCase := {
  name := "LX.34: intent change produces single clause-diff"
  body := do
    let after := { fixtureLawDecl with
      intent := "Move balance with new constraint." }
    let diffs := computeClauseDiffs fixtureLawDecl after
    assertEq (expected := 1) (actual := diffs.length) "1 diff"
    assertEq (expected := "intent") (actual := diffs.head!.field) "field is intent"
}

/-- An `action_index` change produces exactly one clause-diff. -/
def actionIndexChangeDiff : TestCase := {
  name := "LX.34: action_index change produces single clause-diff"
  body := do
    let after := { fixtureLawDecl with actionIndex := 18 }
    let diffs := computeClauseDiffs fixtureLawDecl after
    assertEq (expected := 1) (actual := diffs.length) "1 diff"
    assertEq (expected := "action_index") (actual := diffs.head!.field) "field"
}

/-- Multiple clause changes produce multiple clause-diffs. -/
def multipleClauseChangeDiff : TestCase := {
  name := "LX.34: multiple clause changes produce multiple clause-diffs"
  body := do
    let after := { fixtureLawDecl with
      version := "2.0.0",
      preExpr := "amount > 5",
      implBlock := "fun s => setBalance s 0 0 0",
      intent := "completely rewritten" }
    let diffs := computeClauseDiffs fixtureLawDecl after
    -- Expect: version, pre, impl, intent (4 diffs)
    assertEq (expected := 4) (actual := diffs.length) "4 diffs"
}

/-! ## LX.35 — version-bump classifier -/

/-- Classifying equal LawDecls returns `.none_`. -/
def classifyNoneOnEqual : TestCase := {
  name := "LX.35: classifyVersionBump returns .none_ on equal inputs"
  body := do
    let bump := classifyVersionBump fixtureLawDecl fixtureLawDecl
    assertEq (expected := VersionBump.none_) (actual := bump) "bump = none_"
}

/-- A pre-only change classifies as `.minor`. -/
def classifyMinorOnPreOnly : TestCase := {
  name := "LX.35: classifyVersionBump returns .minor on pre-only change"
  body := do
    let after := { fixtureLawDecl with
      version := "1.1.0",
      preExpr := "amount > 0 ∧ amount ≤ 2^32" }
    let bump := classifyVersionBump fixtureLawDecl after
    assertEq (expected := VersionBump.minor) (actual := bump)
      "bump = minor (refinement)"
}

/-- A satisfies-additions-only change classifies as `.minor`. -/
def classifyMinorOnSatisfiesAdditions : TestCase := {
  name := "LX.35: classifyVersionBump returns .minor on satisfies additions"
  body := do
    let after := { fixtureLawDecl with
      version := "1.1.0",
      satisfies := fixtureLawDecl.satisfies ++ [{ name := "monotonic", args := [] }] }
    let bump := classifyVersionBump fixtureLawDecl after
    assertEq (expected := VersionBump.minor) (actual := bump)
      "bump = minor (satisfies extension)"
}

/-- A proof-only change classifies as `.patch`. -/
def classifyPatchOnProofOnly : TestCase := {
  name := "LX.35: classifyVersionBump returns .patch on proof-only change"
  body := do
    let after := { fixtureLawDecl with
      version := "1.0.1",
      proofOverrides := [{ property := "conservative",
                           tacticBlock := "by simp" }] }
    let bump := classifyVersionBump fixtureLawDecl after
    assertEq (expected := VersionBump.patch) (actual := bump)
      "bump = patch (proof-only)"
}

/-- An impl change classifies as `.major`. -/
def classifyMajorOnImplChange : TestCase := {
  name := "LX.35: classifyVersionBump returns .major on impl change"
  body := do
    let after := { fixtureLawDecl with
      version := "2.0.0",
      implBlock := "fun s => setBalance s 99 99 0" }
    let bump := classifyVersionBump fixtureLawDecl after
    assertEq (expected := VersionBump.major) (actual := bump)
      "bump = major (impl change)"
}

/-- A signed_by change classifies as `.major`. -/
def classifyMajorOnSignedByChange : TestCase := {
  name := "LX.35: classifyVersionBump returns .major on signed_by change"
  body := do
    let after := { fixtureLawDecl with
      version := "2.0.0",
      signedBy := { name := "different_actor" } }
    let bump := classifyVersionBump fixtureLawDecl after
    assertEq (expected := VersionBump.major) (actual := bump)
      "bump = major (signed_by change)"
}

/-- A satisfies-removal change classifies as `.major`. -/
def classifyMajorOnSatisfiesRemoval : TestCase := {
  name := "LX.35: classifyVersionBump returns .major on satisfies removal"
  body := do
    -- Build before with two claims, after with one (i.e. removal).
    let before := { fixtureLawDecl with
      satisfies := [{ name := "conservative", args := [] },
                    { name := "monotonic", args := [] }] }
    let after := { fixtureLawDecl with
      version := "2.0.0",
      satisfies := [{ name := "conservative", args := [] }] }
    let bump := classifyVersionBump before after
    assertEq (expected := VersionBump.major) (actual := bump)
      "bump = major (claim removed)"
}

/-! ## LX.35 — refinement proof check (L016) -/

/-- A LawDecl with the matching refinement proof has the proof. -/
def refinementProofPresent : TestCase := {
  name := "LX.35: hasRefinementProof returns true when proof is present"
  body := do
    let after := { fixtureLawDecl with
      version := "1.1.0",
      proofOverrides := [{ property := "refinement_v1_0",
                           tacticBlock := "by intro h; exact h.left" }] }
    assert (hasRefinementProof "1.0.0" after)
      "refinement_v1_0 should be present"
}

/-- A LawDecl with no refinement proof returns false. -/
def refinementProofMissing : TestCase := {
  name := "LX.35: hasRefinementProof returns false when proof is missing"
  body := do
    let after := { fixtureLawDecl with version := "1.1.0" }
    assert (!hasRefinementProof "1.0.0" after)
      "refinement_v1_0 should be missing"
}

/-- The expected refinement proof name is `refinement_v<MAJ>_<MIN>`. -/
def refinementProofNameShape : TestCase := {
  name := "LX.35: refinementProofName produces refinement_v<MAJ>_<MIN>"
  body := do
    assertEq (expected := "refinement_v1_0")
             (actual := refinementProofName "1.0.0") "1.0.0"
    assertEq (expected := "refinement_v2_3")
             (actual := refinementProofName "2.3.4") "2.3.4"
}

/-! ## Manifest-level deployment diff -/

/-- Computing a deployment-diff with a single law unchanged
    produces an empty diff. -/
def deploymentDiffEmptyOnEqual : TestCase := {
  name := "LX.34: deployment-diff is empty when both refs equal"
  body := do
    let diff := computeDeploymentDiff [fixtureLawDecl] [fixtureLawDecl]
    assertEq (expected := 0) (actual := diff.lawsAdded.length) "0 added"
    assertEq (expected := 0) (actual := diff.lawsRemoved.length) "0 removed"
    assertEq (expected := 0) (actual := diff.lawsModified.length) "0 modified"
}

/-- A new law in the after-list shows up in `lawsAdded`. -/
def deploymentDiffAdded : TestCase := {
  name := "LX.34: deployment-diff detects added laws"
  body := do
    let added := { fixtureLawDecl with
      identifier := "example.new_law", actionIndex := 18 }
    let diff := computeDeploymentDiff [fixtureLawDecl]
                                       [fixtureLawDecl, added]
    assertEq (expected := 1) (actual := diff.lawsAdded.length) "1 added"
    assertEq (expected := "example.new_law")
             (actual := diff.lawsAdded.head!) "added law id"
}

/-- A removed law in the after-list shows up in `lawsRemoved`. -/
def deploymentDiffRemoved : TestCase := {
  name := "LX.34: deployment-diff detects removed laws"
  body := do
    let removed := { fixtureLawDecl with
      identifier := "example.sunset_law", actionIndex := 99 }
    let diff := computeDeploymentDiff [fixtureLawDecl, removed]
                                       [fixtureLawDecl]
    assertEq (expected := 1) (actual := diff.lawsRemoved.length) "1 removed"
    assertEq (expected := "example.sunset_law")
             (actual := diff.lawsRemoved.head!) "removed law id"
}

/-- A modified law shows up in `lawsModified` with the correct
    diff. -/
def deploymentDiffModified : TestCase := {
  name := "LX.34: deployment-diff detects modified laws"
  body := do
    let after := { fixtureLawDecl with
      version := "1.1.0",
      preExpr := "amount > 0 ∧ amount ≤ 2^32" }
    let diff := computeDeploymentDiff [fixtureLawDecl] [after]
    assertEq (expected := 1) (actual := diff.lawsModified.length) "1 modified"
    let modified := diff.lawsModified.head!
    assertEq (expected := "1.0.0") (actual := modified.versionBefore) "before"
    assertEq (expected := "1.1.0") (actual := modified.versionAfter) "after"
    assertEq (expected := VersionBump.minor) (actual := modified.versionBump) "minor"
}

/-! ## Output formatting -/

/-- A non-empty diff produces non-empty formatted output. -/
def formatLawDiffNonEmpty : TestCase := {
  name := "LX.34: formatLawDiff produces non-empty output for non-empty diff"
  body := do
    let after := { fixtureLawDecl with
      version := "1.1.0",
      preExpr := "amount > 0 ∧ amount ≤ 2^32" }
    let diff := computeDeploymentDiff [fixtureLawDecl] [after]
    let modified := diff.lawsModified.head!
    let output := formatLawDiff modified
    assert (!output.isEmpty) "format output is non-empty"
    assert (output.contains '\n') "format output contains newlines"
}

/-! ## Reformatting invariance (the empty-output case) -/

/-- Reformatting-only changes produce no clause diffs.  V1 tests
    this via the structural-diff check: same `LawDecl` structure
    yields no diffs regardless of the *source* whitespace
    (the JSON form already canonicalises whitespace for surface
    text fields). -/
def reformattingProducesEmptyDiff : TestCase := {
  name := "LX.34: reformatting-only diff is empty (structural)"
  body := do
    -- Reformatting is captured by JSON's compress/parse: the
    -- LawDecl structure is byte-equal regardless of source
    -- whitespace.  We test this by encoding/decoding and
    -- diffing the round-trip.
    let json := LawDecl.toCanonicalJson fixtureLawDecl
    match LawDecl.fromJson json with
    | .ok decoded =>
      let diffs := computeClauseDiffs fixtureLawDecl decoded
      assertEq (expected := 0) (actual := diffs.length)
        "round-tripped LawDecl is byte-stable, so no diffs"
    | .error msg =>
      throw (IO.userError s!"unexpected decode failure: {msg}")
}

/-! ## VersionBump display -/

/-- `VersionBump.toDisplay` returns canonical strings. -/
def versionBumpToDisplay : TestCase := {
  name := "LX.35: VersionBump.toDisplay strings"
  body := do
    assertEq (expected := "none") (actual := VersionBump.none_.toDisplay) "none"
    assertEq (expected := "patch") (actual := VersionBump.patch.toDisplay) "patch"
    assertEq (expected := "minor") (actual := VersionBump.minor.toDisplay) "minor"
    assertEq (expected := "major") (actual := VersionBump.major.toDisplay) "major"
}

/-! ## Combined test suite -/

/-- The complete LX.34 / LX.35 test suite. -/
def tests : List TestCase :=
  [ emptyDiffOnEqual,
    preChangeDiff,
    intentChangeDiff,
    actionIndexChangeDiff,
    multipleClauseChangeDiff,
    classifyNoneOnEqual,
    classifyMinorOnPreOnly,
    classifyMinorOnSatisfiesAdditions,
    classifyPatchOnProofOnly,
    classifyMajorOnImplChange,
    classifyMajorOnSignedByChange,
    classifyMajorOnSatisfiesRemoval,
    refinementProofPresent,
    refinementProofMissing,
    refinementProofNameShape,
    deploymentDiffEmptyOnEqual,
    deploymentDiffAdded,
    deploymentDiffRemoved,
    deploymentDiffModified,
    formatLawDiffNonEmpty,
    reformattingProducesEmptyDiff,
    versionBumpToDisplay ]

end LexDiffTests
end LegalKernel.Test.Tools

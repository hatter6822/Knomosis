/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.LexDiff — the Workstream-LX `lex_diff` semantic-diff binary.

LX.34 / LX.35 (`docs/lex_implementation_plan.md` §14).

Walks two checked-in trees of `LegalKernel/_lex_inputs/*.json`
files (one for the "before" git ref, one for the "after"), computes
a per-law / per-manifest semantic diff, and emits the diff to
stdout in the §14.1 format.

The diff is computed on the **parsed AST** (`LawDecl` records),
not on raw source bytes — so reformatting and comment-only changes
do not appear in the output.

# Capabilities

  * Per-clause diff: identifier, version, action_index, intent,
    signed_by, authorized_by, pre_expr, impl_block, satisfies,
    events_block, registry_effect, params, proof_overrides.
  * Version-bump classifier: deterministic mapping of a `LawDiff`
    to one of `patch` / `minor` / `major` per §14.2.
  * Refinement-proof check: a minor-bump-classified law must
    declare a `lex_proof refinement_v<old> := ...` clause; missing
    proofs fire L016.
  * Version-declaration check: confirms the declared version bump
    matches the classifier's; mismatch fires L007.
  * Manifest-level diff: a `DeploymentDiff` record covering law-
    set / authority-set / claim-set additions and removals.

# Exit codes (§14.1)

  * `0` — diff produced successfully (zero or more changes).
  * `1` — version-bump declaration mismatch (L007) OR missing
    refinement proof for a minor bump (L016).
  * `2` — internal binary failure (cannot read a file, malformed
    JSON, etc.).

# Usage

  ```
  lake exe lex_diff <before-dir> <after-dir>
  lake exe lex_diff --help
  ```

The `<before-dir>` and `<after-dir>` paths point at directories
containing `*.json` codegen-input files (typically extracted from
two git refs by an external script).  The binary itself does not
shell out to git — extraction is the caller's responsibility.

This module is **not** part of the trusted computing base.  Bugs
produce wrong audit-binary output (false positives / negatives at
governance gates) but cannot violate any kernel invariant.
-/

import Tools.LexCommon

namespace LegalKernel.Tools.Lex.Diff

open System (FilePath)
open LegalKernel.Tools.Lex

/-! ## Per-clause diff representation -/

/-- A single per-clause diff: the field name plus the before /
    after surface text.  V1 emits the full text in a single
    string (the `git diff -u` output is the caller's
    responsibility). -/
structure ClauseDiff where
  /-- The field name being diffed. -/
  field : String
  /-- The "before" surface text. -/
  before : String
  /-- The "after" surface text. -/
  after : String
  deriving Repr, DecidableEq, Inhabited

/-- The version-bump category (per §14.2).  Each `LawDiff` is
    classified into exactly one of these by the static rules:

      * `patch` — proof-only changes (no `pre`/`impl`/etc. drift).
      * `minor` — refinement: `pre` strengthens, `impl` mutates
        within the same kernel-effect class, or `satisfies` adds
        items.
      * `major` — anything else.
      * `none_` — no diff (used for laws that exist in both refs
        and are byte-equal).
    -/
inductive VersionBump where
  /-- No semantic change. -/
  | none_
  /-- Patch: proof-only changes. -/
  | patch
  /-- Minor: refinement. -/
  | minor
  /-- Major: breaking change. -/
  | major
  deriving Repr, DecidableEq, Inhabited

/-- Render a `VersionBump` as a one-word display string. -/
def VersionBump.toDisplay : VersionBump → String
  | .none_  => "none"
  | .patch => "patch"
  | .minor => "minor"
  | .major => "major"

/-- A per-law structural diff: every clause's pre/post pair plus
    the classified version bump and any auxiliary diagnostics. -/
structure LawDiff where
  /-- The law's canonical identifier. -/
  identifier : String
  /-- The "before" version (semver). -/
  versionBefore : String
  /-- The "after" version (semver). -/
  versionAfter : String
  /-- The classifier's verdict on this diff. -/
  versionBump : VersionBump
  /-- Per-clause diffs.  Empty list = no changes (= `versionBump
      = .none_`). -/
  clauseDiffs : List ClauseDiff
  /-- Whether the new version supplies a `lex_proof
      refinement_v<old>` clause; populated for minor-bumped laws
      only. -/
  refinementProofPresent : Bool
  deriving Repr, Inhabited

/-! ## Per-clause diff helpers -/

/-- Compute the per-clause diff between two `LawDecl`s.  Returns
    the list of clauses that differ. -/
def computeClauseDiffs (before after : LawDecl) : List ClauseDiff := Id.run do
  let mut diffs : List ClauseDiff := []
  if before.identifier != after.identifier then
    diffs := diffs ++ [{ field := "identifier",
                         before := before.identifier,
                         after := after.identifier }]
  if before.version != after.version then
    diffs := diffs ++ [{ field := "version",
                         before := before.version,
                         after := after.version }]
  if before.actionIndex != after.actionIndex then
    diffs := diffs ++ [{ field := "action_index",
                         before := toString before.actionIndex,
                         after := toString after.actionIndex }]
  if before.intent != after.intent then
    diffs := diffs ++ [{ field := "intent",
                         before := before.intent,
                         after := after.intent }]
  if before.signedBy != after.signedBy then
    diffs := diffs ++ [{ field := "signed_by",
                         before := before.signedBy.name,
                         after := after.signedBy.name }]
  if before.authorizedBy != after.authorizedBy then
    diffs := diffs ++ [{ field := "authorized_by",
                         before := before.authorizedBy.expr,
                         after := after.authorizedBy.expr }]
  if before.preExpr != after.preExpr then
    diffs := diffs ++ [{ field := "pre",
                         before := before.preExpr,
                         after := after.preExpr }]
  if before.implBlock != after.implBlock then
    diffs := diffs ++ [{ field := "impl",
                         before := before.implBlock,
                         after := after.implBlock }]
  if before.satisfies != after.satisfies then
    let beforeStr := String.intercalate ", "
      (before.satisfies.map (fun c => c.name))
    let afterStr := String.intercalate ", "
      (after.satisfies.map (fun c => c.name))
    diffs := diffs ++ [{ field := "satisfies",
                         before := beforeStr,
                         after := afterStr }]
  if before.eventsBlock != after.eventsBlock then
    diffs := diffs ++ [{ field := "events",
                         before := before.eventsBlock,
                         after := after.eventsBlock }]
  if before.registryEffect != after.registryEffect then
    diffs := diffs ++ [{ field := "registry_effect",
                         before := toString (repr before.registryEffect),
                         after := toString (repr after.registryEffect) }]
  if before.params != after.params then
    let beforeStr := String.intercalate ", "
      (before.params.map (fun p => p.name))
    let afterStr := String.intercalate ", "
      (after.params.map (fun p => p.name))
    diffs := diffs ++ [{ field := "params",
                         before := beforeStr,
                         after := afterStr }]
  if before.proofOverrides != after.proofOverrides then
    let beforeStr := String.intercalate ", "
      (before.proofOverrides.map (fun o => o.property))
    let afterStr := String.intercalate ", "
      (after.proofOverrides.map (fun o => o.property))
    diffs := diffs ++ [{ field := "proof_overrides",
                         before := beforeStr,
                         after := afterStr }]
  pure diffs

/-! ## Version-bump classifier (LX.35) -/

/-- True if the only clause-diffs are in proof-related fields
    (currently just `proof_overrides`).  Patch-bump trigger. -/
def isProofOnlyDiff (diffs : List ClauseDiff) : Bool :=
  diffs.all (fun d => d.field == "proof_overrides")

/-- True if `pre` is the only mutated clause aside from `version`
    (which is a counter-side-effect of any change).  Minor-bump
    candidate when combined with `satisfies`-only-additions. -/
def isPreOnlyDiff (diffs : List ClauseDiff) : Bool :=
  let nonVersion := diffs.filter (fun d => d.field != "version")
  nonVersion.length == 1 && (nonVersion.head?).map (·.field) == some "pre"

/-- True if `satisfies` is the only mutated clause aside from
    `version` AND it is monotonically extended (no removals). -/
def isSatisfiesAdditionsOnlyDiff (before after : LawDecl)
    (diffs : List ClauseDiff) : Bool :=
  let nonVersion := diffs.filter (fun d => d.field != "version")
  if nonVersion.length != 1 then false
  else
    if (nonVersion.head?).map (·.field) != some "satisfies" then false
    else
      -- Check that every claim in `before.satisfies` is also in
      -- `after.satisfies` (monotonic extension).
      before.satisfies.all (fun bc =>
        after.satisfies.any (fun ac =>
          ac.name == bc.name && ac.args == bc.args))

/-- Classify a per-law diff into a version-bump category per
    §14.2.  Deterministic mapping. -/
def classifyVersionBump (before after : LawDecl) : VersionBump :=
  let diffs := computeClauseDiffs before after
  if diffs.isEmpty then .none_
  else
    -- Filter out the `version` clause itself (its mutation is
    -- a side-effect of any other change, not the cause).
    let semanticDiffs := diffs.filter (fun d => d.field != "version")
    if semanticDiffs.isEmpty then .none_  -- only `version` changed
    else if isProofOnlyDiff semanticDiffs then .patch
    else if isPreOnlyDiff diffs then .minor
    else if isSatisfiesAdditionsOnlyDiff before after diffs then .minor
    else .major

/-! ## Refinement-proof obligation (LX.35)

When a minor bump is detected, `lex_diff` checks for the presence
of a `lex_proof refinement_v<old> := ...` clause in the new
version.  Missing proof emits L016.

The plan §14.3 specifies that the proof name is `refinement_v<old>`
where `<old>` is the previous version's `<MAJOR>.<MINOR>` (no
patch).  E.g., refining `1.0.x → 1.1.0` requires
`lex_proof refinement_v1_0 := ...`. -/

/-- Extract the refinement-proof name from a version string.
    `"1.0.0"` → `"refinement_v1_0"`. -/
def refinementProofName (oldVersion : String) : String :=
  let parts := oldVersion.splitOn "."
  match parts with
  | [maj, min, _]      => s!"refinement_v{maj}_{min}"
  | [maj, min]         => s!"refinement_v{maj}_{min}"
  | _                  => "refinement_v" ++ oldVersion.replace "." "_"

/-- True iff `after.proofOverrides` contains a `refinement_v<old>`
    entry. -/
def hasRefinementProof (oldVersion : String) (after : LawDecl) : Bool :=
  let expectedName := refinementProofName oldVersion
  after.proofOverrides.any (fun o => o.property == expectedName)

/-! ## Manifest-level diff -/

/-- A per-deployment diff: which laws were added / removed /
    modified, plus authority and claim-set diffs.  Manifests are
    NOT part of the codegen-input directory in v1; this record is
    populated only when both inputs include a manifest sidecar
    (deferred to v2). -/
structure DeploymentDiff where
  /-- Laws added in the after version. -/
  lawsAdded : List String
  /-- Laws removed (sunset) in the after version. -/
  lawsRemoved : List String
  /-- Laws present in both but with structural changes. -/
  lawsModified : List LawDiff
  deriving Repr, Inhabited

/-! ## File I/O for the binary -/

/-- Load all `*.json` codegen-input files under a directory and
    parse each into a `LawDecl`.  Returns the list keyed by
    `identifier` (so two refs' inputs can be cross-referenced
    without scanning lists). -/
def loadCodegenDir (dir : FilePath) :
    IO (Except String (List LawDecl)) := do
  if !(← dir.pathExists) then
    return .ok []
  let entries ← dir.readDir
  let mut decls : List LawDecl := []
  for entry in entries do
    let path := entry.path
    if path.extension == some "json" then
      let contents ← IO.FS.readFile path
      match LawDecl.fromJson contents with
      | .ok decl => decls := decls ++ [decl]
      | .error msg =>
        return .error s!"failed to parse {path.toString}: {msg}"
  return .ok decls

/-! ## Diff computation between two directories -/

/-- The set of all law identifiers in a directory's `LawDecl`
    list. -/
def lawIdentifiers (decls : List LawDecl) : List String :=
  decls.map (·.identifier)

/-- Compute a `DeploymentDiff` by comparing two `LawDecl` lists. -/
def computeDeploymentDiff (before after : List LawDecl) :
    DeploymentDiff := Id.run do
  let beforeIds := lawIdentifiers before
  let afterIds := lawIdentifiers after
  -- Added: in `after` but not in `before`.
  let added := afterIds.filter (fun id => !beforeIds.contains id)
  -- Removed: in `before` but not in `after`.
  let removed := beforeIds.filter (fun id => !afterIds.contains id)
  -- Modified: in both but with non-empty diff.
  let mut modified : List LawDiff := []
  for b in before do
    if let some a := after.find? (fun d => d.identifier == b.identifier) then
      let cdiffs := computeClauseDiffs b a
      let bump := classifyVersionBump b a
      if !cdiffs.isEmpty then
        let hasProof := hasRefinementProof b.version a
        modified := modified ++ [{
          identifier := b.identifier,
          versionBefore := b.version,
          versionAfter := a.version,
          versionBump := bump,
          clauseDiffs := cdiffs,
          refinementProofPresent := hasProof
        }]
  pure { lawsAdded := added, lawsRemoved := removed, lawsModified := modified }

/-! ## Output formatting (§14.1) -/

/-- Format a single `LawDiff` per §14.1.  Result ends with a
    newline.

    The output format mirrors the design-doc §14.1 example:

      ```
      legalkernel.transfer:
        version: 1.0.0 → 1.1.0   (minor — refinement)
        pre:                     diff:
          @@ -1,2 +1,3 @@
             amount > 0
             ∧ getBalance s r sender ≥ amount
          +  ∧ amount ≤ 2^32
        impl: unchanged
        satisfies: unchanged
        events: unchanged
        intent: unchanged
      ```

    V1 emits a simplified form: per-clause `before → after`
    pairs, no unified-diff hunks (the caller can pipe through
    `git diff` for richer output). -/
def formatLawDiff (diff : LawDiff) : String :=
  let header := s!"{diff.identifier}:\n"
  let versionLine :=
    s!"  version: {diff.versionBefore} → {diff.versionAfter}   ({diff.versionBump.toDisplay})\n"
  -- Skip the redundant `version` clause-diff line (it's already
  -- printed in the version-line header above).
  let semanticDiffs := diff.clauseDiffs.filter (fun cd => cd.field != "version")
  let clauseLines := String.join (semanticDiffs.map (fun cd =>
    s!"  {cd.field}: {cd.before} → {cd.after}\n"))
  let refinementLine :=
    if diff.versionBump == .minor then
      if diff.refinementProofPresent then
        "  refinement_proof: PRESENT\n"
      else
        s!"  refinement_proof: MISSING (L016)\n"
    else ""
  header ++ versionLine ++ clauseLines ++ refinementLine

/-- Format a `DeploymentDiff` per §14.4. -/
def formatDeploymentDiff (diff : DeploymentDiff) : String :=
  let added := String.join (diff.lawsAdded.map (fun id => s!"  + {id}\n"))
  let removed := String.join (diff.lawsRemoved.map (fun id => s!"  - {id}\n"))
  let modified := String.join (diff.lawsModified.map formatLawDiff)
  s!"== Deployment Diff ==\n" ++
  (if !added.isEmpty then s!"Laws added:\n{added}" else "") ++
  (if !removed.isEmpty then s!"Laws removed:\n{removed}" else "") ++
  (if !modified.isEmpty then s!"Laws modified:\n{modified}" else "") ++
  (if added.isEmpty && removed.isEmpty && modified.isEmpty then
    "(no changes)\n" else "")

/-! ## Diagnostic emission for L007 / L016 -/

/-- A diagnostic representing a version-bump declaration mismatch
    (L007). -/
def L007Diagnostic (path : String) (lawId : String)
    (declared computed : VersionBump) : Diagnostic :=
  { code := "L007",
    severity := .error,
    source := { fileName := path, startPos := { line := 1, column := 0 } },
    message :=
      s!"law `{lawId}` declared version-bump `{declared.toDisplay}` but classifier computed `{computed.toDisplay}`",
    notes := [],
    hints := ["update the version field to match the computed bump, or restructure the diff to match the declared bump"]
  }

/-- A diagnostic representing a missing refinement proof (L016). -/
def L016Diagnostic (path : String) (lawId : String)
    (oldVersion : String) : Diagnostic :=
  { code := "L016",
    severity := .error,
    source := { fileName := path, startPos := { line := 1, column := 0 } },
    message :=
      s!"law `{lawId}` minor-bumped from {oldVersion} but is missing a refinement proof",
    notes := [],
    hints := [s!"add `lex_proof {refinementProofName oldVersion} := by ...` to the law's `lexlaw` block"]
  }

/-! ## Main entry point -/

/-- Print `--help` text and exit 0. -/
def printHelp : IO UInt32 := do
  IO.println "lex_diff — Workstream LX (LX.34/LX.35) semantic-diff binary"
  IO.println ""
  IO.println "Usage: lake exe lex_diff <before-dir> <after-dir>"
  IO.println "       lake exe lex_diff --help"
  IO.println ""
  IO.println "Compares two trees of LegalKernel/_lex_inputs/*.json files"
  IO.println "(typically extracted from two git refs by an external script)"
  IO.println "and emits a per-law / per-manifest semantic diff."
  IO.println ""
  IO.println "The diff is computed on the parsed AST, not on raw source"
  IO.println "bytes — so reformatting and comment-only changes do not"
  IO.println "appear in the output."
  IO.println ""
  IO.println "Exit codes:"
  IO.println "  0  diff produced (zero or more changes)."
  IO.println "  1  L007 (declared-vs-computed bump mismatch) or"
  IO.println "     L016 (missing refinement proof)."
  IO.println "  2  internal failure (malformed JSON, missing dir)."
  return 0

/-- Validate a deployment diff: surface L007 (mismatch) and L016
    (missing proof) violations as diagnostics.  Returns the list
    of diagnostics. -/
def validateDeploymentDiff (diff : DeploymentDiff)
    (afterDir : FilePath) : List Diagnostic := Id.run do
  let mut diags : List Diagnostic := []
  for ld in diff.lawsModified do
    -- L016: minor bump without refinement proof.
    if ld.versionBump == .minor && !ld.refinementProofPresent then
      diags := diags ++ [L016Diagnostic afterDir.toString
        ld.identifier ld.versionBefore]
    -- L007: declared version-bump (encoded in the version-string
    -- delta) doesn't match the computed bump.  Only check this
    -- when both versions are valid semver.
    let oldP := ld.versionBefore.splitOn "."
    let newP := ld.versionAfter.splitOn "."
    if oldP.length == 3 && newP.length == 3 then
      let declaredBump : Option VersionBump :=
        if oldP.head! != newP.head! then some .major
        else if oldP[1]! != newP[1]! then some .minor
        else if oldP[2]! != newP[2]! then some .patch
        else some .none_
      match declaredBump with
      | some db =>
        if db != ld.versionBump then
          diags := diags ++ [L007Diagnostic afterDir.toString
            ld.identifier db ld.versionBump]
      | none => pure ()
  pure diags

/-- Main entry.  Compares two directories of codegen-input JSONs.

    Exit codes:

      0 — diff produced successfully.
      1 — L007 / L016 violations detected.
      2 — internal failure.
    -/
def main (args : List String) : IO UInt32 := do
  if args.contains "--help" || args.contains "-h" then
    return (← printHelp)
  match args with
  | [beforeDir, afterDir] =>
    let beforeFP : FilePath := beforeDir
    let afterFP : FilePath := afterDir
    let beforeDeclsR ← loadCodegenDir beforeFP
    match beforeDeclsR with
    | .error msg =>
      IO.eprintln s!"lex_diff: failed to load `{beforeDir}`: {msg}"
      return 2
    | .ok beforeDecls =>
      let afterDeclsR ← loadCodegenDir afterFP
      match afterDeclsR with
      | .error msg =>
        IO.eprintln s!"lex_diff: failed to load `{afterDir}`: {msg}"
        return 2
      | .ok afterDecls =>
        let diff := computeDeploymentDiff beforeDecls afterDecls
        IO.print (formatDeploymentDiff diff)
        let diags := validateDeploymentDiff diff afterFP
        for d in diags do
          IO.print d.format
        if diags.any (fun d => d.severity == .error) then
          return 1
        return 0
  | _ =>
    IO.eprintln "Usage: lake exe lex_diff <before-dir> <after-dir>"
    IO.eprintln "       lake exe lex_diff --help"
    return 2

end LegalKernel.Tools.Lex.Diff

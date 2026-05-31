-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Tools.Diff — the Workstream-LX `lex_diff` semantic-diff binary.

LX.34 / LX.35 (`docs/planning/lex_implementation_plan.md` §14).

Walks two trees of `Lex/Inputs/*.json` files (or
two git refs), computes a per-law / per-manifest semantic diff,
and emits the diff to stdout in the §14.1 format.

# Capabilities (post-M3-completion)

  * **Two input modes (LX.34)**: takes two directory paths
    OR two git refs (`<ref>:<dir>`).  In git-ref mode, runs
    `git show <ref>:<file>` to extract sidecars at the named
    revision.
  * **Per-clause structural diff**: AST-level comparison of
    `pre_ast`, `impl_calculus`, `events`, `satisfies`,
    `signed_by`, `authorized_by`, `intent`, `version`,
    `action_index`, `params`, `proof_overrides`,
    `registry_effect`.
  * **`LawDiff` per-clause `Option Diff` shape (LX.34 spec)**:
    each clause's diff (or `none` if unchanged) is exposed as a
    named field.
  * **Version-bump classifier**: `classifyVersionBump :
    LawDiff → VersionBump`.
  * **Refinement-proof check (LX.35)**: `checkRefinementProof :
    LawDecl → IO Bool`.
  * **Version-declaration mismatch**: `checkVersionDeclaration
    : LawDiff → Except Diagnostic Unit`.
  * **Manifest-level diff (LX.35)**: `DeploymentDiff` covering
    laws / authority bindings / invariant claims.

# Exit codes (§14.1)

  * `0` — diff produced successfully (zero or more changes).
  * `1` — version-bump declaration mismatch (L007) OR missing
    refinement proof for a minor bump (L016).
  * `2` — internal binary failure (cannot read a file, malformed
    JSON, missing git, etc.).

# Usage

  ```
  lake exe lex_diff <before-dir> <after-dir>
  lake exe lex_diff --git <ref-a> <ref-b>
  lake exe lex_diff --help
  ```

This module is **not** part of the trusted computing base.  Bugs
produce wrong audit-binary output (false positives / negatives at
governance gates) but cannot violate any kernel invariant.
-/

import Lex.Tools.Common
import Lex.DSL.Deployment

namespace LegalKernel.Tools.Lex.Diff

open System (FilePath)
open LegalKernel.Tools.Lex

/-! ## Per-clause diff representation (LX.34 spec shape) -/

/-- A single "Diff" — a before / after string pair.  Used per
    clause in the spec's `Option Diff` per-field shape. -/
structure Diff where
  /-- The "before" surface text. -/
  before : String
  /-- The "after" surface text. -/
  after : String
  deriving Repr, DecidableEq, Inhabited

/-- The version-bump category (per §14.2). -/
inductive VersionBump where
  /-- No semantic change. -/
  | none_
  /-- Patch: proof-only changes. -/
  | patch
  /-- Minor: refinement-shaped. -/
  | minor
  /-- Major: breaking change. -/
  | major
  deriving Repr, DecidableEq, Inhabited

/-- Render a `VersionBump` as a one-word display string. -/
def VersionBump.toDisplay : VersionBump → String
  | .none_ => "none"
  | .patch => "patch"
  | .minor => "minor"
  | .major => "major"

/-- A per-law structural diff (LX.34 spec shape).  Each clause
    has its own `Option Diff` field; `none` means unchanged. -/
structure LawDiff where
  /-- The law's canonical identifier. -/
  identifier : String
  /-- The "before" version. -/
  versionBefore : String
  /-- The "after" version. -/
  versionAfter : String
  /-- The classifier's verdict. -/
  versionBump : VersionBump
  /-- Pre-clause diff (`pre_expr`). -/
  preDiff : Option Diff
  /-- Impl-clause diff (`impl_block`). -/
  implDiff : Option Diff
  /-- Satisfies-clause diff. -/
  satisfiesDiff : Option Diff
  /-- Events-clause diff. -/
  eventsDiff : Option Diff
  /-- Intent-clause diff. -/
  intentDiff : Option Diff
  /-- Signed-by-clause diff. -/
  signedByDiff : Option Diff
  /-- Authorized-by-clause diff. -/
  authDiff : Option Diff
  /-- Action-index diff. -/
  actionIndexDiff : Option Diff
  /-- Params-clause diff. -/
  paramsDiff : Option Diff
  /-- Proof-overrides diff. -/
  proofOverridesDiff : Option Diff
  /-- Registry-effect diff. -/
  registryEffectDiff : Option Diff
  /-- Whether the new version supplies a `lex_proof
      refinement_v<MAJ>_<MIN>` clause. -/
  refinementProofPresent : Bool
  deriving Repr, Inhabited

/-! ## Per-clause diff helpers -/

/-- Compare two `String` values, returning `none` if equal,
    else `some Diff`. -/
def diffString (before after : String) : Option Diff :=
  if before == after then none
  else some { before, after }

/-- Compute a `LawDiff` from two `LawDecl`s.  Each clause is
    diffed independently. -/
def computeLawDiff (before after : LawDecl) : LawDiff :=
  { identifier := before.identifier,
    versionBefore := before.version,
    versionAfter := after.version,
    versionBump := .none_,  -- filled in by classifyVersionBump
    preDiff := diffString before.preExpr after.preExpr,
    implDiff := diffString before.implBlock after.implBlock,
    satisfiesDiff :=
      -- Audit-4: include args in the diff string.  Pre-fix, the
      -- diff used only `.name`, so a refinement that changed args
      -- (e.g. `local [r]` → `local [r, s]`) would silently produce
      -- an empty diff and be misclassified as "no change".
      let renderClaim (c : PropertyClaim) : String :=
        if c.args.isEmpty then c.name
        else c.name ++ "[" ++ String.intercalate "," c.args ++ "]"
      let bs := String.intercalate "," (before.satisfies.map renderClaim)
      let as := String.intercalate "," (after.satisfies.map renderClaim)
      diffString bs as,
    eventsDiff := diffString before.eventsBlock after.eventsBlock,
    intentDiff := diffString before.intent after.intent,
    signedByDiff := diffString before.signedBy.name after.signedBy.name,
    authDiff := diffString before.authorizedBy.expr after.authorizedBy.expr,
    actionIndexDiff :=
      diffString (toString before.actionIndex) (toString after.actionIndex),
    paramsDiff :=
      -- AR.7 / M-6: compare by `name:type:kind` so a type or
      -- binder-kind change surfaces as a diff entry.  The pre-AR
      -- comparator compared names only.
      let bs := String.intercalate "," (before.params.map ParamSpec.render)
      let as := String.intercalate "," (after.params.map ParamSpec.render)
      diffString bs as,
    proofOverridesDiff :=
      -- AR.7 / M-6: compare by `property:tactic-hash` so a
      -- proof-override body change surfaces even when the
      -- property name is unchanged.
      let bs := String.intercalate ","
                  (before.proofOverrides.map ProofOverride.render)
      let as := String.intercalate ","
                  (after.proofOverrides.map ProofOverride.render)
      diffString bs as,
    registryEffectDiff :=
      diffString (toString (repr before.registryEffect))
                 (toString (repr after.registryEffect)),
    refinementProofPresent := false  -- filled in below
  }

/-- True iff the diff has no semantic changes (no clause diff
    AND no version change).

    **Audit-3 bugfix**: pre-fix `isEmpty` ignored the
    `versionBefore` / `versionAfter` fields, so a pure version-
    bump (e.g. `1.0.0 → 1.0.1` with no clause changes) was
    falsely reported as "empty diff" and the law was filtered
    out of `lawsModified` by `computeLawSetDiff`.  This silently
    masked declared-vs-computed bump-mismatches (L007) for
    version-only changes AND made `lex_diff --git` claim
    "no changes" for pure version bumps. -/
def LawDiff.isEmpty (d : LawDiff) : Bool :=
  d.versionBefore == d.versionAfter ∧
  d.preDiff.isNone ∧ d.implDiff.isNone ∧ d.satisfiesDiff.isNone ∧
  d.eventsDiff.isNone ∧ d.intentDiff.isNone ∧ d.signedByDiff.isNone ∧
  d.authDiff.isNone ∧ d.actionIndexDiff.isNone ∧ d.paramsDiff.isNone ∧
  d.proofOverridesDiff.isNone ∧ d.registryEffectDiff.isNone

/-- Are the clauses unchanged except for `version` and (optionally)
    `proof_overrides` ? -/
def LawDiff.isProofOnly (d : LawDiff) : Bool :=
  d.preDiff.isNone ∧ d.implDiff.isNone ∧ d.satisfiesDiff.isNone ∧
  d.eventsDiff.isNone ∧ d.intentDiff.isNone ∧ d.signedByDiff.isNone ∧
  d.authDiff.isNone ∧ d.actionIndexDiff.isNone ∧ d.paramsDiff.isNone ∧
  d.registryEffectDiff.isNone

/-- Are the only mutated clauses `pre` and (optionally)
    `proof_overrides`? -/
def LawDiff.isPreOnly (d : LawDiff) : Bool :=
  d.preDiff.isSome ∧ d.implDiff.isNone ∧ d.satisfiesDiff.isNone ∧
  d.eventsDiff.isNone ∧ d.intentDiff.isNone ∧ d.signedByDiff.isNone ∧
  d.authDiff.isNone ∧ d.actionIndexDiff.isNone ∧ d.paramsDiff.isNone ∧
  d.registryEffectDiff.isNone

/-- Is `before.satisfies ⊆ after.satisfies` (no removals)?  Plus
    only the `satisfies` clause is mutated.

    Audit-4: equality check now correctly includes `args` so a
    same-name claim with different args is treated as a removal+
    addition (i.e. NOT additions-only). -/
def LawDiff.isSatisfiesAdditionsOnly (d : LawDiff)
    (before after : LawDecl) : Bool :=
  d.preDiff.isNone ∧ d.implDiff.isNone ∧ d.satisfiesDiff.isSome ∧
  d.eventsDiff.isNone ∧ d.intentDiff.isNone ∧ d.signedByDiff.isNone ∧
  d.authDiff.isNone ∧ d.actionIndexDiff.isNone ∧ d.paramsDiff.isNone ∧
  d.registryEffectDiff.isNone ∧
  before.satisfies.all (fun bc =>
    after.satisfies.any (fun ac =>
      ac.name == bc.name ∧ ac.args == bc.args))

/-! ## Version-bump classifier (LX.35 named-API) -/

/-- Classify a `LawDiff` (with the `before`/`after` `LawDecl`s
    available for satisfies-additions detection) into a version-
    bump category per §14.2.  Deterministic. -/
def classifyVersionBump (before after : LawDecl) : VersionBump :=
  let d := computeLawDiff before after
  if d.isEmpty then .none_
  else if d.isProofOnly then .patch
  else if d.isPreOnly then .minor
  else if d.isSatisfiesAdditionsOnly before after then .minor
  else .major

/-! ## Refinement-proof check (LX.35) -/

/-- Extract the refinement-proof name from a version string.
    `"1.0.0"` → `"refinement_v1_0"`. -/
def refinementProofName (oldVersion : String) : String :=
  let parts := oldVersion.splitOn "."
  match parts with
  | [maj, min, _]      => s!"refinement_v{maj}_{min}"
  | [maj, min]         => s!"refinement_v{maj}_{min}"
  | _                  => "refinement_v" ++ oldVersion.replace "." "_"

/-- True iff `after.proofOverrides` contains a
    `refinement_v<MAJ>_<MIN>` entry derived from
    `oldVersion`. -/
def hasRefinementProof (oldVersion : String) (after : LawDecl) : Bool :=
  let expectedName := refinementProofName oldVersion
  after.proofOverrides.any (fun o => o.property == expectedName)

/-- LX.35 named API: `checkRefinementProof : LawDecl → IO Bool`.
    Runs in `IO` because the spec calls for it; semantically
    pure, just a typed wrapper around `hasRefinementProof`. -/
def checkRefinementProof (oldVersion : String) (after : LawDecl) :
    IO Bool := do
  return hasRefinementProof oldVersion after

/-- LX.35 named API: confirms the declared version bump matches
    the classifier's; mismatch fires L007.  Returns
    `Except Diagnostic Unit` per spec. -/
def checkVersionDeclaration (filePath : String) (before after : LawDecl) :
    Except Diagnostic Unit := do
  let oldP := before.version.splitOn "."
  let newP := after.version.splitOn "."
  if oldP.length != 3 || newP.length != 3 then
    return ()  -- non-semver versions skip the check
  let declaredBump : VersionBump :=
    if oldP.head! != newP.head! then .major
    else if oldP[1]! != newP[1]! then .minor
    else if oldP[2]! != newP[2]! then .patch
    else .none_
  let computedBump := classifyVersionBump before after
  if declaredBump != computedBump then
    .error {
      code := "L007",
      severity := .error,
      source := { fileName := filePath, startPos := { line := 1, column := 0 } },
      message :=
        s!"law `{before.identifier}` declared version-bump `{declaredBump.toDisplay}` but classifier computed `{computedBump.toDisplay}`",
      notes := [],
      hints :=
        ["update the version field to match the computed bump, or restructure the diff to match the declared bump"]
    }

/-! ## Manifest-level diff (LX.35)

A `DeploymentDiff` records changes between two manifest sidecars.
The spec §14.4 calls for: laws / authority-set / claim-set
diffing, with deployment-level changes (laws or authority
mutations) triggering a major manifest bump. -/

/-- A change to an authority binding. -/
structure AuthorityBindingDiff where
  /-- The slot name (e.g. `"transfer_policy"`). -/
  slotName : String
  /-- The before/after policy expression diff. -/
  diff : Diff
  deriving Repr, Inhabited

/-- A change to an invariant claim (kind / scope / law list). -/
structure InvariantClaimDiff where
  /-- The claim kind (e.g. `"monotonic_law_set"`). -/
  kindName : String
  /-- The before/after law-name list (as comma-joined string). -/
  diff : Diff
  deriving Repr, Inhabited

/-- The full deployment-manifest diff (§14.4). -/
structure DeploymentDiff where
  /-- Laws added in the after version. -/
  lawsAdded : List String
  /-- Laws removed (sunset) in the after version. -/
  lawsRemoved : List String
  /-- Laws present in both but with structural changes. -/
  lawsModified : List LawDiff
  /-- Authority bindings added (new slots). -/
  authoritySlotsAdded : List String
  /-- Authority bindings removed. -/
  authoritySlotsRemoved : List String
  /-- Authority bindings whose policy expression changed. -/
  authoritySlotsModified : List AuthorityBindingDiff
  /-- Invariant claims added. -/
  invariantClaimsAdded : List String
  /-- Invariant claims removed. -/
  invariantClaimsRemoved : List String
  /-- Invariant claims modified (same kind, different law list). -/
  invariantClaimsModified : List InvariantClaimDiff
  deriving Repr, Inhabited

/-- True iff the manifest-diff has no deployment-level changes. -/
def DeploymentDiff.hasManifestLevelChanges (d : DeploymentDiff) : Bool :=
  !d.lawsAdded.isEmpty ∨ !d.lawsRemoved.isEmpty ∨
  !d.authoritySlotsAdded.isEmpty ∨ !d.authoritySlotsRemoved.isEmpty ∨
  !d.authoritySlotsModified.isEmpty ∨
  !d.invariantClaimsAdded.isEmpty ∨ !d.invariantClaimsRemoved.isEmpty ∨
  !d.invariantClaimsModified.isEmpty

/-- True iff manifest-level changes triggered a major manifest
    bump.  Per §14.4: adding/removing laws or authority bindings
    is major; changes within bindings are minor.

    Returns `none` if no manifest-level changes detected. -/
def DeploymentDiff.classifyManifestBump (d : DeploymentDiff) :
    Option VersionBump :=
  if !d.hasManifestLevelChanges then none
  else if !d.lawsAdded.isEmpty ∨ !d.lawsRemoved.isEmpty ∨
          !d.authoritySlotsAdded.isEmpty ∨ !d.authoritySlotsRemoved.isEmpty then
    some .major
  else
    -- Modifications only (e.g. policy-expression change in a slot).
    some .minor

/-! ## File I/O for the binary -/

/-- Load all `*.json` codegen-input files under a directory and
    parse each into a `LawDecl`. -/
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

/-! ## Git integration (LX.34 spec) -/

/-- Validate that a git ref is safe to pass to `git show` /
    `git ls-tree`.  Rejects refs that:

      * Start with `-` (would be interpreted as a flag by git's
        argument parser, allowing flag injection like
        `--upload-pack=evil`).
      * Contain ASCII control characters (defense-in-depth).
      * Are empty.

    Returns `true` if the ref is safe.

    **Threat model**: a malicious ref supplied by an untrusted
    caller (e.g. CI inputs) could exploit git's flag-parsing to
    cause arbitrary command execution via flags like
    `--upload-pack` or `--exec`.  We defend by rejecting
    flag-shaped refs at the binary boundary.

    `IO.Process.output` already passes args directly (no shell);
    this validation closes the remaining flag-injection vector. -/
def isSafeGitRef (ref : String) : Bool :=
  !ref.isEmpty ∧
  !ref.startsWith "-" ∧
  -- Reject `:` so the colon in `<ref>:<path>` is unambiguous;
  -- a ref like `HEAD~1:malicious` would otherwise smuggle a
  -- second pathspec into `git show <ref>:<path>`.
  !ref.contains ':' ∧
  -- Reject NUL and other control characters defense-in-depth.
  ref.toList.all (fun c => c.toNat ≥ 0x20 ∧ c.toNat < 0x7F)

/-- Check whether `needle` appears anywhere as a substring of
    `hay`.  Used by `isSafeGitPath` to detect embedded
    parent-directory escapes. -/
def containsSubstring (hay : String) (needle : String) : Bool :=
  let hayList := hay.toList
  let needleList := needle.toList
  let rec go (l : List Char) : Bool :=
    match l with
    | [] => needleList.isEmpty
    | _ :: tail =>
      if needleList.isPrefixOf l then true else go tail
  decreasing_by simp_wf; omega
  go hayList

/-- Validate that a git path is safe to pass as the `<path>`
    component of `git show <ref>:<path>`.  Rejects paths that:

      * Are empty (would shell-out to `git show <ref>:` which
        prints the commit object — confusing diagnostic).
      * Contain `..` segments anywhere (defense-in-depth; git's
        pathspec layer rejects path traversal but a misconfigured
        caller shouldn't even be sending these).
      * Contain ASCII control characters (NUL, \\n, \\t, etc.).

    NOTE: paths starting with `-` are SAFE here because the
    git argument is `<ref>:<path>` (always prefixed by `<ref>:`),
    so the resulting argv element is `ref:-foo` which git treats
    as a path, not a flag. -/
def isSafeGitPath (path : String) : Bool :=
  !path.isEmpty ∧
  !path.contains '\n' ∧
  !path.contains '\x00' ∧
  -- Audit-5: reject absolute paths.  `git show <ref>:<path>`
  -- expects a repo-relative path; an absolute path like
  -- `/etc/passwd` would be rejected by git's pathspec layer
  -- but the API contract is repo-relative-only.  Rejecting
  -- here gives a precise diagnostic ("unsafe path") instead
  -- of git's generic "path not in tree" error.
  !path.startsWith "/" ∧
  -- Reject Windows-style paths ('\' separator) defense-in-depth.
  !path.contains '\\' ∧
  -- Reject parent-directory escape segments anywhere in the path.
  !"../".isPrefixOf path ∧
  !path.endsWith "/.." ∧
  !containsSubstring path "/../" ∧
  path != ".." ∧
  path.toList.all (fun c => c.toNat ≥ 0x20 ∧ c.toNat < 0x7F)

/-- Run `git show <ref>:<path>` and capture stdout.  Returns
    `none` on git failure, or if the ref / path is unsafe. -/
def gitShow (ref : String) (path : String) : IO (Option String) := do
  if !isSafeGitRef ref then
    return none
  if !isSafeGitPath path then
    return none
  let proc := { cmd := "git",
                args := #["show", s!"{ref}:{path}"] : IO.Process.SpawnArgs }
  -- Audit-4: catch IO exceptions (e.g. `git` not installed,
  -- subprocess spawn failure, broken pipe).  Without this guard,
  -- a missing git binary would throw an uncaught IO error to the
  -- caller, which is expected to handle a `none` return for any
  -- recoverable failure.
  let outputResult ← (IO.Process.output proc : IO _).toBaseIO
  match outputResult with
  | .error _ => return none
  | .ok output =>
    if output.exitCode == 0 then
      return some output.stdout
    else
      return none

/-- LX.34 named API: parse a `LawDecl` from a git ref + file path.
    Uses `git show <ref>:<path>` to fetch the file at the named
    revision.

    Returns `IO LawDecl`; raises `IO.userError` on git failure,
    parse failure, OR if the ref is unsafe (flag injection
    defense). -/
def parseLawDeclFromGitRef (ref : String) (filePath : System.FilePath) :
    IO LawDecl := do
  if !isSafeGitRef ref then
    throw <| IO.userError
      s!"git ref `{ref}` is unsafe (starts with `-`, contains control chars, or is empty); refusing to pass to git for security"
  let pathStr := filePath.toString
  match (← gitShow ref pathStr) with
  | none =>
    throw <| IO.userError s!"git show {ref}:{pathStr} failed"
  | some contents =>
    match LawDecl.fromJson contents with
    | .ok decl => return decl
    | .error msg =>
      throw <| IO.userError
        s!"failed to parse {pathStr} at {ref}: {msg}"

/-- List all `*.json` files in a directory at a specific git ref.
    Uses `git ls-tree -r <ref> -- <dir>` to get the recursive
    listing.

    **Audit-3 bugfix**: pre-fix the call used `git ls-tree
    --name-only <ref> -- <dir>` WITHOUT `-r`, which returns just
    the directory entry itself (not its contents) when `<dir>` is
    a directory.  This caused `loadCodegenDirFromGitRef` to find
    zero JSON files and report "no changes" for any diff —
    silently masking real semantic changes.  The `-r` flag
    recurses into the directory. -/
def gitLsTree (ref : String) (dir : String) :
    IO (Except String (List String)) := do
  if !isSafeGitRef ref then
    return .error
      s!"git ref `{ref}` is unsafe (starts with `-`, contains `:`, contains control chars, or is empty); refusing to pass to git for security"
  if !isSafeGitPath dir then
    return .error
      s!"git pathspec `{dir}` is unsafe (empty, contains `..`, or contains control chars); refusing to pass to git for security"
  let proc := { cmd := "git",
                args := #["ls-tree", "-r", "--name-only", ref, "--", dir]
                : IO.Process.SpawnArgs }
  -- Audit-4: catch IO exceptions (e.g. `git` not installed,
  -- subprocess spawn failure).  Without this guard, a missing
  -- git binary would surface as an uncaught IO error.
  let outputResult ← (IO.Process.output proc : IO _).toBaseIO
  match outputResult with
  | .error e =>
    return .error s!"git ls-tree subprocess failed: {e.toString}"
  | .ok output =>
    if output.exitCode != 0 then
      return .error s!"git ls-tree -r {ref} -- {dir} failed: {output.stderr}"
    -- Split output by newlines; filter `*.json` files.
    let lines := output.stdout.splitOn "\n"
    let jsonFiles := lines.filter (fun l =>
      l.endsWith ".json" ∧ !l.isEmpty)
    return .ok jsonFiles

/-- Load all law sidecars from a git ref's
    `Lex/Inputs/` directory.  Returns the list of
    parsed `LawDecl`s.  Equivalent to `loadCodegenDir` but for a
    git revision. -/
def loadCodegenDirFromGitRef (ref : String)
    (dir : String := "Lex/Inputs") :
    IO (Except String (List LawDecl)) := do
  let listResult ← gitLsTree ref dir
  match listResult with
  | .error msg => return .error msg
  | .ok files =>
    let mut decls : List LawDecl := []
    for f in files do
      match (← gitShow ref f) with
      | none =>
        return .error s!"git show {ref}:{f} failed"
      | some contents =>
        match LawDecl.fromJson contents with
        | .ok decl => decls := decls ++ [decl]
        | .error msg =>
          return .error s!"failed to parse {f} at {ref}: {msg}"
    return .ok decls

/-! ## Diff computation -/

/-- The set of all law identifiers in a directory's `LawDecl`
    list. -/
def lawIdentifiers (decls : List LawDecl) : List String :=
  decls.map (·.identifier)

/-- Compute a `DeploymentDiff` for the laws portion only
    (manifest-level law-set diff). -/
def computeLawSetDiff (before after : List LawDecl) :
    DeploymentDiff := Id.run do
  let beforeIds := lawIdentifiers before
  let afterIds := lawIdentifiers after
  let added := afterIds.filter (fun id => !beforeIds.contains id)
  let removed := beforeIds.filter (fun id => !afterIds.contains id)
  let mut modified : List LawDiff := []
  for b in before do
    if let some a := after.find? (fun d => d.identifier == b.identifier) then
      let diff := computeLawDiff b a
      let bump := classifyVersionBump b a
      let hasProof := hasRefinementProof b.version a
      let withMeta : LawDiff := {
        diff with
          versionBump := bump,
          refinementProofPresent := hasProof
      }
      if !diff.isEmpty then
        modified := modified ++ [withMeta]
  pure { lawsAdded := added,
         lawsRemoved := removed,
         lawsModified := modified,
         authoritySlotsAdded := [],
         authoritySlotsRemoved := [],
         authoritySlotsModified := [],
         invariantClaimsAdded := [],
         invariantClaimsRemoved := [],
         invariantClaimsModified := [] }

/-- Backward-compat alias for the law-set-only diff (the
    pre-M3-completion API). -/
def computeDeploymentDiff := computeLawSetDiff

/-! ## Manifest-level diffing (LX.35)

`computeManifestDiff` takes two `Deployment` records and produces
a complete `DeploymentDiff` covering law-set / authority-set /
claim-set adds / removes / modifications.

Per §14.4: adding/removing laws or authority bindings is a major
manifest bump; per-binding edits are minor.  Combine with
`computeLawSetDiff` to get full per-law content diffs (which
require `LawDecl` JSON sidecars beyond what the `Deployment`
record carries).

The function does not require git or filesystem access — it
operates on `Deployment` Lean values directly.  Tooling that
needs to compare two manifests at git refs should:

  1. Elaborate / load the `Deployment` records at each ref.
  2. Optionally also load the `LawDecl` JSON sidecars at each
     ref via `loadCodegenDirFromGitRef`.
  3. Combine via `computeManifestDiff` (manifest-level) +
     `computeLawSetDiff` (per-law content). -/

/-- Render an `InvariantClaim` as a comma-joined "<kind>:<lawnames>"
    string for diff comparison.

    **Audit-3 fix**: the law-name list is sorted lexicographically
    before joining, so claims with the same set of laws but
    different declared order compare equal.  Per spec §10.2 ("the
    set of laws"), claim law lists are unordered — `[A, B]` and
    `[B, A]` are the same claim.  Without this normalisation,
    reordering would be triple-counted (added + removed +
    modified). -/
private def invariantClaimToString
    (c : LegalKernel.DSL.InvariantClaim) : String :=
  let kindStr : String := match c.kind with
    | .monotonicLawSet        => "monotonic_law_set"
    | .conservativeLawSet     => "conservative_law_set"
    | .freezePreservingLawSet => "freeze_preserving_law_set"
  -- Audit-5: use a Lean-identifier-illegal separator so distinct
  -- name lists can never produce the same rendered string.  The
  -- prior `,` separator collapsed `["foo,bar"]` and
  -- `["foo","bar"]` to identical render strings; under the
  -- French-quoted `«…»` Lean identifier syntax, names admitting
  -- commas are syntactically valid law identifiers.  The `\x1f`
  -- (US — unit separator) byte is illegal in any source-form
  -- Lean identifier and is a stable display-only delimiter
  -- (the rendered string is for diff display + comparison
  -- only, never written back to a manifest).
  let scopeStr : String := match c.scope with
    | .explicit names =>
      let sortedNames := names.toArray.qsort (· < ·) |>.toList
      "[" ++ String.intercalate "\x1f" sortedNames ++ "]"
    | .wildcard       => "[all_laws]"
  s!"{kindStr} {scopeStr}"

/-- Compute a manifest-level diff between two `Deployment`
    records.  Populates law / authority / invariant-claim
    add/remove/modify lists.

    The `lawsModified` field is left empty by this function —
    populating it requires `LawDecl` JSON sidecars (the
    `Deployment` record carries `LawBinding` summaries, not
    full law content).  Use `computeLawSetDiff` separately for
    per-law content diffs. -/
def computeManifestDiff
    (before after : LegalKernel.DSL.Deployment) :
    DeploymentDiff := Id.run do
  -- Law bindings (compared by localName).
  let beforeLawNames := before.laws.map (·.localName)
  let afterLawNames := after.laws.map (·.localName)
  let lawsAdded := afterLawNames.filter (fun n => !beforeLawNames.contains n)
  let lawsRemoved := beforeLawNames.filter (fun n => !afterLawNames.contains n)
  -- Authority slots.
  let beforeAuthSlots := before.authority.map (·.localName)
  let afterAuthSlots := after.authority.map (·.localName)
  let authAdded := afterAuthSlots.filter (fun s => !beforeAuthSlots.contains s)
  let authRemoved := beforeAuthSlots.filter (fun s => !afterAuthSlots.contains s)
  let mut authModified : List AuthorityBindingDiff := []
  for b in before.authority do
    if let some a := after.authority.find? (fun ab => ab.localName == b.localName) then
      if b.policyExpr != a.policyExpr then
        authModified := authModified ++ [{
          slotName := b.localName,
          diff := { before := b.policyExpr, after := a.policyExpr }
        }]
  -- Invariant claims (compared by their string-render).
  let beforeClaims := before.invariantClaims.map invariantClaimToString
  let afterClaims := after.invariantClaims.map invariantClaimToString
  let claimsAdded := afterClaims.filter (fun c => !beforeClaims.contains c)
  let claimsRemoved := beforeClaims.filter (fun c => !afterClaims.contains c)
  -- Modified claims: same kind with different scope.
  let mut claimsModified : List InvariantClaimDiff := []
  for b in before.invariantClaims do
    -- Find an `after` claim with the same kind.
    let kindMatches := after.invariantClaims.filter (fun a => a.kind == b.kind)
    let beforeMatchCount := (before.invariantClaims.filter
        (fun bb => bb.kind == b.kind)).length
    if kindMatches.length == 1 ∧ beforeMatchCount == 1 then
      let a := kindMatches.head!
      -- Audit-3: order-normalise scope before comparison so
      -- `[A, B]` and `[B, A]` aren't reported as modified.
      let renderScope (s : LegalKernel.DSL.InvariantClaimScope) : String :=
        match s with
        | .explicit names =>
          let sortedNames := names.toArray.qsort (· < ·) |>.toList
          -- Audit-5: use US byte delimiter (illegal in Lean
          -- identifiers) so distinct name lists never collide.
          String.intercalate "\x1f" sortedNames
        | .wildcard       => "<all_laws>"
      let bScope := renderScope b.scope
      let aScope := renderScope a.scope
      if bScope != aScope then
        let kindStr : String := match b.kind with
          | .monotonicLawSet        => "monotonic_law_set"
          | .conservativeLawSet     => "conservative_law_set"
          | .freezePreservingLawSet => "freeze_preserving_law_set"
        claimsModified := claimsModified ++ [{
          kindName := kindStr,
          diff := { before := bScope, after := aScope }
        }]
  pure {
    lawsAdded := lawsAdded,
    lawsRemoved := lawsRemoved,
    lawsModified := [],  -- requires LawDecl sidecars
    authoritySlotsAdded := authAdded,
    authoritySlotsRemoved := authRemoved,
    authoritySlotsModified := authModified,
    invariantClaimsAdded := claimsAdded,
    invariantClaimsRemoved := claimsRemoved,
    invariantClaimsModified := claimsModified
  }

/-- Combine a manifest-level diff with a per-law content diff.
    The `lawsModified` field is taken from the law-content diff
    (since manifest-level diffing can't see per-law content);
    other fields are taken from the manifest-level diff. -/
def combineManifestAndLawDiffs
    (manifestDiff : DeploymentDiff) (lawDiff : DeploymentDiff) :
    DeploymentDiff :=
  { manifestDiff with
      lawsModified := lawDiff.lawsModified }

/-! ## Output formatting (§14.1) -/

/-- Format an `Option Diff` for a per-clause diff line.  Returns
    an empty string if `none` (clause unchanged). -/
def formatOptionDiff (field : String) : Option Diff → String
  | none => ""
  | some d => s!"  {field}: {d.before} → {d.after}\n"

/-- Format a `LawDiff` per §14.1.  Result ends with a newline. -/
def formatLawDiff (diff : LawDiff) : String :=
  let header := s!"{diff.identifier}:\n"
  let versionLine :=
    s!"  version: {diff.versionBefore} → {diff.versionAfter}   ({diff.versionBump.toDisplay})\n"
  let clauseLines :=
    formatOptionDiff "pre" diff.preDiff ++
    formatOptionDiff "impl" diff.implDiff ++
    formatOptionDiff "satisfies" diff.satisfiesDiff ++
    formatOptionDiff "events" diff.eventsDiff ++
    formatOptionDiff "intent" diff.intentDiff ++
    formatOptionDiff "signed_by" diff.signedByDiff ++
    formatOptionDiff "authorized_by" diff.authDiff ++
    formatOptionDiff "action_index" diff.actionIndexDiff ++
    formatOptionDiff "params" diff.paramsDiff ++
    formatOptionDiff "proof_overrides" diff.proofOverridesDiff ++
    formatOptionDiff "registry_effect" diff.registryEffectDiff
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
  let authAdded := String.join
    (diff.authoritySlotsAdded.map (fun s => s!"  + {s}\n"))
  let authRemoved := String.join
    (diff.authoritySlotsRemoved.map (fun s => s!"  - {s}\n"))
  let authModified := String.join (diff.authoritySlotsModified.map
    (fun b => s!"  ~ {b.slotName}: {b.diff.before} → {b.diff.after}\n"))
  let claimsAdded := String.join
    (diff.invariantClaimsAdded.map (fun s => s!"  + {s}\n"))
  let claimsRemoved := String.join
    (diff.invariantClaimsRemoved.map (fun s => s!"  - {s}\n"))
  let claimsModified := String.join (diff.invariantClaimsModified.map
    (fun b => s!"  ~ {b.kindName}: {b.diff.before} → {b.diff.after}\n"))
  let bumpInfo : String :=
    match diff.classifyManifestBump with
    | some b => s!"manifest version-bump: {b.toDisplay}\n"
    | none   => ""
  s!"== Deployment Diff ==\n" ++ bumpInfo ++
  (if !added.isEmpty then s!"Laws added:\n{added}" else "") ++
  (if !removed.isEmpty then s!"Laws removed:\n{removed}" else "") ++
  (if !modified.isEmpty then s!"Laws modified:\n{modified}" else "") ++
  (if !authAdded.isEmpty then s!"Authority slots added:\n{authAdded}" else "") ++
  (if !authRemoved.isEmpty then s!"Authority slots removed:\n{authRemoved}" else "") ++
  (if !authModified.isEmpty then s!"Authority slots modified:\n{authModified}" else "") ++
  (if !claimsAdded.isEmpty then s!"Invariant claims added:\n{claimsAdded}" else "") ++
  (if !claimsRemoved.isEmpty then s!"Invariant claims removed:\n{claimsRemoved}" else "") ++
  (if !claimsModified.isEmpty then s!"Invariant claims modified:\n{claimsModified}" else "") ++
  (if added.isEmpty && removed.isEmpty && modified.isEmpty &&
      authAdded.isEmpty && authRemoved.isEmpty && authModified.isEmpty &&
      claimsAdded.isEmpty && claimsRemoved.isEmpty && claimsModified.isEmpty then
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
  IO.println "       lake exe lex_diff --git <ref-a> <ref-b>"
  IO.println "       lake exe lex_diff --help"
  IO.println ""
  IO.println "Compares two trees of Lex/Inputs/*.json files"
  IO.println "and emits a per-law / per-deployment semantic diff."
  IO.println ""
  IO.println "  Two input modes (LX.34):"
  IO.println "    Directory mode:  takes two directory paths."
  IO.println "    Git mode:        takes two git refs (--git <ref-a> <ref-b>)."
  IO.println "                     Runs `git show <ref>:Lex/Inputs/*.json`"
  IO.println "                     to fetch sidecars at the named revision."
  IO.println ""
  IO.println "Exit codes:"
  IO.println "  0  diff produced (zero or more changes)."
  IO.println "  1  L007 (declared-vs-computed bump mismatch) or"
  IO.println "     L016 (missing refinement proof)."
  IO.println "  2  internal failure (malformed JSON, missing dir, git failure)."
  return 0

/-- Validate a deployment diff: surface L007 (mismatch) and L016
    (missing proof) violations as diagnostics. -/
def validateDeploymentDiff (diff : DeploymentDiff)
    (afterDir : FilePath) : List Diagnostic := Id.run do
  let mut diags : List Diagnostic := []
  for ld in diff.lawsModified do
    -- L016: minor bump without refinement proof.
    if ld.versionBump == .minor && !ld.refinementProofPresent then
      diags := diags ++ [L016Diagnostic afterDir.toString
        ld.identifier ld.versionBefore]
    -- L007: declared version-bump doesn't match computed.
    let oldP := ld.versionBefore.splitOn "."
    let newP := ld.versionAfter.splitOn "."
    if oldP.length == 3 && newP.length == 3 then
      let declaredBump : VersionBump :=
        if oldP.head! != newP.head! then .major
        else if oldP[1]! != newP[1]! then .minor
        else if oldP[2]! != newP[2]! then .patch
        else .none_
      if declaredBump != ld.versionBump then
        diags := diags ++ [L007Diagnostic afterDir.toString
          ld.identifier declaredBump ld.versionBump]
  pure diags

/-- Main entry.  Compares two directories OR two git refs.

    Exit codes:

      0 — diff produced successfully.
      1 — L007 / L016 violations detected.
      2 — internal failure.
    -/
def main (args : List String) : IO UInt32 := do
  if args.contains "--help" || args.contains "-h" then
    return (← printHelp)
  -- Check for --git mode.
  if args.length ≥ 1 && args.head! == "--git" then
    match args.tail with
    | [refA, refB] =>
      let beforeR ← loadCodegenDirFromGitRef refA
      match beforeR with
      | .error msg =>
        IO.eprintln s!"lex_diff --git: failed to load `{refA}`: {msg}"
        return 2
      | .ok beforeDecls =>
        let afterR ← loadCodegenDirFromGitRef refB
        match afterR with
        | .error msg =>
          IO.eprintln s!"lex_diff --git: failed to load `{refB}`: {msg}"
          return 2
        | .ok afterDecls =>
          let diff := computeDeploymentDiff beforeDecls afterDecls
          IO.print (formatDeploymentDiff diff)
          let diags := validateDeploymentDiff diff
            (FilePath.mk s!"<git ref {refB}>")
          for d in diags do
            IO.print d.format
          if diags.any (fun d => d.severity == .error) then
            return 1
          return 0
    | _ =>
      IO.eprintln "Usage: lake exe lex_diff --git <ref-a> <ref-b>"
      return 2
  -- Directory mode.
  match args with
  | [beforeDir, afterDir] =>
    let beforeFP : FilePath := beforeDir
    let afterFP : FilePath := afterDir
    let beforeR ← loadCodegenDir beforeFP
    match beforeR with
    | .error msg =>
      IO.eprintln s!"lex_diff: failed to load `{beforeDir}`: {msg}"
      return 2
    | .ok beforeDecls =>
      let afterR ← loadCodegenDir afterFP
      match afterR with
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
    IO.eprintln "       lake exe lex_diff --git <ref-a> <ref-b>"
    IO.eprintln "       lake exe lex_diff --help"
    return 2

end LegalKernel.Tools.Lex.Diff

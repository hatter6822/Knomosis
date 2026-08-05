-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import Tools.Common

/-!
Tools.ApiStabilityAudit — the term-level API-stability discipline.

CLAUDE.md's "Test patterns" section promises that every post-Phase-0
theorem carries a term-level API-stability test "whose elaboration
fails if the theorem signature changes":

    2. **Term-level API stability**: ascribe a `let _proof : T :=
       theorem ...` binding (catches signature changes at elaboration
       time).

The **type ascription is the whole mechanism.**  Written without one:

    let _ := @some_theorem          -- pins ONLY that the name exists

the binding elaborates against whatever type the theorem happens to
have, so reordering its hypotheses, weakening a conclusion, or adding
a parameter all still elaborate.  The test reports PASS and the
guarantee CLAUDE.md describes does not hold.  Written with one:

    let _proof : ∀ (s : State), P s → Q s := some_theorem

any signature change fails elaboration, which is the point.

This gate flags the unascribed form.  The existing occurrences are
frozen in `tools/api_stability_allowlist.txt` so the debt is bounded
and burns down; anything NEW fails the build.

Exit semantics:

  * 0 — every unascribed binding is on the allowlist.
  * 1 — at least one unallowlisted unascribed binding.

This module is **not** part of the trusted computing base.
-/

namespace LegalKernel.Tools.ApiStabilityAudit

open LegalKernel.Tools (readFileSafe)

/-- Roots scanned for the discipline.  Test modules only: the
    ascription rule is about *test* bindings, and a `let _ := @f` in
    production code is ordinary term-level code, not a broken pin. -/
def searchRoots : List String :=
  ["LegalKernel/Test", "Lex/Test"]

/-- Path to the frozen-debt allowlist. -/
def allowlistPath : String := "tools/api_stability_allowlist.txt"

/-- Drop leading and trailing ASCII whitespace. -/
def strip (s : String) : String := s.trimAscii.toString

/-- Does `haystack` contain `needle` as a substring? -/
def containsSub (haystack needle : String) : Bool :=
  decide ((haystack.splitOn needle).length > 1)

/-- Is this line an UNASCRIBED term-level API-stability binding?

    Matches `let <binder> := @<name>` — a `let` whose right-hand side
    is an `@`-prefixed identifier and which carries no `:` type
    ascription between the binder and the `:=`.

    The `@` is what identifies the shape as an API pin rather than an
    ordinary local binding: `@f` suppresses implicit-argument
    insertion, which is only ever wanted when naming a declaration for
    its own sake.  Requiring the absence of `:` before `:=` is what
    distinguishes the broken form from the correct
    `let _proof : T := @f`. -/
def isUnascribedPin (line : String) : Bool :=
  let t := strip line
  if !t.startsWith "let " then false
  else
    let afterLet := (t.drop 4).toString
    match (afterLet.splitOn ":=").head? with
    | none => false
    | some binderPart =>
      -- An ascribed binding has a `:` in the binder part.  (`:=` was
      -- already split off, so a lone `:` here is the ascription.)
      if containsSub binderPart ":" then false
      else
        -- The right-hand side must begin with `@`.
        let rhs := strip (String.intercalate ":=" ((afterLet.splitOn ":=").drop 1))
        rhs.startsWith "@"

/-- One flagged binding: path, 1-based line number, and the line. -/
structure Violation where
  /-- File path (relative to the repository root). -/
  path    : String
  /-- 1-based line number. -/
  lineNo  : Nat
  /-- The offending line, whitespace-stripped. -/
  rawLine : String
  deriving Inhabited

/-- Canonical allowlist key: `path:line`.  Deliberately does NOT
    include the line text — an allowlisted binding that gets its
    ascription added simply stops matching, and one that moves is
    re-reported, which is the correct direction for a burn-down list. -/
def Violation.key (v : Violation) : String := s!"{v.path}:{v.lineNo}"

/-- Format a violation for the operator. -/
def Violation.format (v : Violation) : String :=
  s!"  {v.path}:{v.lineNo}: unascribed API pin: {v.rawLine}"

/-- Recursively list `.lean` files under `root`. -/
partial def listLeanFiles (root : String) : IO (List String) := do
  let path : System.FilePath := root
  match (← path.metadata.toBaseIO) with
  | .error _ => pure []
  | .ok fileMeta =>
    if fileMeta.type == IO.FS.FileType.dir then
      let entries ← path.readDir
      let mut acc : List String := []
      for e in entries do
        let sub ← listLeanFiles e.path.toString
        acc := sub.foldl (fun a f => f :: a) acc
      pure acc.reverse
    else if root.endsWith ".lean" then
      pure [root]
    else
      pure []

/-- Scan one file. -/
def scanFile (path : String) : IO (List Violation) := do
  match (← readFileSafe path) with
  | none      => pure []
  | some text =>
    let mut acc : List Violation := []
    let mut i := 0
    for line in text.splitOn "\n" do
      i := i + 1
      if isUnascribedPin line then
        acc := { path := path, lineNo := i, rawLine := strip line } :: acc
    pure acc.reverse

/-- Read the allowlist; a missing file means an empty allowlist. -/
def readAllowlist : IO (List String) := do
  match (← readFileSafe allowlistPath) with
  | none      => pure []
  | some text =>
    pure (text.splitOn "\n"
      |>.map strip
      |>.filter (fun s => !s.isEmpty && !s.startsWith "#"))

/-- Every unallowlisted unascribed binding under the search roots. -/
def aggregate : IO (List Violation × Nat) := do
  let allowlist ← readAllowlist
  let mut all : List String := []
  for r in searchRoots do
    let xs ← listLeanFiles r
    all := xs.foldl (fun a f => f :: a) all
  let mut result : List Violation := []
  let mut total := 0
  for f in all.reverse do
    for v in (← scanFile f) do
      total := total + 1
      if v.key ∉ allowlist then
        result := v :: result
  pure (result.reverse, total)

end LegalKernel.Tools.ApiStabilityAudit

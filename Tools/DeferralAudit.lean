/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.DeferralAudit — no-deferrals policy enforcement.

Per `CLAUDE.md`'s no-deferrals policy: a workstream / commit
is **not complete** while any of its theorems, modules, or
docstrings document a deferral.

This tool walks every `.lean` file under `LegalKernel/` and
`Tools/` and rejects:

  1. **Deferral markers in docstrings** — phrases like
     `DEFERRED`, `deferred to follow-up`, `multi-day work`,
     `not yet provable`, `until X ships`, `round-trip-conditional`
     anywhere in `/-- ... -/` or `/-! ... -/` blocks.
  2. **PARTIAL status claims** in code-block status tables
     (`| PARTIAL  |` rows in markdown tables embedded in
     module docstrings).

The premise: deferrals weaken the project's "no shortcuts"
discipline by creating long-lived TODOs that accumulate.
Either the work is done (proof shipped) or the theorem doesn't
exist.

**No exceptions.**  There is no allowlist.  If a phrase
documenting a deferral exists in a `.lean` file, the audit
fails.  The fix is to ship the proof / implementation OR
remove the comment entirely (perhaps inlining the missing
content's substantive description without deferral language).

Exit semantics:
  * Exit 0 if no deferral markers found.
  * Exit 1 if any deferral marker is found.

This module is **not** part of the trusted computing base.
-/

import Tools.Common

open LegalKernel.Tools (readFileSafe)

namespace LegalKernel.Tools.DeferralAudit

/-- Search roots. -/
def searchRoots : List String := ["LegalKernel", "Lex", "Tools"]

/-- Lowercase a single character. -/
private def toLowerChar (c : Char) : Char :=
  if 'A' ≤ c ∧ c ≤ 'Z' then
    Char.ofNat (c.toNat + 32)
  else
    c

/-- Lowercase a String. -/
private def toLower (s : String) : String :=
  s.map toLowerChar

/-- Forbidden deferral phrases (lowercase).  Matched as
    case-insensitive substrings against each file's content. -/
def forbiddenPhrases : List String :=
  [ -- Explicit deferral markers.
    "deferred to follow-up"
  , "deferred to a follow-up"
  , "deferred to future"
  , "deferred future"
  , "multi-day deferred"
  , "multi-day work"
  , "not yet discharged"
  , "not yet provable"
  , "yet-unproved"
  , "until ... ships"
  , "round-trip-conditional"
  , "round-trip conditional"
  , "honest deferral"
  , "honestly deferred"
  -- Status-table PARTIAL claims.
  , "| partial  |"
  , "| partial |"
  , "status: partial"
  , "marked partial"
  -- Status-table DEFERRED claims.
  , "| deferred |"
  , "| deferred  |"
  , "status: deferred"
  , "marked deferred"
  -- TODO/FIXME/XXX in docstrings or comments.
  , "TODO:"
  , "FIXME:"
  , "XXX:"
  ]

/-- A violation produced when a forbidden phrase is found. -/
structure Violation where
  /-- File where the phrase was found. -/
  path           : String
  /-- 1-indexed line number. -/
  lineNumber     : Nat
  /-- Lowercased forbidden phrase that matched. -/
  matchedPhrase  : String
  /-- The full line where the phrase appears (truncated to
      120 chars for readability). -/
  lineContent    : String
  deriving Repr

/-- Format a violation as a single audit-line. -/
def Violation.format (v : Violation) : String :=
  let truncated :=
    if v.lineContent.length > 120 then
      (v.lineContent.toRawSubstring.take 117).toString ++ "..."
    else v.lineContent
  s!"  {v.path}:{v.lineNumber}: forbidden phrase `{v.matchedPhrase}` in:\n    {truncated}"

/-- Check whether `haystack` contains `needle` as a substring
    (both lowercased). -/
private def containsLower (haystack needle : String) : Bool :=
  decide (((toLower haystack).splitOn needle).length > 1)

/-- Audit all lines in a file for forbidden phrases. -/
def auditFile (path : String) (content : String) : List Violation :=
  Id.run do
    let mut violations : List Violation := []
    let lines := content.splitOn "\n"
    let mut lineNumber : Nat := 0
    for line in lines do
      lineNumber := lineNumber + 1
      for phrase in forbiddenPhrases do
        if containsLower line phrase then
          violations := violations ++
            [{ path := path
             , lineNumber := lineNumber
             , matchedPhrase := phrase
             , lineContent := line }]
    return violations

/-- List all `.lean` files under `root` recursively. -/
partial def listLeanFiles (root : String) : IO (List String) := do
  if !(← System.FilePath.pathExists root) then return []
  let entries ← System.FilePath.readDir root
  let mut result : List String := []
  for entry in entries do
    let path := root ++ "/" ++ entry.fileName
    if (← System.FilePath.isDir path) then
      result := result ++ (← listLeanFiles path)
    else if path.endsWith ".lean" then
      result := result ++ [path]
  return result

/-- Paths to exclude from the scan.  These files mention the
    forbidden phrases as DATA (the forbidden-token list, the
    documentation of what's banned) rather than as live
    deferrals; scanning them would be a self-reference. -/
def excludedPaths : List String :=
  [ "Tools/DeferralAudit.lean"
  , "DeferralAudit.lean"
  , "Tools/NamingAudit.lean"
  ]

/-- Check whether a path should be excluded from the scan. -/
def isExcluded (path : String) : Bool :=
  excludedPaths.any (fun p => path == p)

/-- Run the deferral audit.  **No allowlist.**  Every deferral
    phrase, anywhere in the scanned files, fails the audit. -/
def runAudit : IO (List Violation) := do
  let mut violations : List Violation := []
  for root in searchRoots do
    let files ← listLeanFiles root
    for path in files do
      if isExcluded path then continue
      match (← readFileSafe path) with
      | none         => pure ()
      | some content =>
        violations := violations ++ auditFile path content
  return violations

end LegalKernel.Tools.DeferralAudit

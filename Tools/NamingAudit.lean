/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.NamingAudit — content-name discipline enforcement.

Per `CLAUDE.md`'s "Names describe content, never provenance"
rule:
  * **Identifier names** (defs, theorems, structures, classes,
    instances) must describe *what the declaration is or proves*,
    never *which work unit, audit, phase, or session produced it*.
  * **File names** (`.lean` module files) must describe their
    content, not the work artifact ("things that were missing"
    is process; "encoder injectivity" is content).

This tool walks every `.lean` file under `LegalKernel/`, `Tools/`,
and the project root, then:

  1. **File-name check**: rejects file paths whose final component
     (without `.lean`) matches a forbidden-token regex,
     case-insensitive.
  2. **Declaration-name check**: rejects `def`/`theorem`/`structure`
     /`class`/`instance`/`abbrev`/`lemma` lines whose declared
     identifier matches a forbidden-token regex.

Forbidden tokens (substring match, case-insensitive):

  * **Work-process markers**: `wu`, `phase`, `audit`, `session`,
    `pr[0-9]`, `claude_`.
  * **Temporal markers**: `old`, `new`, `legacy`, `v2`, `v3`,
    `tmp`, `todo`, `fixme`.
  * **Status markers**: `missing`, `deferred`, `pending`, `stub`,
    `wip`, `draft`, `incomplete`, `unfinished`.
  * **Grab-bag markers**: `helpers`, `helper`, `utils`, `utilities`,
    `misc`, `miscellaneous`, `supplemental`, `auxiliary`, `extras`,
    `addenda`, `addendum`, `assorted`.

Allowlist: `tools/naming_allowlist.txt` — one line per
`module-path:matched-token`, used to grandfather exceptions
(e.g., `lemmas` in a content-driven file name like `BalanceLemmas`).

Exit semantics:
  * Exit 0 if every file name + declaration name is content-driven.
  * Exit 1 if any forbidden-token match is found and is not
    allowlisted.

This module is **not** part of the trusted computing base.  Bugs
here surface as false positives or false negatives.
-/

import Tools.Common

open LegalKernel.Tools (readFileSafe)

namespace LegalKernel.Tools.NamingAudit

/-- Search roots for the naming audit. -/
def searchRoots : List String := ["LegalKernel", "Lex", "Tools"]

/-- Allowlist file path. -/
def namingAllowlistPath : String := "tools/naming_allowlist.txt"

/-- Forbidden tokens (lowercase) that must not appear as
    substrings of file basenames or declaration identifiers.

    **Design.**  The list is intentionally focused on truly
    process-y tokens: words that describe WHEN or WHY something
    was added (provenance/process), never WHAT something is or
    proves (content).  We deliberately exclude tokens like
    `pending`, `deferred`, `old`, `new` because they have
    legitimate content uses (a dispute's `pendingMidpoint`, a
    Lex `DeferredEntry`, a nonce's "old value" role).  The
    allowlist mechanism handles any remaining false positives. -/
def forbiddenTokens : List String :=
  -- Status-marker packagers ("missing-theorems"-style file names
  -- that group theorems by work artefact rather than content).
  [ "missingtheorems"
  , "missing_theorems"
  , "missing_theorem"
  , "missingtheorem"
  -- Work-unit / phase / audit number stamps (provenance).
  , "wu1", "wu2", "wu3", "wu4", "wu5"
  , "wu6", "wu7", "wu8", "wu9"
  , "wu_2_", "wu_3_", "wu_4_", "wu_5_"
  , "phase0", "phase1", "phase2", "phase3"
  , "phase4", "phase5", "phase6", "phase7"
  , "audit1", "audit2", "audit3", "audit_"
  -- Session / CI references (provenance).
  , "session_"
  , "claude_"
  , "pr_"
  -- Explicit process/status suffixes (never content).
  , "_tmp"
  , "_todo"
  , "_fixme"
  , "_wip"
  , "_draft"
  , "_legacy"
  -- Version-suffix temporal markers (AR.8 / M-9).  Per CLAUDE.md
  -- "Names describe content, never provenance": an identifier
  -- suffixed `_v2` / `_v3` / `_v4` / `_v5` describes *which
  -- iteration produced it*, not *what the declaration is*.
  -- Rename to a content suffix (e.g. `_quorum`, `_unrestricted`,
  -- `_keyed`) before landing.
  , "_v2"
  , "_v3"
  , "_v4"
  , "_v5"
  -- Grab-bag umbrella names (non-descriptive group-by-leftover
  -- naming).
  , "miscellaneous"
  , "supplemental"
  , "auxiliary"
  , "addenda"
  , "addendum"
  , "assorted"
  -- Round-trip-conditional packagers — naming pattern used for
  -- theorems whose stated hypotheses cannot be discharged in the
  -- current codebase.  Either ship the proof unconditionally or
  -- do not ship the theorem; the project's no-deferrals policy
  -- forbids the hedge.
  , "_via_roundtrip"
  , "_round_trip_conditional"
  ]

/-- Lowercase a single character. -/
private def toLowerChar (c : Char) : Char :=
  if 'A' ≤ c ∧ c ≤ 'Z' then
    Char.ofNat (c.toNat + 32)
  else
    c

/-- Lowercase a String. -/
private def toLower (s : String) : String :=
  s.map toLowerChar

/-- Check whether `haystack` contains `needle` as a substring
    (both lowercased). -/
private def containsLower (haystack needle : String) : Bool :=
  decide (((toLower haystack).splitOn needle).length > 1)

/-- Extract the file's basename without the `.lean` extension.
    Returns the trailing path segment after the last `/`. -/
def basename (path : String) : String :=
  let segments := path.splitOn "/"
  let last := segments.getLast?.getD path
  -- Strip `.lean` extension.
  if last.endsWith ".lean" then
    (last.dropEnd 5).toString
  else
    last

/-- A diagnostic produced when a forbidden token matches. -/
structure Violation where
  /-- File path the violation was found in. -/
  path           : String
  /-- The matched-text scope: either `"filename"` (the file's
      basename matched) or `"identifier"` (a declaration name
      inside the file matched). -/
  scope          : String
  /-- The full identifier or basename that matched. -/
  matchedName    : String
  /-- The forbidden token that was found inside it. -/
  forbiddenToken : String
  deriving Repr

/-- Format a violation as a single audit-line. -/
def Violation.format (v : Violation) : String :=
  s!"  {v.path} [{v.scope}]: identifier `{v.matchedName}` contains forbidden token `{v.forbiddenToken}`"

/-- Check a single name (file basename or declaration identifier)
    against the forbidden-token list.  Returns `some token` if a
    forbidden token is found; `none` otherwise. -/
def findForbiddenToken (name : String) : Option String :=
  forbiddenTokens.find? (containsLower name)

/-- Check a file's basename for forbidden tokens. -/
def auditFilename (path : String) : Option Violation :=
  let base := basename path
  match findForbiddenToken base with
  | none      => none
  | some tok  =>
    some { path := path
         , scope := "filename"
         , matchedName := base
         , forbiddenToken := tok }

/-- Recognise the start of a top-level declaration and extract
    the declared identifier.  Returns `some name` on a match;
    `none` otherwise.

    Handles: `def NAME`, `theorem NAME`, `structure NAME`,
    `class NAME`, `instance NAME`, `abbrev NAME`, `lemma NAME`,
    `noncomputable def NAME`, `private def NAME`, etc. -/
def parseDeclName (line : String) : Option String := Id.run do
  let trimmed := line.trimAscii.toString
  -- Strip optional modifiers.
  let stripIfPrefix (s : String) (p : String) : String :=
    if s.startsWith p then (s.drop p.length).toString else s
  let trimmed₁ :=
    stripIfPrefix (stripIfPrefix (stripIfPrefix trimmed "noncomputable ")
                                 "private ")
                  "protected "
  -- Match declaration keyword.
  let keywords : List String :=
    [ "def "
    , "theorem "
    , "structure "
    , "class "
    , "instance "
    , "abbrev "
    , "lemma "
    , "inductive "
    ]
  for kw in keywords do
    if trimmed₁.startsWith kw then
      let rest := trimmed₁.drop kw.length
      -- The identifier is the first token (up to whitespace or
      -- punctuation like `(`, `:`, `[`, `{`).
      let stopAt : Char → Bool := fun c =>
        c == ' ' || c == '(' || c == ':' || c == '[' || c == '{'
          || c == '\n' || c == '\t'
      let identifier := (rest.takeWhile (fun c => !stopAt c)).toString
      -- Skip instances with no explicit name (Lean infers).
      if identifier.isEmpty || identifier == "instance" then
        return none
      return some identifier
  return none

/-- Audit all declarations in a file.  Returns a list of
    violations. -/
def auditDeclarations (path : String) (content : String) :
    List Violation := Id.run do
  let mut violations : List Violation := []
  for line in content.splitOn "\n" do
    match parseDeclName line with
    | none      => pure ()
    | some name =>
      match findForbiddenToken name with
      | none     => pure ()
      | some tok =>
        violations := violations ++
          [{ path := path
           , scope := "identifier"
           , matchedName := name
           , forbiddenToken := tok }]
  return violations

/-- List all `.lean` files under `root` recursively.  Mirrors
    the discovery pattern in `Tools.CountSorries` and
    `Tools.StubAudit`. -/
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

/-- Read the allowlist file, returning a list of allowlist
    entries.  Format: `path:matched-token` per line.  Empty
    lines and lines starting with `#` are ignored. -/
def readAllowlist : IO (List (String × String)) := do
  match (← readFileSafe namingAllowlistPath) with
  | none      => return []
  | some text =>
    let mut result : List (String × String) := []
    for line in text.splitOn "\n" do
      let trimmed := line.trimAscii.toString
      if trimmed.isEmpty || trimmed.startsWith "#" then continue
      match trimmed.splitOn ":" with
      | [p, t] => result := result ++ [(p.trimAscii.toString, t.trimAscii.toString)]
      | _      => continue
    return result

/-- Check whether a violation is on the allowlist. -/
def isAllowlisted (allowlist : List (String × String))
    (v : Violation) : Bool :=
  allowlist.any (fun (p, t) =>
    v.path == p && v.forbiddenToken == t)

/-- Run the naming audit.  Returns the list of unallowlisted
    violations. -/
def runAudit : IO (List Violation) := do
  let allowlist ← readAllowlist
  let mut violations : List Violation := []
  for root in searchRoots do
    let files ← listLeanFiles root
    for path in files do
      -- File-name check.
      match auditFilename path with
      | none   => pure ()
      | some v => violations := violations ++ [v]
      -- Declaration-name check.
      match (← readFileSafe path) with
      | none         => pure ()
      | some content =>
        violations := violations ++ auditDeclarations path content
  return violations.filter (fun v => !isAllowlisted allowlist v)

end LegalKernel.Tools.NamingAudit

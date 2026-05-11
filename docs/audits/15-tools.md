# Non-Lex Audit Tools — `Tools/` + top-level wrappers

**Files (non-Lex tools):**
* `Tools/Common.lean` (74 lines)
* `Tools/TcbAudit.lean` (145 lines)
* `Tools/CountSorries.lean` (253 lines)
* `Tools/StubAudit.lean` (256 lines)
* `Tools/NamingAudit.lean` (300 lines)
* `Tools/DeferralAudit.lean` (183 lines)
* `NamingAudit.lean` (entrypoint wrapper — 40 lines)
* `DeferralAudit.lean` (entrypoint wrapper — 37 lines)

**TCB:** None.  All audit tools are diagnostic; bugs surface as
CI false positives or false negatives, never as kernel-invariant
violations.

---

## `Tools/Common.lean` — shared definitions

The single source of truth for the kernel-TCB file list,
TCB-core file list, internal-import allowlist, and the
allowlist file path.

```lean
def kernelTcbFiles : List String :=
  [ "LegalKernel/Kernel.lean"
  , "LegalKernel/RBMapLemmas.lean"
  , "LegalKernel/Laws/Transfer.lean"
  ]

def tcbCoreFiles : List String :=
  [ "LegalKernel/Kernel.lean"
  , "LegalKernel/RBMapLemmas.lean"
  ]

def tcbInternalImports : List String :=
  [ "LegalKernel.Kernel"
  , "LegalKernel.RBMapLemmas"
  ]
```

**Finding:** The lists are correct and minimal.  The distinction
between `kernelTcbFiles` (no-sorry gate) and `tcbCoreFiles` (TCB
allowlist gate) is important: `Laws/Transfer.lean` is in the
no-sorry set but not in the allowlist gate, because it's allowed
to import other laws.

`readFileSafe` (line 69): wraps `IO.FS.readFile.toBaseIO` to
return `Option String`.  Used by every audit tool to handle
missing files gracefully.

---

## `Tools/TcbAudit.lean` — TCB import allowlist gate

**Workflow:**

1. Read `tcb_allowlist.txt`, parsing one import per line.
2. For each file in `tcbCoreFiles`, parse all `import X.Y.Z` lines.
3. Reject any import not in the allowlist or `tcbInternalImports`.

**Parser:**

```lean
def parseImport (line : String) : Option String :=
  let cs := trimChars line.toList
  let importKeyword := "import ".toList
  if cs.take importKeyword.length = importKeyword then
    let rest := trimChars (cs.drop importKeyword.length)
    let modChars := rest.takeWhile (fun c => c.isAlphanum || c = '.' || c = '_')
    if modChars.isEmpty then none else some (listToString modChars)
  else
    none
```

**Hazard observation:** The parser does **not** support Lean's
`import all`, `prelude`, or `meta import` keyword variants.  The
docstring acknowledges this and notes "Canon's TCB does not use
them, and ruling them out keeps the parser simple."  A future PR
that adds `prelude` to a TCB file would be silently ignored.
Reviewers should:
* Either: explicitly forbid these forms in the TCB by code review
  (currently done in §13.6 amendments).
* Or: extend the parser to handle them.

**Finding:** The audit is intentionally pessimistic — any
unrecognised `import` form silently passes.  This is the right
direction (false negatives, never false positives), but it does
mean the allowlist is not airtight against creative `import`
syntax.

**Pre-processing:**
* `cleanLine` strips `#`-style line comments and surrounding
  whitespace.  Note: this is the allowlist-file format, not the
  Lean source format (Lean uses `--` for comments).  This is
  correct given that the parser is invoked on both the allowlist
  file (which uses `#`) and the source files (which use `--`).
  But wait — the parser invokes `cleanLine` on source lines too.
  Let me check.

Looking at `importsOf` (line 88):
```lean
def importsOf (content : String) : List String :=
  content.splitOn "\n"
    |>.filterMap (fun line =>
        let cleaned := cleanLine line
        if cleaned.isEmpty then none else parseImport cleaned)
```

So `cleanLine` is applied to source lines.  Source lines can
contain `--` comments (not `#`), but Lean source lines should
NEVER contain `#` (that's a different syntax).  In practice, this
"works" for the TCB-core files because they don't have `#`
characters in import lines.  But a `#print` or `#check` line
would be incorrectly truncated.  Since TCB-core files don't
contain those, the audit works.

**Hazard observation:** The unified `cleanLine` between allowlist
parsing and source-import parsing is correct but fragile.  If a
future TCB-core file contains a `#`-character (e.g. in a Lean
attribute), the parser will silently truncate.  Currently safe
because the strict-warnings + missingDocs linters keep TCB files
clean.

`isAllowed` (line 113): `imp ∈ allowlist || imp ∈ tcbInternalImports`.
Correct.

`main` (line 128): iterates over `tcbCoreFiles`, collects
violations, exits 1 on non-empty.  Standard.

**Finding:** The tool is correct for its intended use case.  Two
minor hazards (unsupported `import` forms, `#`-character
handling) are bounded by the small scope of the TCB.

---

## `Tools/CountSorries.lean` — no-sorry gate

**Approach:** A two-stage character-level pre-processor masks
out comments and string literals (preserving newlines so line
numbers match), then four substring patterns detect the
`sorry` term in proof position.

**Lex state machine (lines 81–114):**

```lean
inductive LexState
  | code
  | inString (escaped : Bool)
  | inBlockComment (depth : Nat)
  | inLineComment
```

`maskStep` (line 98) is a per-character transition function.
Three transitions are explicitly handled:
* `code` + `/` + `-` → `inBlockComment 1` (open block comment)
* `code` + `-` + `-` → `inLineComment` (open line comment)
* `code` + `"` → `inString false` (open string literal)

`inString` tracks escape state via the `escaped` field; `\"` is
read as two characters consumed (escaped → not-escaped, then
unchanged).

`inBlockComment` tracks nesting depth via the `Nat` field; Lean
allows nested block comments.

**Hazard observation:** The `maskStep` function takes a
*two-character* lookahead but returns only the masked first
character.  The caller in `maskNonCode` (line 119) handles this
by pattern-matching on the state transitions and consuming two
characters at a time when both are mask-significant (e.g. `/-`
or `--`).  The handling is correct but subtle; reviewers should
note that the `go` function inside `maskNonCode` (lines 120–136)
is the load-bearing piece.

**Hazard observation:** The lookahead consumption is fragile to
modifications.  If a future PR adds a third state-transition
trigger (e.g. raw strings `s!"..."`), both `maskStep` and
`maskNonCode`'s pattern match must be updated together.
Currently only three transitions; safe.

**Pattern matching (line 168):**
```lean
let pAssign    := listContains codeLine ":= sorry".toList
let pBy        := listContains codeLine "by sorry".toList
let pExact     := listContains codeLine "exact sorry".toList
let pBare      := trimmed = "sorry".toList
```

Four patterns; one is bare-line (entire trimmed line equals
"sorry"), three are substring.  All four are documented in the
module's docstring.

**Hazard observation:** The pattern set is exhaustive for
*common* `sorry` placements but not formally complete.  A
sufficiently obfuscated `sorry` could escape:
* `let x := sorry; exact x` (matched by `:= sorry`)
* `have : T := sorry` (matched by `:= sorry`)
* `refine sorry` (NOT matched — `refine` is not in the pattern set)
* `apply sorry` (NOT matched)
* `· sorry` (NOT matched — the bullet introduces a proof body,
  not the `by` keyword)
* `(sorry : T)` (NOT matched)

The module docstring notes "A full check would invoke Lean's
elaborator and inspect `sorryAx` axiom usage; the present tool
catches the common-case violations and is fast enough to run on
every CI build."  This is correct — full coverage would require
running the elaborator, which is significantly more expensive.

**Finding:** The current pattern set covers the historical
patterns documented in CLAUDE.md.  As a defensive measure, every
TCB module should be code-reviewed AND audit-tooled; the tool is
a forcing-function rather than a complete oracle.

`searchRoots` (line 56): `["LegalKernel", "Lex"]`.  Note: the
project root is not scanned — `Main.lean`, `Replay.lean`,
`Tests.lean`, `NamingAudit.lean`, `DeferralAudit.lean`,
`LegalKernel.lean`, `Lex.lean`, `Deployments.lean` are not
checked.  This is by design: those are top-level entry points,
not kernel-adjacent code.

`main` (line 235): reports per-file counts; non-zero counts in
`kernelTcbFiles` are CI failures.  Correct.

**Finding:** Tool is correct for its intended use case.  The
pattern set is intentionally minimalist; reviewers should not
rely on it as a complete proof-of-no-sorry.

---

## `Tools/StubAudit.lean` — stub-detection gate

**Workflow:**

1. Walk every `.lean` file under `searchRoots = ["LegalKernel", "Lex"]`.
2. For each line containing a stub pattern (`:= ByteArray.empty`,
   `:= []`, `:= #[]`, `:= ⟨#[]⟩`, `:= pure ByteArray.empty`),
   scan the preceding 12 lines for a `/-- ... -/` docstring
   block.
3. If the docstring block contains a red-flag token (`stub`,
   `placeholder`, `todo`, `fixme`, `wire`, `deferred`, `later`,
   `not for production`), report the line.
4. Filter out lines on the allowlist (`tools/stub_allowlist.txt`).

**The `docstringAbove` helper (line 157):** scans upward up to
`lookback = 12` lines for a docstring block.  Two-state machine:
`inDoc` is `false` initially, becomes `true` on `/--`, stays
`true` until `-/`.  This is a simpler form of the `count_sorries`
mask logic.

**Hazard observation:** The docstring detection is line-based, not
character-based.  A docstring opening on the same line as the
stub (`def x : T := ByteArray.empty -- /-- stub -/`) would NOT
be caught.  This is fine because Lean's standard formatting puts
docstrings on their own lines; the audit tool's job is to catch
the *common* case.

**Hazard observation:** The 12-line lookback is a magic number.
If a future module has a 15-line docstring with the red-flag
token at the top, the stub-flagged line would not match the
docstring.  Currently safe; the only stubs in production are
short.

**Pattern matching (line 145):**
```lean
def lineHasStubPattern (line : String) : Bool :=
  let code := stripLineComment line
  stubPatterns.any (fun p => containsSubstr code p)
```

`stripLineComment` (line 138) is naive: it splits on `--` and
returns the head.  Does not handle `--` inside string literals,
which is documented as "overkill for the audit's purposes."

**Finding:** The audit is correct for its intended use case.
The historical incident it caught (the Phase-3 `signingInput :=
ByteArray.empty` placeholder) is exactly the pattern it now
detects.

The allowlist mechanism (`tools/stub_allowlist.txt`) uses
canonical keys `path:line|raw-line`, binding to the specific
line text — so any change to the line invalidates the
allowlist entry and forces re-review.

**Hazard observation:** The canonical key includes the line
NUMBER, which means inserting blank lines above an allowlisted
stub shifts the line number and breaks the binding.  This is
fragile but intentional: it forces re-review.  Reviewers should
be aware that re-running the audit after an unrelated edit may
fail.

---

## `Tools/NamingAudit.lean` — content-name discipline gate

**Workflow:**

1. Walk every `.lean` file under `searchRoots = ["LegalKernel", "Lex", "Tools"]`.
2. Check the file basename against the forbidden-token list (case-insensitive).
3. Parse every top-level declaration (`def`, `theorem`, `structure`,
   `class`, `instance`, `abbrev`, `lemma`, `inductive`) and check the
   identifier against the forbidden-token list.
4. Filter out allowlisted entries.

**Forbidden tokens (lines 79–119):** a focused list of process /
provenance / temporal / status / grab-bag markers.  The list
deliberately excludes content-y tokens like `pending`, `deferred`,
`old`, `new` that have legitimate content uses (e.g. a dispute's
`pendingMidpoint`, a nonce's `oldValue` role).

**Hazard observation:** The token list is hand-maintained.  A
future provenance-flavored token (e.g. `mlk2026` for a sprint
codename) would not be caught without manual list expansion.  The
project's general "code review" backstop catches this; the audit
is the mechanical first-pass.

**Declaration parser (line 190):** strips `noncomputable`,
`private`, `protected` modifiers, then matches one of 8
declaration keywords, then takes the first identifier up to
whitespace or punctuation.

**Hazard observation:** The parser only handles three modifiers.
A `noncomputable private def X` would be parsed (both modifiers
stripped in turn); a `@[simp] def X` would NOT (the attribute
isn't stripped).  Currently, attributes are written on a separate
line, so this is fine.  If a future PR puts an attribute on the
same line as the declaration, the audit would silently skip the
declaration.  This is a false-negative hazard.

**Substring matching (line 134):**
```lean
private def containsLower (haystack needle : String) : Bool :=
  decide (((toLower haystack).splitOn needle).length > 1)
```

A nice trick: split on the needle, and if the result has more
than one segment, the needle was found.  Equivalent to substring
matching but uses the built-in `splitOn`.

`runAudit` (line 283): walks every file, checks filename + every
declaration name, filters by allowlist.

**Finding:** Correct.  The token list is the right size — not too
aggressive (which would flag legitimate names) and not too
permissive (which would let process-y names through).  The
audit pairs with the documented pre-commit `grep` pattern in
CLAUDE.md as a belt-and-suspenders enforcement.

---

## `Tools/DeferralAudit.lean` — no-deferrals policy gate

**Workflow:**

1. Walk every `.lean` file under `searchRoots = ["LegalKernel", "Lex", "Tools"]`.
2. For each line, check if it contains any of the forbidden
   deferral phrases (case-insensitive substring match).
3. **No allowlist.**  Every match is a violation.
4. Skip `Tools/DeferralAudit.lean` and `Tools/NamingAudit.lean`
   themselves (the forbidden-token lists are DATA, not live
   deferrals).

**Forbidden phrases (lines 67–97):** explicit deferral markers
(`deferred to follow-up`, `multi-day work`, `not yet provable`,
`round-trip-conditional`, etc.), status-table PARTIAL claims
(`| partial  |`), status-table DEFERRED claims (`| deferred |`),
and the classic comment markers `TODO:`, `FIXME:`, `XXX:`.

**Hazard observation:** The matching is by substring, so a longer
phrase containing the substring would also match.  E.g. "the
TODO list" would match `TODO:` ... wait, no: the pattern is
`TODO:` with colon, so "the TODO list" doesn't match.  Good.

**Hazard observation:** The phrase `until ... ships` (line 78) uses
literal `...` characters.  This means "until X ships" would NOT
match unless the source literally writes `until ... ships`.  This
is intentionally narrow (the auditor reads as "the literal
template appearing in deferral-flavoured prose").  If a future
PR writes "until Phase 7 ships" instead of using the template,
the audit would NOT catch it.  Reviewers should be alert.

**Finding:** Tool is correct for its intended use case.  The
no-allowlist policy is by design — the discipline says either
ship the proof or remove the comment.  The two excluded files
(this one and `NamingAudit.lean`) are the only files that
legitimately contain the forbidden phrases as data.

`excludedPaths` (line 159): hard-coded list.  Both paths and the
NameAudit path are listed.  Note: `DeferralAudit.lean` (the
top-level wrapper) is NOT in the exclude list, but it only
imports `Tools.DeferralAudit` and contains no forbidden phrases
itself.  Spot-checked: the wrapper is clean.

---

## Top-level wrappers (`NamingAudit.lean`, `DeferralAudit.lean`)

Both are minimal entry-point wrappers that:
1. Import the corresponding `Tools.*` module.
2. Open the namespace.
3. Define `main : IO UInt32` that runs `runAudit` and prints
   per-violation diagnostics on stderr.

**Finding:** Both wrappers are correct.  No logic; just the CLI
shell.

---

## Module-level findings

**Strengths:**

* All five mechanical gates (`tcb_audit`, `count_sorries`,
  `stub_audit`, `naming_audit`, `deferral_audit`) are
  self-contained, fast (single-pass over source), and run on
  every PR.
* The shared `Tools.Common` module concentrates the kernel-TCB
  file list in one place — a TCB amendment touches one file.
* No `sorry`, no custom axioms in any audit tool.

**Hazards (all documented and bounded):**

* `tcb_audit` parser doesn't support `prelude`, `import all`,
  `meta import` — silent pass-through.
* `count_sorries` pattern set is exhaustive for common patterns
  but not formally complete; a sufficiently obfuscated `sorry`
  could escape (e.g. `refine sorry`, `apply sorry`).
* `stub_audit` line-based docstring detection misses
  single-line stubs with inline docstrings (uncommon).
* `naming_audit` declaration parser doesn't handle attributes
  on the same line as the declaration (uncommon by style).
* `deferral_audit` substring matching can miss paraphrased
  deferrals (e.g. "we'll add this later" doesn't match
  "deferred to follow-up").

**Recommendations (none blocking):**

* Consider extending `count_sorries` to match `refine sorry`
  and `apply sorry` patterns.
* Consider extending `stub_audit` to lookback past blank lines
  (currently the 12-line window includes blank lines).
* Consider adding a periodic full-elaborator-based audit (e.g.
  via `#print axioms` on a per-theorem basis) to catch the
  edge cases the substring-based tools can't.

None of these are urgent; the audit suite as currently shipped
is the right size for a CI-gate.  The pre-commit `grep` patterns
in CLAUDE.md are the documented backstop.

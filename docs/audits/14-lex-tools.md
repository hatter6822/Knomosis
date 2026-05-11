# Audit 14 — Lex audit-binary tooling libraries

Scope: the 5 files in `/home/user/Canon/Lex/Tools/` (~4125 lines
total). These are the *library* layers behind the
`lex_lint` / `lex_codegen` / `lex_diff` / `lex_format` Lake
executables; the thin entry wrappers in `Lex/Bin/` are audited
separately.

Status: all 5 modules are **non-TCB**. Bugs surface as wrong
audit-binary verdicts (false positive/negative CI gates) but
cannot violate kernel invariants. Verified by inspection — none
of the files import any `LegalKernel.*` TCB module; they import
each other, `Tools.Common`, `Lean.Data.Json`, and
`Lex.DSL.Deployment` only.

Header: every file carries the canonical Canon copyright header.

---

## 1. `Lex/Tools/Common.lean` (985 lines) — shared utilities

### 1.1 Imports

`/home/user/Canon/Lex/Tools/Common.lean:36-39`:
- `Tools.Common` (the non-Lex audit binaries' shared helpers).
- `Lean.Data.Json`, `Lean.Data.Json.Parser`, `Lean.Data.Position`.

All Lean-core and project-internal — consistent with the Std-only
posture. Importing `Tools.Common` may be slightly unusual since
the Lex tools live under a different namespace, but it is fine
because it is the project's *non-Lex* tools-helper library and
not a TCB module.

### 1.2 Namespace mismatch (deliberate)

`Common.lean:41-50`: the file lives at `Lex/Tools/Common.lean`
(module path `Lex.Tools.Common`) but declares
`namespace LegalKernel.Tools.Lex`. Documented as deliberate so
every Lex binary and test references the same namespace.

### 1.3 Key data structures

| Structure | Lines | Role |
|---|---|---|
| `SourcePos` | 64-69 | 1-indexed line, 0-indexed col, with own `Repr`/`DecidableEq`. |
| `ClauseSource` | 81-86 | (file, position) pair. |
| `Severity` | 91-98 | `error`/`warning`/`info`. |
| `Diagnostic` | 106-119 | code, severity, source, message, notes, hints. |
| `RegistryEntry` | 194-204 | identifier, actionIndex, firstRelease, sourceLine. |
| `Violation` | 297-304 | code, line, message — registry-validation result. |
| `BinderKind` | 445-455 | explicit / implicit / strictImplicit / `inst` (added audit-4). |
| `ParamSpec` | 458-465 | name : type with binder kind. |
| `AuthorityRefKind` | 468-473 | `actorRef` / `policyRef`. |
| `SignedByRef`, `AuthorizedByRef` | 476-487 | per-clause payloads. |
| `PropertyClaim` | 490-509 | name + list of opaque arg strings (audit-3 simplified). |
| `ProofOverride` | 512-517 | property + raw tactic text. |
| `RegistryEffectKind` | 520-529 | `none_` / `replaceKey` / `registerIdentity` / `localPolicy`. |
| `LawDecl` | 538-570 | the §5.2 JSON-mirror structure. |

Every public structure derives `Repr` and `DecidableEq` so the
diagnostic and diff layers can compare without help — except
`Diagnostic` itself, which deliberately only derives `Repr` and
`Inhabited` (not `DecidableEq`) because it transitively contains
freeform `String`s that don't benefit from structural equality.

### 1.4 Parser totality

**Registry parser** (`parseRegistryLine` lines 245-263,
`parseRegistry` lines 269-280):
- Skips blank/comment lines, returns `Option (Except String _)`.
- Malformed `<idx>` returns `.error` with line number.
- Malformed (non-3-token) row returns a structured error.
- Total — never throws or panics. Final result is
  `Except (List String) (List RegistryEntry)`.

**JSON parser** (`LawDecl.fromJson` lines 769-809):
- Uses `Lean.Json.parse` (the core JSON parser; total — returns
  `Except`).
- Each field decoded via `getObjValAs?`; any missing/wrong-type
  field returns `Except` error.
- Schema-version mismatch (`schemaVersion != 1`) returns
  `.error` at line 772-773.
- `params`, `satisfies`, `proof_overrides` arrays are
  type-checked via `match Lean.Json.arr a => ...`; non-array
  bodies produce a structured error.
- **Sharp**: this is NOT a hand-rolled JSON parser — it
  delegates to Lean core's `Lean.Json.parse`. That is the
  correct and total approach. The codec itself is fully total.

**Round-trip claim** (line 765-768): "`LawDecl.fromJson
(LawDecl.toCanonicalJson l) = .ok l`". This is documented but
not mechanised; tests must enforce.

### 1.5 JSON codec — determinism and field-order subtlety

The docstring at lines 704-734 admits a sharp point: the actual
on-disk field order is the *reverse-alphabetical* order produced
by Lean core's `Json.mkObj` (which builds an internal RBNode and
serialises in that traversal order), **not** the `[schema_version,
identifier, version, ...]` order in which the encoder calls
`mkObj`. The docstring at lines 711-723 explicitly enumerates the
actual emitted order. The point made is reasonable: byte-stability
is what determinism requires, and JSON itself doesn't impose key
order, so consumers must not depend on order. Worth verifying:
the documented order is locked in by Lean core but could shift
across toolchain bumps.

The encoder uses `json.pretty ++ "\n"` (line 763), so the output
is human-readable AND newline-terminated.

### 1.6 `PropertyClaim.args` — audit-3 simplification

Lines 490-509, 621-661: the docstrings document a fairly serious
pre-audit-3 round-trip bug where args were encoded as raw JSON,
decoded via `compress`, producing `["foo"]` → `["\"foo\""]`. The
current shipped form treats args as opaque strings (wrapped via
`Json.str` on encode, unwrapped via `getStr` on decode). This is
correct and symmetric. M2's typed-arg pass is deferred.

### 1.7 `whitespaceTokenize` and `stripWhitespace`

Lines 210-214, 228-240: hand-rolled because `String.trim` /
`String.split` use a deprecated `String.Slice` return type in
current Lean. The implementations are O(n) and look correct.
Audit-2 noted that `whitespaceTokenize` previously missed `\n` —
this is now fixed. The docstring notes "all current callers pass
single-line input"; the function is hardened defensively.

### 1.8 Path-traversal hardening

Lines 832-866: `isSafeIdentifier` + `codegenInputFileName?` reject
identifiers containing characters outside `[a-zA-Z0-9_.]`. Note
that `.` is in the allowed set but `codegenInputFileName?`
replaces every `.` with `_` before suffixing `.json`, so a
hypothetical `«..»`-quoted identifier produces the file name
`__.json` rather than `..\.json`. This is sound. The
backward-compatible `codegenInputFileName` (no `?` — line 873)
falls back to sanitisation rather than `none`.

### 1.9 `atomicWriteIfChanged` (lines 977-983)

Implements `<path>.tmp` → `rename(2)` atomicity. Idempotent
(no-op if existing content matches). Documented limitations
(lines 955-975):
- TOCTOU between `pathExists` and `writeFile` — two concurrent
  writes both observe the absent sentinel; last-writer wins.
- Predictable `.tmp` suffix permits a symlink-redirect attack on
  shared filesystems.

Both are documented but unmitigated. Acceptable per the docstring
because Lex/Inputs is a repo-internal directory.

### 1.10 `loadCodegenInputs` (lines 891-907)

- Tolerates an absent directory (returns `.ok []`).
- Sorts results by `actionIndex` (using `Array.qsort` which is
  NOT stable; if two laws share an index, ordering is
  unspecified). This *is* observed and mitigated in the
  Codegen.lean canonical manifest (which adds an identifier
  tie-breaker, lines 814-818) but **not** here. A registry with
  two laws sharing an index is itself an L005 violation caught
  by `validateRegistry`, so the instability is contained, but
  `loadCodegenInputs` could exhibit non-deterministic ordering
  under a corrupt input set.

### 1.11 `walkLeanFiles` (lines 915-931)

- `partial def` (marked).
- Excludes hidden dirs, `_lex_inputs`, `.lake`, `build`.
- Returns `IO (List FilePath)`.
- Note: there is **no symlink-loop protection** — if a developer
  inserts a symlink loop into the source tree, this can spin
  forever. Acceptable since it walks user-controlled source
  trees.

### 1.12 Documentation drift / sharp points

- `walkLeanFiles` docstring at line 911-914 says "filters out
  hidden directories and `_lex_inputs`" but also filters `.lake`
  and `build`. Minor doc miss.
- `Diagnostic.format` (lines 130-136) emits a line that includes
  *backslash-newline* (line 132: trailing `\`). This is a Lean
  source-code line-continuation, not an emitted byte; the
  output is a single header line. Correct.
- `ClauseSource.ofSyntax` (lines 149-158) hardcodes line/col to
  0/0 when no FileMap is supplied; this is a fall-back, not the
  canonical path. Callers should use `Diagnostic.atSyntax`.

---

## 2. `Lex/Tools/Lint.lean` (227 lines) — `lex_lint` library

### 2.1 Imports

Line 41: `import Lex.Tools.Common`. Single import; reasonable.

### 2.2 Diagnostic helpers

Lines 55-75: `registryDiagnostic` and `codegenInputDiagnostic`
create line-1-col-0 anchored diagnostics. The registry helper
takes an actual line number; the codegen helper hardcodes line 1
(documented at lines 50-52 as a placeholder, since file-level
checks don't know line numbers).

### 2.3 Lint passes

| Pass | Lines | Behaviour |
|---|---|---|
| `lintRegistry` | 83-103 | Reads registry, parses (`.error` returns `Except` with file-not-found), validates rules. Parse errors become L007 diagnostics; rule violations carry their own L-code. |
| `lintCodegenInputs` | 108-127 | Absent directory ≡ empty set, **not** an error. Per-file JSON parse errors become L007. |
| `lintCodegenAgainstRegistry` | 132-149 | For each codegen-input, looks up registry entry by identifier; unknown identifier or mismatched actionIndex → L007. |

### 2.4 Exit codes (documented lines 21-26, implemented lines 198-219)

- `0` — every check passed.
- `1` — at least one error-severity diagnostic.
- `2` — internal error (registry file not found).

Verified: the `--help` text mirrors these.

### 2.5 Behaviour on malformed inputs

| Input | Exit code |
|---|---|
| Registry parse error (malformed row) | 1 (L007 emitted) |
| Registry rule violation (duplicate id, gap) | 1 (L005/L006/L007) |
| Registry file absent | 2 (internal error) |
| Codegen-input dir absent | 0 (treated as empty set) |
| Codegen-input JSON parse error | 1 (L007) |
| Codegen-input not in registry | 1 (L007) |
| Codegen-input action_index mismatch | 1 (L007) |

### 2.6 Documentation drift

The §13.1 rule numbering in `validateRegistry` (Common.lean
319-377) uses L005 for uniqueness violations, L006 for
reserved-range, and L007 for everything else (format, monotone,
release-tag). The Lint module emits L007 for parser errors AND
synthesizes "see §13.1 for full rule set" hints — accurate.

---

## 3. `Lex/Tools/Codegen.lean` (1378 lines) — `lex_codegen` library

### 3.1 Imports

Line 73: `import Lex.Tools.Common`. Single import; reasonable.

### 3.2 Configuration structures (lines 83-122)

- `Outputs`: per-target file paths with sensible defaults
  pointing into `LegalKernel/`.
- `CodegenOptions`: `checkOnly`, `canonical`, `genPropertyTests`
  bools + paths. Defaults via `instance : Inhabited` rather than
  `deriving Inhabited` (lines 99, 125) — necessary to preserve
  the `:= "..."` literals on the path fields.

`parseOptions` (lines 130-139): trivial arg-walking; ignores
unknown args (forward-compatibility).

### 3.3 Fence-marker contract

**Markers** (lines 149-152):
```
beginFenceMarker = "-- BEGIN LEX-GENERATED (do not edit by hand)"
endFenceMarker   = "-- END LEX-GENERATED"
```

Both are matched *after* `stripWhitespace` (lines 194, 197, 225,
231). This means a fence with leading whitespace is recognised;
the leading whitespace is also preserved on rewrite (via
`leadingWhitespace`, lines 249-250, applied in `replaceFenceAt`
lines 297-298).

**Fence locators**:
- `locateFence` (185-207): single fence per file. Rejects
  duplicates with `multipleBegin` / `multipleEnd`; rejects
  reversed order; rejects missing END.
- `locateAllFences` (218-236): multi-fence variant. Returns
  pairs in document order. Same error-handling. Used by
  `appendToTargetFile` since the action-file has 2 fences,
  encoding-file 3, signedAction-file 2.

**Splice** (`replaceFenceAt` lines 292-304):
- Header: `lines.take b` joined with newlines.
- Footer: `lines.drop (e + 1)` joined.
- Markers: re-emitted with original indentation.
- Empty `generated` → BEGIN/END adjacent (no body).
- Non-empty body terminated with `\n` if not already.

**Critical**: when there are multiple fences, the caller MUST
process them in **descending index order** (line 707-715) so
earlier replacements don't shift later indices. `appendToTargetFile`
correctly does this via `qsort` on `b` descending (lines 715-718).

**Idempotence**: `replaceFenceAt` preserves marker indentation,
so re-running on already-rewritten content is a no-op. Verified by
the `atomicWriteIfChanged` check at line 720 (compares before/after
bytes).

### 3.4 M1 emission policy — `requiresEmission` returns `false`

Lines 363-364: in M1, `requiresEmission` returns `false` for
**every** declaration. Consequence: every renderer
(`renderActionInductive`, etc.) returns `""`. The fence-rewrite
machinery is wired and exercised by the test suite, but the
shipped target files all have empty fences in M1.

This means `lex_codegen` is **effectively a no-op in M1** —
verified at lines 381-492. M2 is expected to flip this on a
per-law basis.

### 3.5 Audit-5 forward-protection

Lines 418-425, 431-438, 467-478: the parameterised-encode,
parameterised-decode, and replaceKey/registerIdentity renderers
emit deliberately illegal Lean tokens (`M2_RENDERER_TODO_...`) so
a future author who flips `requiresEmission := true` without
rewriting the renderer hits an immediate parse error rather
than silently producing wrong on-wire format. This is good
defence-in-depth.

### 3.6 `--check` mode

`checkTargetFile` (lines 564-598):
- Absent target file with empty rendering → OK.
- Absent target with non-empty rendering → L026.
- `locateAllFences` error + non-empty rendering → L026.
- Fence-count mismatch → L026.
- Per-fence body byte-mismatch (after normalising trailing `\n`)
  → L026.

### 3.7 Advisory file lock

Lines 607-677. `tryAcquireLock` (629-634) is the TOCTOU-classic
`pathExists`-then-`writeFile`. Documented at 617-622. `withFileLock`
(655-677) is the exception-safe wrapper; releases via
`safeRelease` (lines 667-668) which swallows IO errors during
cleanup, so the body's outcome is preserved verbatim.

**Sharp**: the lock is purely advisory; concurrent invocations
on the same target can race past the `pathExists` check. Documented.
Per audit-2/audit-5 notes, lock-leak class via early-return paths
was closed by the `withFileLock` introduction.

### 3.8 `--canonical` and `--gen-property-tests` modes

- `--canonical` (lines 792-849): writes a structured plaintext
  manifest at `Lex/Inputs/canonical_manifest.txt`. Sorts laws by
  `(actionIndex, identifier)` for total stability — lines 814-818.
- `--gen-property-tests` (lines 1062-1176): emits a real Lean
  test file at `Lex/Test/AutoGenProperties.lean`. Auto-generates
  per-(law, property) tests for the 5 hardcoded supported kernel
  laws (line 899-904); other laws produce coverage-comment
  entries. Each test wraps in a `CANON_AUTOGEN_SKIP=1` skip
  envelope.

Both modes lock via `withFileLock` (lines 1224, 1281-1282).

### 3.9 Main dispatch (lines 1190-1369)

Order of mode checks:
1. `--help` / `-h`
2. `--gen-property-tests`
3. `--canonical`
4. (default) load codegen inputs + registry, validate, render,
   then either `--check` or rewrite-in-place.

### 3.10 Behaviour on malformed inputs

| Input | Exit code |
|---|---|
| `--help` | 0 |
| Malformed codegen-input JSON | 2 |
| Malformed registry | 2 |
| Codegen-input not in registry / wrong action_index | 1 |
| `--check` mode, fence divergence | 1 |
| `--check` mode, AutoGen.lean divergence (when present) | 1 |
| Concurrent invocation (lock contended) | 1 |
| Write error during fence rewrite | 1 |

### 3.11 Documentation drift / sharp points

- The module's top docstring (line 55-56) says `--canonical` is
  "M2 mode: regenerate the entire target body. Not yet
  implemented." This is now stale — the audit-3 update at lines
  1232-1288 implements `--canonical` as the structured manifest
  scaffold (not full-body regeneration). The exit-code description
  at 60-62 also conflicts with the implemented behaviour.
- The `Outputs` defaults (lines 85-92) use string-literal
  initialisers that require the `Inhabited` instance hack — a
  comment at 96-99 documents this trap.
- The auto-gen renderers (lines 934-1037) hardcode the parameter
  signatures of 5 kernel laws (transfer/mint/burn/freezeResource/
  reward). Adding a 6th law to `autoGenSupportedLaws` without
  adding a `renderXTest` clause results in `none` from every
  property renderer — a silent miss, mitigated only by the
  coverage-comment fallback at lines 1144-1145.
- `emitAutoGenLean` emits a Lean source file with hardcoded
  imports (line 1090-1098). If the target law set changes (e.g.
  burn is removed), the import list still contains the import —
  the regenerated file would not compile. The generator does not
  prune unused imports.

---

## 4. `Lex/Tools/Diff.lean` (976 lines) — `lex_diff` library

### 4.1 Imports

Lines 62-63: `Lex.Tools.Common` and `Lex.DSL.Deployment`. The
second is needed for `LegalKernel.DSL.Deployment` /
`InvariantClaim` types used in manifest-level diffing.

### 4.2 Key data structures

| Structure | Lines | Role |
|---|---|---|
| `Diff` | 74-79 | (before, after) string pair. |
| `VersionBump` | 82-91 | `none_` / `patch` / `minor` / `major`. |
| `LawDiff` | 102-136 | per-law diff with one `Option Diff` per clause + version metadata + `refinementProofPresent` bool. |
| `AuthorityBindingDiff` | 309-314 | slot name + Diff. |
| `InvariantClaimDiff` | 317-322 | kind name + Diff. |
| `DeploymentDiff` | 325-344 | added/removed/modified lists for laws, authority slots, invariant claims. |

### 4.3 Diff algorithm — per clause

`computeLawDiff` (lines 148-184): each clause diffed
independently via `diffString` (which returns `none` if equal).
Verified that **every** clause from `LawDecl` is covered. Worth
noting:

- `satisfies` (lines 155-165): audit-4 fix — claims rendered as
  `name[args,...]` so a same-name claim with different args is
  caught. Pre-audit-4 only `name` was diffed.
- `registry_effect` (lines 180-182): compared via
  `toString (repr ...)` — relies on `RegistryEffectKind`'s
  derived `Repr` being stable across runs (it's an inductive
  with 4 constructors, so this is fine).
- `params` (lines 172-175): only `.name` is included — the
  rendered diff string doesn't include type or kind. A
  param-type or binder-kind change is **silently invisible** to
  the diff. This is a real latent bug worth flagging.
- `proof_overrides` (lines 176-179): only `.property` is
  included — the tactic body itself is not diffed.

### 4.4 Empty-diff predicate

`LawDiff.isEmpty` (lines 197-202): audit-3 bugfix — pre-fix
ignored `versionBefore` / `versionAfter`, so a pure version
bump was misclassified as "empty" and filtered out by
`computeLawSetDiff`. Now includes the version-equality check.

### 4.5 Version-bump classifier

`classifyVersionBump` (lines 241-247):
- Empty diff → `none_`.
- Only proof_overrides → `patch`.
- Only pre → `minor`.
- Only satisfies (additions only) → `minor`.
- Anything else → `major`.

Sharp: `isProofOnly` (lines 206-210) checks "no clause diff
EXCEPT possibly proof_overrides". The classifier then names this
`patch`. Note that the `proofOverridesDiff` check is **omitted
from `isProofOnly`'s body** — meaning the predicate is true even
when `proofOverridesDiff.isSome`. That's the intended semantics
(a patch is when ONLY proofs changed) — verified correct.

### 4.6 Refinement-proof name and check

`refinementProofName` (lines 253-258): `1.0.0` →
`refinement_v1_0`. Handles 2-segment and other versions
permissively.

`hasRefinementProof` / `checkRefinementProof` (lines 263-272):
checks if `after.proofOverrides` contains an entry whose
`property == "refinement_v<MAJ>_<MIN>"`.

### 4.7 Git integration

`isSafeGitRef` (lines 410-418):
- Rejects refs that start with `-` (flag injection).
- Rejects refs containing `:` (would smuggle a second pathspec
  through `git show <ref>:<path>`).
- Rejects ASCII control / non-ASCII characters.

`isSafeGitPath` (lines 448-466):
- Rejects empty, absolute paths, Windows separators, `..`
  segments anywhere, control chars, non-ASCII.
- Note: `isPrefixOf` is checked on `"../"` and `containsSubstring`
  on `"/../"` — there's also an `endsWith "/.."` check. Plus
  `path != ".."`. Good coverage; appears fully airtight against
  `..`-traversal.

`gitShow` / `gitLsTree` (lines 470-550): `IO.Process.output`
with safe argv. Audit-4 wraps IO errors via `toBaseIO` so a
missing `git` binary returns `none` rather than throwing.
Audit-3 fixed `git ls-tree` to include `-r` (was returning empty
listings before).

### 4.8 Manifest-level diff

`computeManifestDiff` (lines 681-747): walks `Deployment.laws`,
`Deployment.authority`, `Deployment.invariantClaims`.

`invariantClaimToString` (lines 649-670): audit-5 — uses
**`\x1f` (ASCII US byte)** as a separator between sorted law
names, because the prior `,` separator collided with the French-
quoted `«foo,bar»` Lean identifier syntax (commas are legal
inside identifiers). The US byte is illegal in Lean identifiers
and never written back to a manifest, so it's a safe display-
only delimiter. Audit-3 sorts names lexicographically so
`[A,B]` and `[B,A]` compare equal.

`combineManifestAndLawDiffs` (lines 753-757): trivial merge —
takes manifest fields from one diff and `lawsModified` from
another.

### 4.9 Behaviour on malformed inputs

| Input | Exit code |
|---|---|
| `--help` | 0 |
| Directory mode, before-dir absent | 0 (treated as empty) |
| Directory mode, malformed JSON | 2 |
| `--git`, unsafe ref | 2 (via `throw IO.userError`) |
| `--git`, git failure | 2 |
| `--git`, parse failure | 2 |
| Valid diff with declared/computed bump mismatch | 1 (L007) |
| Valid diff with missing refinement proof for minor | 1 (L016) |
| Wrong arg count | 2 |

### 4.10 Documentation drift / sharp points

- `formatLawDiff` (line 768-791): emits a `refinement_proof:
  PRESENT` / `MISSING (L016)` line only when the bump is `minor`.
  But `LawDiff.refinementProofPresent` is populated for every
  modified law in `computeLawSetDiff` (line 599), so the data is
  always there even though it's only displayed for minor bumps.
- `params` diff drops type/kind info (see 4.3) — undocumented
  limitation. A reviewer comparing two versions whose params
  changed type from `Nat` to `Int` would see "no diff" in
  `params`.
- The default load of `loadCodegenDir` (line 373-387) does NOT
  sort, but `lawIdentifiers` (line 579-580) and the iteration in
  `computeLawSetDiff` (lines 591-602) walk `before` first. If
  the directory listing returns laws in a non-deterministic
  order, the `lawsModified` list will be in non-deterministic
  order — affecting the diff display, not correctness.
- `containsSubstring` (lines 423-432) is a hand-rolled
  substring-search with a manual decreasing-by proof. Looks
  correct; O(n*m) worst case but `n` and `m` are tiny.

---

## 5. `Lex/Tools/Format.lean` (559 lines) — `lex_format` library

### 5.1 Imports

Line 72: `import Lex.Tools.Common`. Single import.

### 5.2 Canonical clause order

Lines 84-107: hard-coded list of clause keywords (`lex_*` and
`deploy_*`). Unknown clauses get index 1000 (line 115) — placed
after canonical ones; among themselves their original order is
preserved by the stable secondary sort.

### 5.3 Line-classification predicates (lines 119-160)

- `stripTrailingWhitespace`, `isClauseStartLine`,
  `extractClauseKeyword`, `isBlockOpener`, `isCommentLine`,
  `isBlankLine` — all single-line predicates.
- `isBlockOpener` matches `lexlaw ` (or `\t`) or `deployment `
  (or `\t`). The body indentation is computed by counting
  leading whitespace.

### 5.4 Block segmentation

`segmentBlockBody` (lines 234-323):
- Walks lines top-to-bottom.
- Comments + blanks buffered until the next non-blank line.
- If next line is a clause-start: comments attach as
  `precedingComments` (move with the clause on reorder).
- If next line is a continuation: comments + line become
  continuations of current clause.
- If never any clause: comments become `preludeLines`.

The function is `Id.run do` — pure modulo `IO`.

### 5.5 Top-level format function

`formatLexSource` (lines 420-476):
1. Split into lines.
2. Walk top-to-bottom; for each line:
   - If block-opener: collect body lines until indentation drops
     to or below opener's; segment, canonicalise empty-events,
     sort, emit.
   - Else: pass through with trailing-whitespace stripped.
3. Drop trailing blank lines, append one final newline.

Marked `partial def`. The `while` loop uses an `idx`-based
manual iteration over a `linesArr` — clean approach.

**Audit-4 fix** at lines 447-456: the body-line collection
previously kept trailing blank lines, which then attached as
continuations of the last clause and got misplaced after sort.
Fix is to trim trailing blanks from `bodyLines` before
`segmentBlockBody`.

### 5.6 Empty-events canonicalisation

`isEmptyEventsClauseGroup` (lines 376-392):
- Recognises `lex_events := do pure ()`, `lex_events := do
  nothing`, and the multi-line forms (leader `lex_events := do`
  with continuation `pure ()` or `nothing`).

`canonicaliseEmptyEventsClause` (lines 396-402): rewrites to
single-line `lex_events := []`, preserving leader indentation.

### 5.7 Idempotency

The pipeline is composed of:
1. `stripTrailingWhitespace` — idempotent (already-stripped is
   unchanged).
2. Block segmentation + canonical sort — idempotent since the
   canonical order is total.
3. Empty-events canonicalisation — idempotent since the result
   is the single-line form, which is no longer detected as
   "needs canonicalisation" on a second pass.
4. Trailing-blank stripping + single final newline — idempotent.

Composing idempotent transforms gives an idempotent pipeline.
Worth verifying experimentally; the docstring at lines 33,
417 claims `format ∘ format = format`.

### 5.8 In-place rewrite — symlink protection

Lines 530-546: audit-5 hardening — refuses to follow a symlink
when `--in-place` is requested. Uses
`System.FilePath.symlinkMetadata` (the `lstat` variant) to
detect symlinks without following them. Bails out with exit
code 2 and a precise diagnostic. Without this guard,
`IO.FS.rename` would follow the symlink and overwrite the
target.

### 5.9 Behaviour on malformed inputs

| Input | Exit code |
|---|---|
| `--help` | 0 |
| File not found | 2 |
| `--in-place` on a symlink | 2 (audit-5 refusal) |
| Lex source with unknown clause keyword | 0 — unknown kept, sorted last (forward-compat) |
| Lex source with no `lexlaw` block | 0 — everything passes through |
| Invalid Lean syntax inside `lex_impl := do ...` | 0 — formatter doesn't parse, just sorts |

### 5.10 Documentation drift / sharp points

- The block-end detection (lines 442-446) uses **only**
  indentation comparison. If a clause continuation is
  outdented (legitimate Lean has flexible indentation),
  it would be treated as the end of the block. In practice
  `lex_*` clauses are inside `where` with 2-space indentation,
  so this is fine for the LX corpus.
- `--in-place` writes via `atomicWriteIfChanged` (from Common,
  line 550): the no-write-if-unchanged property holds, so a
  Lex file already in canonical form is not touched.
- The format function does NOT validate that segments parse as
  Lean — it's a textual rewrite. If the input has unbalanced
  syntax, the output may have unbalanced syntax in a different
  arrangement.

---

## 6. Cross-cutting findings

### 6.1 Hand-rolled JSON parser?

No. `LawDecl.fromJson` (Common.lean:769) delegates to
`Lean.Json.parse` from Lean core. The codec layer above it is
hand-written but uses `getObjValAs?` everywhere — total and
explicit.

### 6.2 Golden-byte sidecar contracts

Two byte-stable artefacts exist:
- `Lex/Inputs/canonical_manifest.txt` (emitted by `lex_codegen
  --canonical`) — checked via `--canonical --check`.
- `Lex/Test/AutoGenProperties.lean` (emitted by `lex_codegen
  --gen-property-tests`) — checked via `--check` if present
  (Codegen.lean:1335).

Both rely on byte-stable inputs:
- Sort by `(actionIndex, identifier)` tie-breaker (Codegen
  814-818, 1063-1067).
- Hardcoded helper-source strings (Codegen 1090-1137).

A Lean toolchain bump that changes `Json.pretty` output
formatting would silently invalidate the golden bytes.

### 6.3 Partial codegen

Codegen.lean:363-364 makes `requiresEmission` return `false`
universally in M1. The renderers (lines 381-492) all return
empty strings for the M1 corpus. The infrastructure is
production-ready but emits nothing — a deliberate "skeleton
milestone" posture per the LX implementation plan. The
forward-protection (audit-5, lines 418-425, 431-438, 467-478)
ensures a flip without proper M2 rendering would error
immediately rather than silently corrupt.

### 6.4 Unchecked file ops

- `loadCodegenInputs` / `loadCodegenDir`: read files but treat
  absent directory as empty (not an error). Acceptable
  behaviour.
- `atomicWriteIfChanged`: documented TOCTOU + symlink risks.
- `gitShow` / `gitLsTree`: wrap subprocess IO errors via
  `toBaseIO` (audit-4) so missing `git` returns `none`.
- `lex_format --in-place` refuses symlinks (audit-5).

### 6.5 Documentation drift summary

| Location | Drift |
|---|---|
| Codegen.lean:55-62 | top docstring says `--canonical` "not yet implemented" / exit 2; audit-3 implemented it as scaffold mode. |
| Diff.lean:172-175 | params diff loses type/kind info (undocumented). |
| Common.lean:911-914 | walkLeanFiles docstring lists fewer exclusions than the code (`.lake`, `build` are also excluded). |
| Common.lean:704-734 | "field order matches §5.2 exactly" was wrong; current docstring acknowledges actual reverse-alphabetical Lean-core order and argues byte-stability is what matters. |
| Codegen.lean:1062-1176 | `emitAutoGenLean` hardcodes imports; growing/shrinking the supported-law set would leave stale imports in the generated file. |

### 6.6 Sharp behaviours under malformed input — summary

- `lex_lint`: malformed JSON in `Lex/Inputs/` exits 1 (L007);
  absent registry exits 2; absent inputs dir exits 0.
- `lex_codegen`: malformed JSON exits 2 (loadCodegenInputs
  returns `.error`); fence-mismatch in `--check` exits 1;
  concurrent invocation (lock contended) exits 1.
- `lex_diff`: malformed JSON exits 2; declared-vs-computed
  bump mismatch exits 1 (L007); minor bump without proof
  exits 1 (L016); unsafe git ref exits 2 via
  `throw IO.userError`.
- `lex_format`: malformed Lean inside `lex_impl` is NOT
  detected — the formatter is textual; missing file exits 2;
  symlink-in-place exits 2.

---

## 7. Concrete latent-bug candidates worth tracking

1. **`Diff.lean:172-175`**: `paramsDiff` only compares
   `param.name`, not `type` or `kind`. A param-type change is
   invisible to the diff. Likely a real defect; the audit-4
   note about `satisfies.args` suggests the same fix pattern
   should apply here (include type/kind in the rendered
   diff-string).
2. **`Diff.lean:176-179`**: `proofOverridesDiff` only compares
   `.property`, not `.tacticBlock`. A tactic-body change is
   invisible to the diff classifier. Whether this matters
   depends on the §14.2 policy for proof-body changes; the
   `patch` classification at line 244 assumes proof_overrides
   changes are detectable, but `isProofOnly` (lines 206-210)
   doesn't actually require `proofOverridesDiff.isSome` —
   meaning **a no-change diff is classified `patch`** if no
   other clauses changed, which is a no-op call to
   `classifyVersionBump`. Worth verifying that `isEmpty` is
   checked before `isProofOnly` (it is — line 243).
3. **`Common.lean:891-907`** (`loadCodegenInputs`): sort by
   `actionIndex` only; non-stable `qsort` is non-deterministic
   on duplicate indices. Acceptable since duplicates are an
   L005 violation, but worth documenting that the codegen-input
   load is only deterministic under registry-valid inputs.
4. **`Codegen.lean:1090-1098`**: `emitAutoGenLean` hardcodes
   imports. Adding/removing a supported law without updating
   the import set leaves stale imports. Mitigated only by Lean
   warning-as-error CI behaviour.
5. **`Format.lean:442-446`**: block-end is detected purely by
   indentation. Lex permits flexible indentation; an outdented
   continuation would close the block early.

None of these is kernel-affecting — all five are non-TCB
audit-binary modules. But each is a real opportunity to harden
the toolchain before LX-M2 lands the kernel-built-in re-
expression workload.

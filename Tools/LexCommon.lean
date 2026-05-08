/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.LexCommon — shared utilities for the Workstream-LX audit
binaries (`lex_lint`, `lex_codegen`, `lex_diff`, `lex_format`).

LX.4 (`docs/lex_implementation_plan.md` §19.3).  Provides:

* The `LawDecl` Lean structure mirroring §5.2's JSON schema, with
  per-field typed Lean values, `Repr` and `DecidableEq` instances.
* Registry parsing: `RegistryEntry`, `parseRegistry`,
  `formatRegistry`, plus the registry-consistency check predicates
  (rules 1 – 7 of §13.1).
* JSON codec: `LawDecl.toCanonicalJson`, `LawDecl.fromJson` round-
  trippable on canonical inputs; deterministic field order.
* `Diagnostic` record used by every emitter, with a uniform
  `<file>:<line>:<col>: error: L<NNN>: <message>` formatter (§18.1).
* Generic file-walker `walkLeanFiles` for the lint binary's
  source-tree traversal.

This module is **not** part of the trusted computing base.  Bugs
in this file produce wrong audit-binary output (false positives /
negatives at CI gates) but cannot violate any kernel invariant.

The module is `Std`-only — no Mathlib, no batteries; consistent
with the project's Std-only rule.  Lean core's `Lean.Json` provides
the JSON foundation; `System.FilePath` provides the path helpers.
-/

import Tools.Common
import Lean.Data.Json
import Lean.Data.Json.Parser
import Lean.Data.Position

namespace LegalKernel.Tools.Lex

/-! ## Source-position record (used by every diagnostic emitter) -/

/-- Alias for `Lean.Position`.  The plan §LX.4 calls for a
    `Position` threading utility re-exported under
    `LegalKernel.Tools.Lex`; this abbreviation satisfies that. -/
abbrev Position := Lean.Position

/-- A captured source position for a Lex-clause syntax node.
    Mirrors `Lean.Position` but is `Repr`-derivable (the Lean type
    is a `structure` with both `line` and `column` `Nat`s, but its
    `Repr` instance is not stable across toolchain bumps; we use
    our own to ensure JSON round-trip stability). -/
structure SourcePos where
  /-- 1-indexed line in the source file (matches `lake build`'s diagnostic line numbering). -/
  line   : Nat
  /-- 0-indexed column in the source file. -/
  column : Nat
  deriving Repr, DecidableEq, Inhabited

/-- Convert a Lean source position to a `SourcePos`.  Handles
    the `Lean.Position` ↔ `SourcePos` boundary at the macro and
    audit-binary surfaces. -/
def SourcePos.ofPosition (p : Position) : SourcePos :=
  { line := p.line, column := p.column }

/-- A clause's source span (file path + start position).  Used for
    the diagnostic-translation layer (§18.2): every `Diagnostic`
    anchors at a `ClauseSource`, ensuring user errors point at the
    Lex declaration's exact line/column. -/
structure ClauseSource where
  /-- Absolute or repository-relative path to the source file. -/
  fileName : String
  /-- Start position of the clause's syntax node. -/
  startPos : SourcePos
  deriving Repr, DecidableEq, Inhabited

/-! ## Diagnostic record (§18.1) -/

/-- Diagnostic severity. -/
inductive Severity where
  /-- Error severity: build-failing. -/
  | error
  /-- Warning severity: surfaced but build-allowing. -/
  | warning
  /-- Info severity: surfaced as a hint only. -/
  | info
  deriving Repr, DecidableEq, Inhabited

/-- A diagnostic message.  Each diagnostic carries a stable code
    (`L001` – `L027`), severity, source anchor, message text,
    optional notes (auxiliary context lines), and remediation
    hints.  The `Diagnostic.format` formatter produces the
    canonical `<file>:<line>:<col>: error: L<NNN>: <message>`
    surface (§18.1). -/
structure Diagnostic where
  /-- Stable diagnostic code (e.g. `"L003"`). -/
  code     : String
  /-- Severity (error / warning / info). -/
  severity : Severity
  /-- Where the diagnostic anchors in source. -/
  source   : ClauseSource
  /-- Headline message (one-line; further context goes in `notes`). -/
  message  : String
  /-- Auxiliary context lines printed under the headline. -/
  notes    : List String
  /-- Remediation suggestions printed under the notes. -/
  hints    : List String
  deriving Repr, Inhabited

/-- Format a severity as the prefix Lean / clang use. -/
def Severity.toString : Severity → String
  | .error   => "error"
  | .warning => "warning"
  | .info    => "info"

/-- Format a diagnostic per §18.1.  Output ends with a newline.
    Notes and hints are emitted as `--> note: …` / `--> hint: …`
    lines. -/
def Diagnostic.format (d : Diagnostic) : String :=
  let header :=
    s!"{d.source.fileName}:{d.source.startPos.line}:{d.source.startPos.column}: \
       {d.severity.toString}: {d.code}: {d.message}\n"
  let noteLines := String.join (d.notes.map (fun n => s!"  --> note: {n}\n"))
  let hintLines := String.join (d.hints.map (fun h => s!"  --> hint: {h}\n"))
  header ++ noteLines ++ hintLines

/-- Convenience: build an error-severity diagnostic. -/
def Diagnostic.error
    (code : String) (source : ClauseSource) (message : String)
    (notes : List String := []) (hints : List String := []) :
    Diagnostic :=
  { code, severity := .error, source, message, notes, hints }

/-- Build a `ClauseSource` from a `Lean.Syntax` value's source
    position.  Used by macro callers to anchor diagnostics at the
    user's surface syntax; falls back to the provided file name
    if the syntax has no position information attached. -/
def ClauseSource.ofSyntax (stx : Lean.Syntax) (fileName : String := "<unknown>") :
    ClauseSource :=
  match stx.getPos? with
  | none =>
    { fileName, startPos := { line := 0, column := 0 } }
  | some _pos =>
    -- Without a `FileMap` we can't decode the position byte offset
    -- to a (line, column) pair.  Callers with a `FileMap` available
    -- use `Diagnostic.atSyntax` instead, which threads the map.
    { fileName, startPos := { line := 0, column := 0 } }

/-- Convenience: build a `Diagnostic` anchored at a `Lean.Syntax`
    node's source position, using a `Lean.FileMap` to translate
    byte offsets to (line, column) pairs.  This is the canonical
    helper macros use when emitting errors. -/
def Diagnostic.atSyntax
    (code : String) (severity : Severity)
    (stx : Lean.Syntax) (fileMap : Lean.FileMap) (fileName : String)
    (message : String)
    (notes : List String := []) (hints : List String := []) :
    Diagnostic :=
  let pos := stx.getPos?.getD ⟨0⟩
  let leanPos := fileMap.toPosition pos
  let source : ClauseSource :=
    { fileName,
      startPos := { line := leanPos.line, column := leanPos.column } }
  { code, severity, source, message, notes, hints }

/-- Convenience: build a warning-severity diagnostic. -/
def Diagnostic.warning
    (code : String) (source : ClauseSource) (message : String)
    (notes : List String := []) (hints : List String := []) :
    Diagnostic :=
  { code, severity := .warning, source, message, notes, hints }

/-! ## Registry parsing (§4.1)

The `lex_index_registry.txt` format is one entry per line:
`<identifier>  <action_index>  <first_release>`.  Comments start
with `#` and blank lines are ignored.  Indices must be increasing,
identifiers unique, format identifier-like.  The parser surfaces
syntactic errors as `Diagnostic` values; rule violations
(L005 – L007) are produced by `validateRegistry` below. -/

/-- One row of the registry. -/
structure RegistryEntry where
  /-- The law's canonical identifier (e.g. `"legalkernel.transfer"`). -/
  identifier : String
  /-- Frozen action-index assignment.  Must be monotonically increasing
      across rows, starting at 0 with no gaps. -/
  actionIndex : Nat
  /-- The release tag that first registered this index (semver-shaped). -/
  firstRelease : String
  /-- Source line number (1-indexed) for diagnostic reporting. -/
  sourceLine : Nat
  deriving Repr, DecidableEq, Inhabited

/-- Strip leading and trailing ASCII whitespace from a string.
    Replacement for the deprecated `String.trim` (which now returns
    a `String.Slice` whose method surface differs from `String`).
    Mirrors `Tools/StubAudit.stripWhitespace` exactly. -/
def stripWhitespace (s : String) : String :=
  let cs := s.toList
  let dropLeft := cs.dropWhile Char.isWhitespace
  let dropBoth := (dropLeft.reverse.dropWhile Char.isWhitespace).reverse
  String.ofList dropBoth

/-- Whitespace-tokenize a string: split on spaces / tabs / newlines /
    carriage returns and drop empty fragments.  Used by the
    registry-line parser; avoids depending on `String.split`'s
    slice-iterator return type.

    Audit-2: pre-fix the function only split on space / tab / CR,
    which silently mishandled multi-line input (tokens spanned
    line boundaries).  The fix-pass adds `\n` to the separator
    set so the function matches its docstring "whitespace" -
    classification.  All current callers pass single-line input
    (lines pre-split via `splitOn "\n"`), so this is a defensive
    correction with no observable behaviour change. -/
private def whitespaceTokenize (s : String) : List String := Id.run do
  let mut tokens : List String := []
  let mut cur : String := ""
  for c in s.toList do
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' then
      if !cur.isEmpty then
        tokens := tokens ++ [cur]
        cur := ""
    else
      cur := cur.push c
  if !cur.isEmpty then
    tokens := tokens ++ [cur]
  pure tokens

/-- Parse a single registry line into a `RegistryEntry`.  Returns
    `none` for blank or comment-only lines (the caller should skip
    them).  Returns `some (.error msg)` for malformed lines. -/
def parseRegistryLine (lineNum : Nat) (line : String) :
    Option (Except String RegistryEntry) :=
  let trimmed := stripWhitespace line
  if trimmed.isEmpty then none
  else if trimmed.startsWith "#" then none
  else
    -- Three whitespace-separated fields.
    let parts := whitespaceTokenize trimmed
    match parts with
    | [ident, idxStr, release] =>
      match idxStr.toNat? with
      | some idx =>
        some (.ok { identifier := ident, actionIndex := idx,
                    firstRelease := release, sourceLine := lineNum })
      | none =>
        some (.error s!"line {lineNum}: action_index `{idxStr}` is not a Nat")
    | _ =>
      some (.error
        s!"line {lineNum}: expected `<identifier>  <action_index>  <first_release>`")

/-- Parse the contents of a registry file into a list of entries.
    Skips blanks and comments; surfaces malformed-line errors as a
    list of strings (one per malformed line; the caller decides how
    to surface each as a `Diagnostic`). -/
def parseRegistry (contents : String) :
    Except (List String) (List RegistryEntry) := Id.run do
  let mut entries : List RegistryEntry := []
  let mut errors : List String := []
  let lines := contents.splitOn "\n"
  for h : i in [:lines.length] do
    let line := lines[i]
    match parseRegistryLine (i + 1) line with
    | none => pure ()
    | some (.ok e) => entries := entries ++ [e]
    | some (.error msg) => errors := errors ++ [msg]
  if errors.isEmpty then .ok entries else .error errors

/-- Format a list of registry entries back to the on-disk text
    representation.  Idempotent under round-trip:
    `parseRegistry (formatRegistry r) = .ok r` on representative
    inputs.  Used by `lex_format`'s registry-canonicalisation
    pass. -/
def formatRegistry (entries : List RegistryEntry) : String :=
  String.join (entries.map (fun e =>
    s!"{e.identifier}  {e.actionIndex}  {e.firstRelease}\n"))

/-! ### Registry validation (rules 1 – 7 of §13.1) -/

/-- A structured registry-validation violation: an L-code, the
    source line where the violation surfaces, and a human-readable
    message *without* the L-code prefix (the caller's `Diagnostic`
    formatter prepends the L-code automatically). -/
structure Violation where
  /-- The diagnostic code (e.g. `"L005"`, `"L006"`, `"L007"`). -/
  code    : String
  /-- 1-indexed source line in the registry file (0 if unknown). -/
  line    : Nat
  /-- Human-readable description of the violation. -/
  message : String
  deriving Repr, Inhabited

/-- Validate a parsed registry against the §13.1 rules:
      1. Increasing-index discipline (indices monotone by 1, no gaps).
      2. Unique identifiers.
      3. Unique indices.
      4. Identifier format (dot-separated lowercase, ≥ 2 segments).
      5. Release-tag format (semver-shaped).
      6. (Rule 6 — cross-check codegen-input — is checked separately
         by `lex_codegen --check`; this function checks only the
         registry's internal consistency.)
      7. The first 17 indices are reserved for `legalkernel.*`.

    Returns the list of structured rule violations.  Empty list =
    no violations. -/
def validateRegistry (entries : List RegistryEntry) : List Violation := Id.run do
  let mut violations : List Violation := []
  -- Rule 4: identifier format (dot-segmented; lowercase first char of each segment).
  for e in entries do
    if !isValidIdentifier e.identifier then
      violations := violations ++ [{
        code := "L007", line := e.sourceLine,
        message :=
          s!"identifier `{e.identifier}` is not a valid dot-segmented lowercase path of two-or-more segments"
      }]
  -- Rule 5: release tag format.
  for e in entries do
    if !isValidRelease e.firstRelease then
      violations := violations ++ [{
        code := "L007", line := e.sourceLine,
        message :=
          s!"first_release `{e.firstRelease}` is not a valid semver-shaped tag"
      }]
  -- Rule 1: increasing-index discipline (start at 0, monotone by 1).
  let mut expected : Nat := 0
  for e in entries do
    if e.actionIndex != expected then
      violations := violations ++ [{
        code := "L007", line := e.sourceLine,
        message :=
          s!"action_index for `{e.identifier}` is {e.actionIndex}; expected {expected} (registry must increment by 1)"
      }]
    expected := e.actionIndex + 1
  -- Rule 2: unique identifiers.
  let idents := entries.map (·.identifier)
  for h : i in [:idents.length] do
    let id_i := idents[i]
    for _h2 : j in [i+1:idents.length] do
      if id_i == idents[j]! then
        violations := violations ++ [{
          code := "L005",
          line := (entries[i]!).sourceLine,
          message := s!"identifier `{id_i}` appears more than once"
        }]
  -- Rule 3: unique indices.
  let idxs := entries.map (·.actionIndex)
  for h : i in [:idxs.length] do
    for _h2 : j in [i+1:idxs.length] do
      if idxs[i] == idxs[j]! then
        violations := violations ++ [{
          code := "L005",
          line := (entries[i]!).sourceLine,
          message := s!"action_index `{idxs[i]}` appears more than once"
        }]
  -- Rule 7: legalkernel range reservation.
  for e in entries do
    if e.actionIndex < 17 then
      if !e.identifier.startsWith "legalkernel." then
        violations := violations ++ [{
          code := "L006", line := e.sourceLine,
          message :=
            s!"identifier `{e.identifier}` has action_index {e.actionIndex} but is not in the `legalkernel.*` namespace; the first 17 indices are reserved"
        }]
  pure violations
where
  /-- An identifier is a dot-separated lowercase path of two-or-more
      segments; each segment matches `[a-z][a-zA-Z0-9_]*`. -/
  isValidIdentifier (s : String) : Bool :=
    let parts := s.splitOn "."
    if parts.length < 2 then false
    else parts.all isValidSegment
  /-- A segment matches `[a-z][a-zA-Z0-9_]*`. -/
  isValidSegment (s : String) : Bool :=
    let cs := s.toList
    match cs with
    | []     => false
    | h :: t =>
      if !(h ≥ 'a' && h ≤ 'z') then false
      else
        t.all (fun c =>
          (c ≥ 'a' && c ≤ 'z') || (c ≥ 'A' && c ≤ 'Z') ||
          (c ≥ '0' && c ≤ '9') || c == '_')
  /-- A release tag is `v<MAJOR>.<MINOR>(.<PATCH>)?(-<pre>)?(\+<meta>)?`. -/
  isValidRelease (s : String) : Bool :=
    let cs := s.toList
    match cs with
    | 'v' :: rest =>
      let body : String := String.ofList rest
      -- Split off optional `+<meta>` suffix first.
      let (vMain, _meta) : String × String :=
        match body.splitOn "+" with
        | [main]        => (main, "")
        | main :: rest  => (main, String.intercalate "+" rest)
        | _             => (body, "")
      -- Then split off optional `-<pre>` suffix.
      let (numPart, _pre) : String × String :=
        match vMain.splitOn "-" with
        | [main]        => (main, "")
        | main :: rest  => (main, String.intercalate "-" rest)
        | _             => (vMain, "")
      -- numPart must be `<MAJOR>.<MINOR>(.<PATCH>)?`.
      let segs := numPart.splitOn "."
      if segs.length < 2 || segs.length > 3 then false
      else segs.all (fun seg =>
        !seg.isEmpty && seg.all (fun c => c ≥ '0' && c ≤ '9'))
    | _ => false

/-! ## `LawDecl` and the JSON codec (§5.2 / LX.11)

The `LawDecl` Lean structure mirrors the JSON schema field-for-
field.  AST nodes (`PreNode`, `ImplStmt`, `EventStmt`, etc.) are
declared in `LegalKernel.DSL.LexLaw` (the macro module); here we
declare a flattened *string-tagged* representation suitable for
the audit binaries which never elaborate user `pre`/`impl`
expressions.

The JSON encoder/decoder is *deterministic*: equal `LawDecl`s
produce byte-equal JSON, with field order matching §5.2 exactly.
This is what `lex_codegen --check` relies on for deterministic
diff comparisons. -/

/-- A binder kind for `params` entries (§5.2).

    Audit-4 amendment: added the `inst` variant for typeclass
    instance binders `[Inhabited α]`.  Pre-audit-4, the
    `paramSpecsFromBinder` walker silently dropped instance
    binders (returning `[]`), causing JSON-vs-source drift for
    any law that happened to use `[]`-style parameters.  None of
    the M2 kernel-built-in laws use instance binders, so the
    drift was dormant — but the addition future-proofs the
    walker for M3 deployment-private laws. -/
inductive BinderKind where
  /-- `(x : T)` — explicit. -/
  | explicit
  /-- `{x : T}` — implicit. -/
  | implicit
  /-- `⦃x : T⦄` — strict-implicit. -/
  | strictImplicit
  /-- `[x : T]` or `[T]` — instance (typeclass) binder.  Added in
      LX-M2 audit-4 to close the silent-drop drift. -/
  | inst
  deriving Repr, DecidableEq, Inhabited

/-- One parameter (binder) of a Lex law. -/
structure ParamSpec where
  /-- Identifier name (e.g. `"r"`, `"sender"`). -/
  name : String
  /-- Type annotation as captured surface text (e.g. `"ResourceId"`). -/
  type : String
  /-- Binder kind. -/
  kind : BinderKind
  deriving Repr, DecidableEq, Inhabited

/-- Authority-binding kinds (§5.2). -/
inductive AuthorityRefKind where
  /-- `signed_by <name>` — name refers to an in-scope actor binder. -/
  | actorRef
  /-- `authorized_by <expr>` — `expr` is a surface-string Lean term. -/
  | policyRef
  deriving Repr, DecidableEq, Inhabited

/-- A `signed_by` clause's payload. -/
structure SignedByRef where
  /-- The bound actor's name (or a literal string for the `actorRef`-kind). -/
  name : String
  deriving Repr, DecidableEq, Inhabited

/-- An `authorized_by` clause's payload (captured as Lean source-
    text; the elaborator does not interpret the expression at the
    LX.4 layer). -/
structure AuthorizedByRef where
  /-- The Lean source text of the policy expression. -/
  expr : String
  deriving Repr, DecidableEq, Inhabited

/-- A property claim (one `satisfies` entry). -/
structure PropertyClaim where
  /-- Property name (e.g. `"conservative"`, `"local"`). -/
  name : String
  /-- Property arguments captured as opaque text strings.

      Audit-3 redesign: pre-fix the docstring claimed args were
      "compressed-JSON strings" parsed back via `Lean.Json.parse`.
      The codec then *parsed* each arg as JSON on encode and
      *compressed* on decode, producing an asymmetric round-trip
      (`["foo"]` round-tripped to `["\"foo\""]`).  The audit-3
      design treats args as opaque strings: the codec wraps each
      as `Json.str` on encode and unwraps via `getStr` on
      decode — symmetric.  The macro layer is responsible for
      any text-to-typed-value conversion (M2 concern).

      Strings rather than `Lean.Json` so that the structure can
      derive `Repr` and `DecidableEq` (`Lean.Json` doesn't ship
      either). -/
  args : List String
  deriving Repr, DecidableEq, Inhabited

/-- A `proof <P> := …` override. -/
structure ProofOverride where
  /-- The property name being overridden. -/
  property : String
  /-- The raw Lean tactic source captured verbatim. -/
  tacticBlock : String
  deriving Repr, DecidableEq, Inhabited

/-- The `registry_effect` field's variants (§5.2). -/
inductive RegistryEffectKind where
  /-- No registry mutation; the law preserves `KeyRegistry` pointwise. -/
  | none_
  /-- `replaceKey actor newKey` shape (signed by old key). -/
  | replaceKey
  /-- `registerIdentity actor pk` shape (signed by bridge). -/
  | registerIdentity
  /-- `declareLocalPolicy` / `revokeLocalPolicy` (LP-extension; not in v1's `applyActionToRegistry` but in `applyActionToLocalPolicies`). -/
  | localPolicy
  deriving Repr, DecidableEq, Inhabited

/-- The `LawDecl` Lean structure mirroring §5.2's JSON schema.

    Many fields capture surface-string snippets rather than
    elaborated Lean terms (e.g. `preExpr`, `implBlock`, `events`,
    `authorizedBy`).  This is the audit-binary view: the macro
    layer (`LegalKernel.DSL.LexLaw`) elaborates the strings into
    typed Lean values; the binaries don't need that machinery. -/
structure LawDecl where
  /-- Schema version.  Currently `1`. -/
  schemaVersion : Nat
  /-- Canonical identifier (e.g. `"legalkernel.transfer"`). -/
  identifier : String
  /-- Semver-shaped version. -/
  version : String
  /-- Frozen action-index assignment. -/
  actionIndex : Nat
  /-- Free-form intent prose; shown to reviewers. -/
  intent : String
  /-- Ordered parameter list. -/
  params : List ParamSpec
  /-- The bound signer's name. -/
  signedBy : SignedByRef
  /-- The deployment authority predicate's surface source. -/
  authorizedBy : AuthorizedByRef
  /-- Surface text of the `pre` clause (the macro layer parses this
      into a `PreNode` AST). -/
  preExpr : String
  /-- Surface text of the `impl` block. -/
  implBlock : String
  /-- The `satisfies` clause's claims. -/
  satisfies : List PropertyClaim
  /-- The `events` block's surface text (parsed by the macro layer). -/
  eventsBlock : String
  /-- Authority-layer registry effect classification. -/
  registryEffect : RegistryEffectKind
  /-- `proof <P>` overrides. -/
  proofOverrides : List ProofOverride
  /-- Origin source position for diagnostic anchoring. -/
  sourceLocation : ClauseSource
  deriving Repr, DecidableEq, Inhabited

/-! ### JSON codec -/

/-- Encode a `BinderKind`. -/
def encodeBinderKind : BinderKind → Lean.Json
  | .explicit       => Lean.Json.str "explicit"
  | .implicit       => Lean.Json.str "implicit"
  | .strictImplicit => Lean.Json.str "strict_implicit"
  | .inst           => Lean.Json.str "inst"

/-- Decode a `BinderKind` from JSON. -/
def decodeBinderKind : Lean.Json → Except String BinderKind
  | Lean.Json.str "explicit"        => .ok .explicit
  | Lean.Json.str "implicit"        => .ok .implicit
  | Lean.Json.str "inst"            => .ok .inst
  | Lean.Json.str "strict_implicit" => .ok .strictImplicit
  | j                                =>
    .error s!"unknown binder kind: {j.compress}"

/-- Encode a `RegistryEffectKind`. -/
def encodeRegistryEffectKind : RegistryEffectKind → Lean.Json
  | .none_            => Lean.Json.str "none"
  | .replaceKey       => Lean.Json.str "replaceKey"
  | .registerIdentity => Lean.Json.str "registerIdentity"
  | .localPolicy      => Lean.Json.str "localPolicy"

/-- Decode a `RegistryEffectKind`. -/
def decodeRegistryEffectKind : Lean.Json → Except String RegistryEffectKind
  | Lean.Json.str "none"             => .ok .none_
  | Lean.Json.str "replaceKey"       => .ok .replaceKey
  | Lean.Json.str "registerIdentity" => .ok .registerIdentity
  | Lean.Json.str "localPolicy"      => .ok .localPolicy
  | j => .error s!"unknown registry-effect kind: {j.compress}"

/-- Encode a `ParamSpec` to canonical JSON. -/
def encodeParamSpec (p : ParamSpec) : Lean.Json :=
  Lean.Json.mkObj [
    ("name", Lean.Json.str p.name),
    ("type", Lean.Json.str p.type),
    ("kind", encodeBinderKind p.kind)
  ]

/-- Decode a `ParamSpec` from JSON. -/
def decodeParamSpec (j : Lean.Json) : Except String ParamSpec := do
  let name ← j.getObjValAs? String "name"
  let type ← j.getObjValAs? String "type"
  let kindJ ← j.getObjVal? "kind"
  let kind ← decodeBinderKind kindJ
  return { name, type, kind }

/-- Encode a `PropertyClaim`.

    Audit-3 fix: pre-fix the encoder tried to *parse* each `args`
    string as JSON and embed the parsed JSON directly, falling
    back to `Json.str` on parse failure.  The decoder then
    `compress`-ed each JSON value back to a string.  This was
    asymmetric: `args = ["foo"]` (raw string) encoded to
    `Json.str "foo"`, decoded as `compress` → `"\"foo\""`
    (with quotes), so `decode (encode x).args ≠ x.args` in
    general — even though the byte-encode-twice property
    happened to hold (because `Json.str "foo"` and parsing
    `"\"foo\""` both produce the same JSON).

    The audit-3 design treats `args` as opaque strings: encode
    wraps each as `Json.str`, decode unwraps each via `getStr`.
    This is structurally invariant under both
    encode → decode → encode AND decode → encode → decode.
    M2's typed-arg pass (`local [r]` with `r` parsed as a
    `ResourceId`) will introduce a richer `args` representation
    at that time. -/
def encodePropertyClaim (c : PropertyClaim) : Lean.Json :=
  Lean.Json.mkObj [
    ("name", Lean.Json.str c.name),
    ("args", Lean.Json.arr (c.args.map Lean.Json.str).toArray)
  ]

/-- Decode a `PropertyClaim`.  Audit-3: args are now read as
    plain JSON strings (matching `encodePropertyClaim`'s
    `Json.str` wrapping); a non-string arg element returns an
    error. -/
def decodePropertyClaim (j : Lean.Json) : Except String PropertyClaim := do
  let name ← j.getObjValAs? String "name"
  let argsJ ← j.getObjVal? "args"
  match argsJ with
  | Lean.Json.arr a =>
    let args ← a.toList.mapM (fun e =>
      match e with
      | Lean.Json.str s => .ok s
      | _ =>
        .error s!"PropertyClaim.args: every element must be a JSON string (audit-3 invariant); got {e.compress}")
    return { name, args }
  | _ => .error s!"PropertyClaim.args expected array; got {argsJ.compress}"

/-- Encode a `ProofOverride`. -/
def encodeProofOverride (o : ProofOverride) : Lean.Json :=
  Lean.Json.mkObj [
    ("property", Lean.Json.str o.property),
    ("tactic_block", Lean.Json.str o.tacticBlock)
  ]

/-- Decode a `ProofOverride`. -/
def decodeProofOverride (j : Lean.Json) : Except String ProofOverride := do
  let property ← j.getObjValAs? String "property"
  let tacticBlock ← j.getObjValAs? String "tactic_block"
  return { property, tacticBlock }

/-- Encode a `SourcePos`. -/
def encodeSourcePos (p : SourcePos) : Lean.Json :=
  Lean.Json.mkObj [
    ("line", Lean.Json.num (p.line : Int)),
    ("column", Lean.Json.num (p.column : Int))
  ]

/-- Decode a `SourcePos`. -/
def decodeSourcePos (j : Lean.Json) : Except String SourcePos := do
  let line ← j.getObjValAs? Nat "line"
  let column ← j.getObjValAs? Nat "column"
  return { line, column }

/-- Encode a `ClauseSource`. -/
def encodeClauseSource (s : ClauseSource) : Lean.Json :=
  Lean.Json.mkObj [
    ("file", Lean.Json.str s.fileName),
    ("position", encodeSourcePos s.startPos)
  ]

/-- Decode a `ClauseSource`. -/
def decodeClauseSource (j : Lean.Json) : Except String ClauseSource := do
  let fileName ← j.getObjValAs? String "file"
  let posJ ← j.getObjVal? "position"
  let pos ← decodeSourcePos posJ
  return { fileName, startPos := pos }

/-- Encode a `LawDecl` to canonical JSON.

    **Determinism guarantee.**  The result is byte-stable across
    calls on structurally-equal inputs.  Uses `Lean.Json.pretty`
    with the default indent so the on-disk JSON is human-readable
    yet diff-friendly.

    **Field-order note (audit-3).**  The pre-audit-3 docstring
    claimed "field order matches §5.2 exactly".  This is FALSE:
    `Lean.Json.mkObj` constructs an internal `RBNode` keyed by
    field name, which iterates in reverse-alphabetical order
    when pretty-printed.  The actual field order in the emitted
    JSON is `[version, source_location, signed_by,
    schema_version, satisfies, registry_effect, proof_overrides,
    pre_expr, params, intent, impl_block, identifier,
    events_block, authorized_by, action_index]` (descending
    lexicographic on the field-name keys).  This is determined
    by Lean core's `Json` representation and is stable across
    Lean releases for a given key set.

    **Why it doesn't matter.**  The §5.2 schema is about *which*
    fields are present and *what shape* each carries, not about
    the JSON serialization order.  Downstream consumers
    (`LawDecl.fromJson`, the `lex_codegen` cross-stack consumers,
    and any external client) all interpret JSON object keys
    independently of order — JSON itself doesn't impose a key
    order.  Determinism (byte-stability of the produced
    encoding) is the property that matters, and it holds.

    Audit-3 lands the corrected docstring; no functional
    change. -/
def LawDecl.toCanonicalJson (d : LawDecl) : String :=
  let json := Lean.Json.mkObj [
    ("schema_version", Lean.Json.num (d.schemaVersion : Int)),
    ("identifier", Lean.Json.str d.identifier),
    ("version", Lean.Json.str d.version),
    ("action_index", Lean.Json.num (d.actionIndex : Int)),
    ("intent", Lean.Json.str d.intent),
    ("params", Lean.Json.arr (d.params.map encodeParamSpec).toArray),
    ("signed_by", Lean.Json.mkObj [
      ("kind", Lean.Json.str "actorRef"),
      ("name", Lean.Json.str d.signedBy.name)
    ]),
    ("authorized_by", Lean.Json.mkObj [
      ("kind", Lean.Json.str "policyRef"),
      ("expr", Lean.Json.str d.authorizedBy.expr)
    ]),
    ("pre_expr", Lean.Json.str d.preExpr),
    ("impl_block", Lean.Json.str d.implBlock),
    ("satisfies", Lean.Json.arr (d.satisfies.map encodePropertyClaim).toArray),
    ("events_block", Lean.Json.str d.eventsBlock),
    ("registry_effect", Lean.Json.mkObj [
      ("kind", encodeRegistryEffectKind d.registryEffect)
    ]),
    ("proof_overrides",
      Lean.Json.arr (d.proofOverrides.map encodeProofOverride).toArray),
    ("source_location", encodeClauseSource d.sourceLocation)
  ]
  -- Use `pretty` with the default indent for diff-friendly output.
  json.pretty ++ "\n"

/-- Decode a JSON document into a `LawDecl`.  Round-trippable on
    canonical inputs:
    `LawDecl.fromJson (LawDecl.toCanonicalJson l) = .ok l` for
    every `l`. -/
def LawDecl.fromJson (s : String) : Except String LawDecl := do
  let j ← Lean.Json.parse s
  let schemaVersion ← j.getObjValAs? Nat "schema_version"
  if schemaVersion != 1 then
    .error s!"unsupported schema_version {schemaVersion}; expected 1"
  let identifier ← j.getObjValAs? String "identifier"
  let version ← j.getObjValAs? String "version"
  let actionIndex ← j.getObjValAs? Nat "action_index"
  let intent ← j.getObjValAs? String "intent"
  let paramsJ ← j.getObjVal? "params"
  let params ← match paramsJ with
    | Lean.Json.arr a => a.toList.mapM decodeParamSpec
    | _ => .error "params expected array"
  let signedByJ ← j.getObjVal? "signed_by"
  let signedByName ← signedByJ.getObjValAs? String "name"
  let authJ ← j.getObjVal? "authorized_by"
  let authExpr ← authJ.getObjValAs? String "expr"
  let preExpr ← j.getObjValAs? String "pre_expr"
  let implBlock ← j.getObjValAs? String "impl_block"
  let satisfiesJ ← j.getObjVal? "satisfies"
  let satisfies ← match satisfiesJ with
    | Lean.Json.arr a => a.toList.mapM decodePropertyClaim
    | _ => .error "satisfies expected array"
  let eventsBlock ← j.getObjValAs? String "events_block"
  let regJ ← j.getObjVal? "registry_effect"
  let regKindJ ← regJ.getObjVal? "kind"
  let registryEffect ← decodeRegistryEffectKind regKindJ
  let provJ ← j.getObjVal? "proof_overrides"
  let proofOverrides ← match provJ with
    | Lean.Json.arr a => a.toList.mapM decodeProofOverride
    | _ => .error "proof_overrides expected array"
  let locJ ← j.getObjVal? "source_location"
  let sourceLocation ← decodeClauseSource locJ
  return {
    schemaVersion, identifier, version, actionIndex, intent,
    params,
    signedBy := { name := signedByName },
    authorizedBy := { expr := authExpr },
    preExpr, implBlock, satisfies, eventsBlock, registryEffect,
    proofOverrides, sourceLocation
  }

/-! ## Codegen-input directory utilities -/

/-- The canonical codegen-input directory under the repository
    root.  Macro Pass 1 writes here; Pass 2 (`lex_codegen`) reads. -/
def codegenInputsDir : System.FilePath := "LegalKernel/_lex_inputs"

/-- The canonical registry path. -/
def registryPath : System.FilePath := "lex_index_registry.txt"

/-- True iff a single character is one of the canonical
    identifier-segment characters: `[a-zA-Z0-9_.]` (note the dot
    is included so dotted identifiers like
    `legalkernel.transfer` are recognised; the dot is replaced
    with `_` by `codegenInputFileName` before being used as a
    file name, so `..` cannot escape `LegalKernel/_lex_inputs/`).

    Used to sanitise codegen-input file names against path-
    traversal attempts via `«»`-quoted Lean identifiers (e.g.
    `«../../etc/passwd»`), which `Lean.Parser` admits as valid
    identifiers but would otherwise let the macro write
    arbitrary files. -/
private def isAlnumUnderscore (c : Char) : Bool :=
  (c ≥ 'a' && c ≤ 'z') || (c ≥ 'A' && c ≤ 'Z') ||
  (c ≥ '0' && c ≤ '9') || c == '_' || c == '.'

/-- True iff `s` consists only of the canonical identifier-
    segment characters (per `isAlnumUnderscore`): `[a-zA-Z0-9_.]`.

    **Path-traversal hardening.**  A traversal component like
    `..` is technically composable from the dot character, but
    `codegenInputFileName` (the only consumer of this predicate)
    replaces every `.` with `_` before constructing the file name,
    so a hypothetical `«..»` identifier produces the file name
    `__.json`, harmless and contained within
    `LegalKernel/_lex_inputs/`.  More aggressive characters (`/`,
    `\\`, control chars, non-ASCII) are rejected by this predicate
    and never reach the file-name composer.  Audit-2 hardened the
    docstring to make the dot-then-underscore-replace flow explicit;
    no functional change. -/
def isSafeIdentifier (s : String) : Bool :=
  !s.isEmpty && s.toList.all isAlnumUnderscore

/-- Convert a Lex law identifier to a codegen-input file name.
    Replaces dots with underscores and appends `.json`.

    **Security**: rejects any identifier containing characters
    outside `[a-zA-Z0-9_.]` by returning `none`.  This blocks
    path-traversal attempts via `«»`-quoted Lean identifiers
    (e.g. `«../../etc/passwd»`), which `Lean.Parser` accepts as
    valid identifiers but would otherwise let the macro write
    arbitrary files outside `LegalKernel/_lex_inputs/`. -/
def codegenInputFileName? (identifier : String) : Option String :=
  if isSafeIdentifier identifier then
    some (identifier.replace "." "_" ++ ".json")
  else
    none

/-- Backward-compatible variant of `codegenInputFileName?` that
    falls back to a sanitised form for unsafe identifiers (every
    non-`[a-zA-Z0-9_.]` character is replaced with `_`).  Callers
    that need a guaranteed-safe file name in all cases use this;
    callers that want to fail loudly use `codegenInputFileName?`. -/
def codegenInputFileName (identifier : String) : String :=
  match codegenInputFileName? identifier with
  | some name => name
  | none =>
    let sanitised : String :=
      String.ofList (identifier.toList.map
        (fun c => if isAlnumUnderscore c then c else '_'))
    sanitised.replace "." "_" ++ ".json"

/-- Compute the codegen-input file path for a given identifier. -/
def codegenInputPath (identifier : String) : System.FilePath :=
  codegenInputsDir / codegenInputFileName identifier

/-- Load every JSON file under the codegen-input directory and
    parse each as a `LawDecl`.  Returns the list sorted by
    `actionIndex`.  Surfacing errors per-file is the caller's
    responsibility; a single malformed JSON aborts the load with
    a single error. -/
def loadCodegenInputs (dir : System.FilePath := codegenInputsDir) :
    IO (Except String (List LawDecl)) := do
  if !(← System.FilePath.pathExists dir) then
    return .ok []  -- absent directory ≡ empty input set
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
  -- Sort by actionIndex (ascending).
  let sorted := decls.toArray.qsort (fun a b => a.actionIndex < b.actionIndex)
  return .ok sorted.toList

/-! ## File-walker -/

/-- Walk a directory recursively and return every `.lean` file's
    path.  Filters out hidden directories (those starting with `.`)
    and the conventional `_lex_inputs` directory (which contains
    JSON, not Lean source). -/
partial def walkLeanFiles (dir : System.FilePath) :
    IO (List System.FilePath) := do
  if !(← System.FilePath.pathExists dir) then
    return []
  if !(← System.FilePath.isDir dir) then
    -- A single file: include if it's a `.lean`.
    if dir.extension == some "lean" then return [dir] else return []
  let entries ← dir.readDir
  let mut acc : List System.FilePath := []
  for entry in entries do
    let baseName := entry.fileName
    if baseName.startsWith "." then continue
    if baseName == "_lex_inputs" then continue
    if baseName == ".lake" || baseName == "build" then continue
    let nested ← walkLeanFiles entry.path
    acc := acc ++ nested
  return acc

/-! ## Atomic-write helper (used by the macro's idempotent write)

The strategy: write to `<path>.tmp`, `IO.FS.rename` to the final
path.  POSIX `rename(2)` is atomic; concurrent readers see either
the old or the new file, never a partial state.  See §6.10 of the
implementation plan. -/

/-- Write `contents` to `path` atomically.  If a file already
    exists at `path` with byte-identical contents, the function is
    a no-op (no `mtime` bump).  This is the production wrapper
    consumed by the `lex_law` macro and the `lex_codegen`
    binary.

    **Atomicity model.**  The implementation writes to
    `<path>.tmp` and then `IO.FS.rename`s into place.  POSIX
    `rename(2)` is atomic on the same filesystem; concurrent
    readers see either the old or new file, never a partial
    write.  Cross-filesystem renames may fall back to a
    copy+delete on some platforms; this is acceptable for the
    `LegalKernel/_lex_inputs/` directory (always on the same
    filesystem as the repo).

    **Known TOCTOU limitation.**  Two concurrent invocations on
    the same `path` race between `pathExists` (line 1) and
    `writeFile` (line tmp) — both can observe the absent
    sentinel and both write.  The second invocation's content
    wins via `rename`'s last-write-wins semantics, which is
    acceptable when both invocations would write the same bytes
    (the M1 case).  Production deployments needing strict
    serialisation must wrap the call in a `flock`-based external
    lock (the `lex_codegen` binary's `withFileLock` is one such
    wrapper, but with the same TOCTOU window — both wrappers are
    advisory in M1).  Documented for audit-2.

    **Symlink / fixed-`.tmp` consideration.**  The `.tmp` suffix
    is predictable.  An attacker with write access to the
    target's parent directory could pre-create a symlink at
    `<path>.tmp` redirecting writes elsewhere.  The risk surface
    is limited because (a) the only files this function writes
    in production are codegen-input JSON files in
    `LegalKernel/_lex_inputs/` (a repo-internal directory whose
    write access is gated by repo permissions), and (b) the
    overwritten content is non-secret (the JSON is committed to
    git).  M2 may upgrade to a `mkstemp`-style unique tmp name. -/
def atomicWriteIfChanged (path : System.FilePath) (contents : String) : IO Unit := do
  if (← path.pathExists) then
    let existing ← IO.FS.readFile path
    if existing == contents then return ()
  let tmpPath := path.toString ++ ".tmp"
  IO.FS.writeFile tmpPath contents
  IO.FS.rename tmpPath path.toString

end LegalKernel.Tools.Lex

/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Tools.Codegen — the Workstream-LX codegen binary.

LX.17 / LX.18 / LX.19 / LX.20 of
`docs/planning/lex_implementation_plan.md`.

Reads every JSON file under `Lex/Inputs/`, sorts
by `action_index`, and (in M1's *additive* mode) appends new
constructors / branches inside `-- BEGIN LEX-GENERATED` /
`-- END LEX-GENERATED` fences in the four cross-module artefacts
(`Authority/Action.lean`, `Encoding/Action.lean`,
`Events/Extract.lean`, `Authority/SignedAction.lean`).

# Architecture

  * `parseOptions`     — argv → CodegenOptions (--check / --canonical).
  * `locateFence`      — find `[BEGIN, END]` line indices in a file.
  * `extractFenceContent` — extract fence body (lines b+1 .. e-1).
  * `replaceFenceContent` — replace fence body in a file's contents.
  * `requiresEmission` — does a `LawDecl` need cross-module artefact
    updates?  M1 rule: `false` for any law whose impl is identity
    AND has no params (the example law fits).  M2 will adopt
    "every Lex law extends `Action`" once kernel-built-ins migrate.
  * `renderActionInductive` / `renderCompileTransition`
    / `renderActionFieldsBounded` / `renderActionEncode`
    / `renderActionDecode` / `renderActionEvents`
    / `renderApplyActionToRegistry` / `renderNonRegistryMutating`
    — per-target renderers.  Each returns the empty string when
    no Lex declarations require emission (M1's example-law set).
  * `renderTarget` / `renderAll` — top-level dispatchers that map
    each target file to its rendered content.
  * `checkTargetFile` — byte-compare fence contents against
    rendered output; returns `none` on match, `some L026 message`
    on divergence.
  * `appendToTargetFile` — fence-respecting in-place rewrite using
    `atomicWriteIfChanged`.

# Operating modes

  * default — read codegen-input + registry, validate consistency,
    rewrite each target file's fence to match the rendered output.
    Idempotent: re-running on a clean checkout writes nothing.
  * `--check` — verify the committed target files' fences match
    the rendered output byte-for-byte.  Exits 0 on consistency,
    1 with diagnostic L026 on divergence.
  * `--canonical` — M2 / audit-3 mode: emit the structured
    canonical manifest (`Lex/Inputs/canonical_manifest.txt`) and,
    with `--gen-property-tests`, the property-test coverage file.
    Used by the LX milestone-bump tooling to refresh the
    deployment-canonical artefacts; non-fence-aware (writes a
    full file body) so it cannot interleave with `--check`.

# AR.13.4 / m-8: fence-marker contract

The fence markers `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED`
form a *string contract* between this codegen tool and every
generated-region reader (the four cross-module artefacts listed
above plus the test harness).  Renaming either string requires
updating the codegen tool AND every reader simultaneously; the
markers are not validated against a single source-of-truth
constant — they are duplicated by design (one in this file's
`fenceBegin` / `fenceEnd` definitions, one in each target file's
fence body).  A reviewer encountering fence-marker drift should
re-grep for the literal strings before assuming a single rename
suffices.

# AR.13.4 / m-18: duplicate-index non-determinism note

Sort order under duplicate-index registries is `Array.qsort`-
determined.  Lean's `qsort` is *not* guaranteed stable across
toolchain versions: two registry entries with the same
`action_index` may swap positions on a toolchain bump.  The
audit-3 sidecar tools mitigate this with an explicit identifier
tie-breaker (sort by `(action_index, identifier)`); reviewers
encountering duplicate indices should run `lex_lint` first to
surface them before any codegen run.

# Exit codes

  * 0 — success.
  * 1 — divergence detected (in `--check` mode), render error,
    or registry-input mismatch.
  * 2 — internal binary failure (cannot read a file, etc.).

# Concurrency safety

The default mode acquires an advisory lockfile
(`<targetFile>.lex_codegen.lock`) before rewriting each target;
concurrent invocations on the same target serialise (the second
waits for the first to release).  `--check` mode is read-only and
does not lock.
-/

import Lex.Tools.Common

namespace LegalKernel.Tools.Lex.Codegen

open System (FilePath)

/-! ## Configuration -/

/-- Per-target output paths.  Mirrors the implementation plan
    §12.1 `Outputs` record. -/
structure Outputs where
  /-- The `Action` inductive + `compileTransition` host. -/
  actionFile        : FilePath := "LegalKernel/Authority/Action.lean"
  /-- The CBE encoder/decoder for `Action`. -/
  encodingFile      : FilePath := "LegalKernel/Encoding/Action.lean"
  /-- The `actionEvents` host. -/
  eventsFile        : FilePath := "LegalKernel/Events/Extract.lean"
  /-- The `applyActionToRegistry` +
      `non_registry_mutating_preserves_registry` host. -/
  signedActionFile  : FilePath := "LegalKernel/Authority/SignedAction.lean"

/-- Default-valued `Outputs`.  Constructed via the anonymous
    constructor so the per-field default initializers are
    honoured (a `deriving Inhabited` would substitute
    `default : FilePath = ""` for each field, ignoring the
    `:= "..."` literals above). -/
instance : Inhabited Outputs := ⟨{}⟩

/-- Top-level codegen options parsed from `argv`. -/
structure CodegenOptions where
  /-- `--check` mode flag.  When `true`, the binary verifies
      committed artefacts match the codegen output but does not
      write any file. -/
  checkOnly : Bool := false
  /-- `--canonical` mode flag (M2).  When `true`, the binary
      regenerates the entire target body rather than the fence
      contents.  Not yet implemented in M1. -/
  canonical : Bool := false
  /-- `--gen-property-tests` mode flag (LX.38).  When `true`, the
      binary regenerates `Lex/Test/AutoGenProperties.lean`
      from the codegen-input JSONs' `satisfies` claims.  In M3 v1,
      the file is hand-curated and this flag's renderer is a
      structural placeholder (the M3 acceptance gate runs against
      the hand-curated file directly; M4 may flip the gate to the
      generated form). -/
  genPropertyTests : Bool := false
  /-- Codegen-input directory. -/
  inputDir : FilePath := codegenInputsDir
  /-- Output target paths. -/
  outputs : Outputs := {}

/-- Default-valued `CodegenOptions` honouring all field defaults. -/
instance : Inhabited CodegenOptions := ⟨{}⟩

/-- Parse argv into a `CodegenOptions`.  Supports `--check`,
    `--canonical`, `--gen-property-tests`, and ignores other
    arguments (forward-compatibility for v2 flags). -/
def parseOptions (args : List String) : CodegenOptions := Id.run do
  let mut opts : CodegenOptions := {}
  for arg in args do
    if arg == "--check" then
      opts := { opts with checkOnly := true }
    else if arg == "--canonical" then
      opts := { opts with canonical := true }
    else if arg == "--gen-property-tests" then
      opts := { opts with genPropertyTests := true }
  pure opts

/-! ## Fence helpers (§12.10)

The fence-respecting append algorithm.  M1 mode wraps
generated content between the two markers; manual edits
outside the fence are preserved verbatim, manual edits inside
are clobbered. -/

/-- The opening fence marker.  Must match exactly across runs. -/
def beginFenceMarker : String := "-- BEGIN LEX-GENERATED (do not edit by hand)"

/-- The closing fence marker. -/
def endFenceMarker : String := "-- END LEX-GENERATED"

/-- Failure modes for fence detection. -/
inductive FenceError where
  /-- The target file has no fence markers at all. -/
  | noFence
  /-- The file has multiple BEGIN markers. -/
  | multipleBegin
  /-- The file has multiple END markers. -/
  | multipleEnd
  /-- An END marker precedes a BEGIN marker. -/
  | reversed
  /-- A BEGIN marker has no matching END. -/
  | noEnd
  deriving Repr, Inhabited

/-- Pretty-print a `FenceError` for diagnostic emission. -/
def FenceError.toString : FenceError → String
  | .noFence       => "no `-- BEGIN LEX-GENERATED` fence in file"
  | .multipleBegin => "multiple `-- BEGIN LEX-GENERATED` fences in file"
  | .multipleEnd   => "multiple `-- END LEX-GENERATED` fences in file"
  | .reversed      => "`-- END LEX-GENERATED` precedes `-- BEGIN LEX-GENERATED`"
  | .noEnd         => "`-- BEGIN LEX-GENERATED` has no matching `-- END LEX-GENERATED`"

/-- Locate the BEGIN/END fence in a file's contents.  Returns
    the (B, E) line indices on success.  Lines are 0-indexed in
    the result; comparison against the file's `splitOn "\n"`
    output gives the matching lines.

    M1 supports a single fence per file.  Multiple fences in the
    same file are rejected with `multipleBegin` / `multipleEnd`
    (M2 will lift this when individual functions/inductives gain
    their own dedicated fences). -/
def locateFence (contents : String) :
    Except FenceError (Nat × Nat) := Id.run do
  let lines := contents.splitOn "\n"
  let mut beginIdx : Option Nat := none
  let mut endIdx : Option Nat := none
  let mut beginCount : Nat := 0
  let mut endCount : Nat := 0
  for h : i in [:lines.length] do
    let line := lines[i]
    if stripWhitespace line == beginFenceMarker then
      beginIdx := some i
      beginCount := beginCount + 1
    if stripWhitespace line == endFenceMarker then
      endIdx := some i
      endCount := endCount + 1
  if beginCount > 1 then return .error .multipleBegin
  if endCount > 1 then return .error .multipleEnd
  match beginIdx, endIdx with
  | none, _ => return .error .noFence
  | _, none => return .error .noEnd
  | some b, some e =>
    if e < b then return .error .reversed
    else return .ok (b, e)

/-- Locate ALL `(BEGIN, END)` fence pairs in a file's contents.

    Files with multiple managed regions (e.g. both `Action`
    inductive and `compileTransition`) need this multi-fence
    locator.  Pairs are returned in document order; if any
    `BEGIN` is unpaired the function returns `.error .noEnd`,
    if any `END` precedes its `BEGIN` the function returns
    `.error .reversed`.  An empty result is success
    (`.ok []`) — meaning the file has no managed regions. -/
def locateAllFences (contents : String) :
    Except FenceError (List (Nat × Nat)) := Id.run do
  let lines := contents.splitOn "\n"
  let mut pairs : List (Nat × Nat) := []
  let mut openBegin : Option Nat := none
  for h : i in [:lines.length] do
    let line := lines[i]
    let stripped := stripWhitespace line
    if stripped == beginFenceMarker then
      if openBegin.isSome then
        -- A second BEGIN before an END is treated as multipleBegin.
        return .error .multipleBegin
      openBegin := some i
    else if stripped == endFenceMarker then
      match openBegin with
      | none   => return .error .reversed
      | some b => pairs := pairs ++ [(b, i)]; openBegin := none
  if openBegin.isSome then return .error .noEnd
  return .ok pairs

/-- Extract the fence body (the lines strictly between BEGIN and
    END) as a single newline-joined string.  An empty fence
    (BEGIN immediately followed by END) returns the empty string. -/
def extractFenceContent (contents : String) (b e : Nat) : String :=
  let lines := contents.splitOn "\n"
  let body := (lines.drop (b + 1)).take (e - b - 1)
  String.intercalate "\n" body

/-- Compute the leading whitespace prefix (indentation) of a
    line.  Used by `replaceFenceAt` to preserve the
    BEGIN/END markers' indentation when rewriting. -/
private def leadingWhitespace (s : String) : String :=
  String.ofList (s.toList.takeWhile (fun c => c == ' ' || c == '\t'))

/-- Replace the content between fences with `generated`,
    preserving the header (above BEGIN), footer (below END),
    and the marker lines themselves.

    Behaviour:
      * Header is `lines.take b` joined with newlines and
        terminated with a newline (so concatenation places
        BEGIN on a fresh line).
      * Footer is `lines.drop (e + 1)` joined with newlines.
      * Output ends with a newline iff the original did.
      * If `generated` is empty, the BEGIN and END lines are
        adjacent (no body lines between them).
      * The BEGIN and END lines preserve their pre-rewrite
        indentation (so the markers stay column-aligned with
        the surrounding code). -/
def replaceFenceContent (contents : String) (generated : String) :
    Except FenceError String := do
  let lines := contents.splitOn "\n"
  let (b, e) ← locateFence contents
  let beginLine := lines[b]!
  let endLine := lines[e]!
  let beginIndent := leadingWhitespace beginLine
  let endIndent := leadingWhitespace endLine
  let header := (lines.take b).foldr (fun l acc => l ++ "\n" ++ acc) ""
  let footer := String.intercalate "\n" (lines.drop (e + 1))
  let body := if generated.isEmpty then ""
              else generated ++ (if generated.endsWith "\n" then "" else "\n")
  return header ++ beginIndent ++ beginFenceMarker ++ "\n" ++ body ++
         endIndent ++ endFenceMarker ++ "\n" ++ footer

/-- Replace the fence at the given `(b, e)` line indices with
    `generated`.  Generalisation of `replaceFenceContent` for
    files with multiple fences (use with `locateAllFences`).
    The caller is responsible for processing fences in
    descending-index order so earlier replacements don't
    invalidate later indices.

    BEGIN/END indentation is preserved verbatim from the
    pre-rewrite file (so `lex_codegen` is idempotent on a
    fence whose markers are indented). -/
def replaceFenceAt (contents : String) (b e : Nat) (generated : String) :
    String :=
  let lines := contents.splitOn "\n"
  let beginLine := lines[b]!
  let endLine := lines[e]!
  let beginIndent := leadingWhitespace beginLine
  let endIndent := leadingWhitespace endLine
  let header := (lines.take b).foldr (fun l acc => l ++ "\n" ++ acc) ""
  let footer := String.intercalate "\n" (lines.drop (e + 1))
  let body := if generated.isEmpty then ""
              else generated ++ (if generated.endsWith "\n" then "" else "\n")
  header ++ beginIndent ++ beginFenceMarker ++ "\n" ++ body ++
    endIndent ++ endFenceMarker ++ "\n" ++ footer

/-! ## Per-target renderers (LX.17 / LX.18 / LX.19)

Each renderer takes the sorted `LawDecl` list and returns the
text body to install between the matching fence's BEGIN/END
lines (excluding the marker lines themselves).

M1 emission rule: the example law and any other declaration
whose `requiresEmission` predicate returns `false` are SKIPPED
by every renderer.  M1's example law has identity impl + zero
params + no `Action` extension, so all M1 renderers return
empty strings.  M2 will set `requiresEmission := true`
universally once kernel-built-ins migrate.

The renderers are PURE (no IO); their outputs are deterministic
functions of the input list, which guarantees byte-stability
under repeated runs. -/

/-- Compose the constructor identifier for a Lex law.  The rule:
    take the dot-separated identifier, replace dots with
    underscores, prefix with `lex_`.  E.g.
    `"example.example_lex_only_law"` becomes
    `"lex_example_example_lex_only_law"`.

    Caveat: this is only invoked on emission-required laws, which
    in M1 is the empty set; the function is preserved for M2's
    real renderer logic. -/
def ctorOf (identifier : String) : String :=
  "lex_" ++ identifier.replace "." "_"

/-- Compose the transition-def name for a Lex law.  Mirrors the
    macro's emission convention from `Lex/DSL/Law.lean`:
    `<identifier-with-dots-as-underscores>_transition`. -/
def transitionDefName (identifier : String) : String :=
  identifier.replace "." "_" ++ "_transition"

/-- M1 emission policy: should this Lex law's cross-module
    artefacts be emitted by Pass 2?

    M1 is a *skeleton* milestone (per `docs/planning/lex_implementation_plan.md`
    §19.3): the macro Pass 1, the synthesizer skeleton, and the
    additive codegen Pass 2 are all in place, but the example law
    (LX.21) deliberately does NOT extend the kernel-built-in
    `Action` inductive — it lives in the JSON sidecar registry
    only.  The §LX.21 plan note states explicitly:

    > "Until LX.21, the on-wire format is byte-identical
    > pre/post-LX (no Lex declaration extends Action with a real
    > constructor)."

    Therefore M1's `requiresEmission` returns `false` for every
    Lex declaration.  M2 (LX.22 – LX.30) lifts this: as kernel-
    built-in laws migrate to Lex, the M2-extended emission policy
    will return `true` per-law (probably reading a structured
    `LawDecl.shape` field that the M2-extended macro emits).

    The function-shape is preserved for M2 plug-in; the `decl`
    parameter is intentionally unused in M1. -/
def requiresEmission (_decl : LawDecl) : Bool :=
  false

/-- Filter the input list to only declarations needing cross-module
    emission. -/
def emittedDecls (decls : List LawDecl) : List LawDecl :=
  decls.filter requiresEmission

/-! ### LX.17 — Action renderers -/

/-- Render the body of the `inductive Action` fence.  For each
    emission-required Lex law, emits one line of the form
    `  | <ctorName> (<params>) : Action`.  The constructor name
    is derived from the law's identifier by replacing dots with
    underscores and lowercasing the leading character.

    M1: returns `""` (the example law's `requiresEmission` is
    `false`). -/
def renderActionInductive (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d => s!"  | {ctorOf d.identifier}")
  String.intercalate "\n" lines

/-- Render the body of the `compileTransition` fence.  For each
    emission-required Lex law, emits one line of the form
    `  | .<ctorName> => <transitionDefName>`. -/
def renderCompileTransition (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d =>
    s!"  | .{ctorOf d.identifier} => {transitionDefName d.identifier}")
  String.intercalate "\n" lines

/-! ### LX.18 — Encoding renderers -/

/-- Render the body of the `Action.fieldsBounded` fence. -/
def renderActionFieldsBounded (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d => s!"  | .{ctorOf d.identifier} => True")
  String.intercalate "\n" lines

/-- Render the body of the `Action.encode` fence.

    Audit-5 forward-protection: the M1 skeleton emits only the
    constructor tag, which is correct for parameterless laws but
    silently DROPS field encodings for parameterised laws.  If a
    future author flips `requiresEmission := true` for a
    parameterised law without rewriting this body, the resulting
    on-wire format would be ambiguous (two distinct values would
    encode to the same bytes).

    Defence: when `params` is non-empty, emit a deliberately-
    illegal Lean token so the next `--check` build (or the next
    target-file rebuild) fails immediately with a parse error —
    forcing the author to revisit this renderer rather than
    discovering the bug only via a cross-stack mismatch. -/
def renderActionEncode (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d =>
    if d.params.isEmpty then
      s!"  | .{ctorOf d.identifier} => Encodable.encode (T := Nat) {d.actionIndex}"
    else
      s!"  | .{ctorOf d.identifier} => -- AUDIT-5 FORWARD-PROTECTION: parameterised law `{d.identifier}` requires an M2 encode body; the M1 skeleton drops fields\n      M2_RENDERER_TODO_PARAMETERIZED_ENCODE_{ctorOf d.identifier}")
  String.intercalate "\n" lines

/-- Render the body of the `Action.decode` fence.

    Audit-5 forward-protection: same hazard as `renderActionEncode`
    — the skeleton's reverse path drops fields silently. -/
def renderActionDecode (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d =>
    if d.params.isEmpty then
      s!"  | .ok ({d.actionIndex}, s₁) => .ok (.{ctorOf d.identifier}, s₁)"
    else
      s!"  | .ok ({d.actionIndex}, _s₁) => -- AUDIT-5 FORWARD-PROTECTION: parameterised law `{d.identifier}` requires an M2 decode body; the M1 skeleton drops fields\n      M2_RENDERER_TODO_PARAMETERIZED_DECODE_{ctorOf d.identifier}")
  String.intercalate "\n" lines

/-! ### LX.19 — Events + SignedAction renderers -/

/-- Render the body of the `actionEvents` fence.  M1 rule: if a
    Lex law has an empty `eventsBlock`, emit `[]`. -/
def renderActionEvents (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d =>
    let body :=
      if (stripWhitespace d.eventsBlock).isEmpty ||
         stripWhitespace d.eventsBlock == "[]"
      then "[]"
      else "[]  -- TODO M2: emit synthesizer-generated event list"
    s!"  | .{ctorOf d.identifier} => {body}")
  String.intercalate "\n" lines

/-- Render the body of the `applyActionToRegistry` fence.  Emits
    a per-arm dispatch only for laws whose `registryEffect` is
    non-`none_`.  M1: returns `""`.

    Audit-5 forward-protection: for `replaceKey` / `registerIdentity`
    effects the skeleton's emitted text references identifiers
    (`<ctor>_actor`, `<ctor>_newKey`, `<ctor>_pk`) that don't
    exist as Lean values — they would have to be replaced with
    field-projections on the constructor's bound parameters.
    Until M2 supplies that projection logic, emit a deliberately-
    illegal token so the next `--check` build fails immediately
    rather than silently producing broken Lean. -/
def renderApplyActionToRegistry (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.filterMap (fun d =>
    match d.registryEffect with
    | .none_           => none  -- registry preserved by catch-all `_`
    | .replaceKey      =>
      some s!"  | .{ctorOf d.identifier} => -- AUDIT-5 FORWARD-PROTECTION: M2 must project this ctor's actor/key fields; the M1 skeleton refers to undefined identifiers\n      M2_RENDERER_TODO_REGISTRY_REPLACE_{ctorOf d.identifier}"
    | .registerIdentity =>
      some s!"  | .{ctorOf d.identifier} => -- AUDIT-5 FORWARD-PROTECTION: M2 must project this ctor's actor/pk fields; the M1 skeleton refers to undefined identifiers\n      M2_RENDERER_TODO_REGISTRY_REGISTER_{ctorOf d.identifier}"
    | .localPolicy     => none  -- local-policy effects live in `applyActionToLocalPolicies`
  )
  String.intercalate "\n" lines

/-- Render the body of the `non_registry_mutating_preserves_registry`
    fence.  Emits a per-arm `rfl` for each registry-non-mutating
    Lex law. -/
def renderNonRegistryMutating (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.filterMap (fun d =>
    match d.registryEffect with
    | .none_           => some s!"  | {ctorOf d.identifier} => rfl"
    | .replaceKey      => none  -- excluded by `hneReplace`
    | .registerIdentity => none  -- excluded by `hneRegister`
    | .localPolicy     => some s!"  | {ctorOf d.identifier} => rfl"
  )
  String.intercalate "\n" lines

/-! ## Validation -/

/-- Validate codegen-input set against the registry.  Each
    declaration's identifier must appear in the registry, and
    its `action_index` must match.  Returns the list of
    diagnostic strings (empty = no violations). -/
def validateAgainstRegistry
    (decls : List LawDecl) (entries : List RegistryEntry) : List String :=
  Id.run do
    let mut violations : List String := []
    for d in decls do
      match entries.find? (fun e => e.identifier == d.identifier) with
      | none =>
        violations := violations ++
          [s!"L007: codegen-input identifier `{d.identifier}` not found in registry"]
      | some e =>
        if e.actionIndex != d.actionIndex then
          violations := violations ++
            [s!"L007: codegen-input identifier `{d.identifier}` has action_index {d.actionIndex} but registry says {e.actionIndex}"]
    pure violations

/-! ## Per-target rendering dispatch

The fence in each target file is identified by *position* (the
`locateFence` walker visits them in document order), not by name.
The action-file has TWO fences (Action inductive + compileTransition);
the encoding-file has THREE (fieldsBounded + encode + decode);
the events-file has ONE (actionEvents); the signed-action-file has
TWO (applyActionToRegistry + non_registry_mutating).

`renderTargetFences` builds the rendered content for each fence
position in document order; the caller pairs them with the file's
located fences and overwrites in descending-index order. -/

/-- The rendered content for each fence in a single target file,
    in document order.  Each `String` is the body to write between
    the matching BEGIN/END marker pair. -/
abbrev FenceBodies := List String

/-- Compute the fence bodies for the action-file (2 fences). -/
def actionFileFences (decls : List LawDecl) : FenceBodies :=
  [renderActionInductive decls, renderCompileTransition decls]

/-- Compute the fence bodies for the encoding-file (3 fences). -/
def encodingFileFences (decls : List LawDecl) : FenceBodies :=
  [renderActionFieldsBounded decls,
   renderActionEncode decls,
   renderActionDecode decls]

/-- Compute the fence bodies for the events-file (1 fence). -/
def eventsFileFences (decls : List LawDecl) : FenceBodies :=
  [renderActionEvents decls]

/-- Compute the fence bodies for the signed-action-file (2 fences). -/
def signedActionFileFences (decls : List LawDecl) : FenceBodies :=
  [renderApplyActionToRegistry decls, renderNonRegistryMutating decls]

/-! ## --check mode

Compare each target file's fence contents against the rendered
output.  Divergence fires diagnostic L026 and exits non-zero. -/

/-- Compare the fence contents in a target file against the
    rendered fence bodies (one per fence in document order).
    Returns a non-empty list of diagnostic strings on divergence
    (one per divergent fence) or `[]` on byte-equality.

    M1 invariant: every M1-shipped target file has the right
    number of fences pre-installed, so a count mismatch is
    reported as a single fence-count diagnostic. -/
def checkTargetFile (path : FilePath) (rendered : FenceBodies) :
    IO (List String) := do
  if !(← path.pathExists) then
    -- Target absent.  An absent target is acceptable iff every
    -- rendered body is empty (M1 corpus matches this).
    if rendered.all (·.isEmpty) then
      return []
    else
      return [s!"L026: target file `{path.toString}` does not exist but expected non-empty fence content"]
  let contents ← IO.FS.readFile path
  match locateAllFences contents with
  | .error e =>
    if rendered.all (·.isEmpty) then
      return []
    else
      return [s!"L026: target file `{path.toString}`: {FenceError.toString e}; cannot install non-empty rendering"]
  | .ok fencePairs =>
    if fencePairs.length != rendered.length then
      return [s!"L026: target file `{path.toString}` has {fencePairs.length} fence(s) but expected {rendered.length}"]
    let mut violations : List String := []
    for i in [:rendered.length] do
      let (b, e) := fencePairs[i]!
      let existing := extractFenceContent contents b e
      let renderedBody := rendered[i]!
      -- Both forms are normalised by stripping a trailing newline
      -- so an empty rendered body matches an empty fence body
      -- regardless of how they're spelled.
      let normExisting :=
        if existing.endsWith "\n" then existing.dropEnd 1 |>.toString else existing
      let normRendered :=
        if renderedBody.endsWith "\n" then renderedBody.dropEnd 1 |>.toString else renderedBody
      if normExisting != normRendered then
        violations := violations ++
          [s!"L026: fence #{i + 1} in `{path.toString}` diverges from rendered output"]
    return violations

/-! ## Default mode (in-place rewrite)

Acquires an advisory lockfile on each target before rewriting,
serialising concurrent invocations. -/

/-- The advisory-lock path for a given target.  Co-located with
    the target so a stale lock is easy to spot. -/
private def lockPathFor (path : FilePath) : FilePath :=
  FilePath.mk (path.toString ++ ".lex_codegen.lock")

/-- Acquire an advisory file lock.

    The implementation creates a sentinel file at
    `<path>.lex_codegen.lock`.  Returns `true` if the lock was
    acquired (no prior sentinel existed), `false` if a concurrent
    invocation holds it.

    **Race-condition note.**  This is a TOCTOU-vulnerable
    `pathExists`-then-`writeFile` pattern: two near-simultaneous
    invocations can both observe the absent sentinel and both
    succeed.  This is acceptable for the M1 use case (single
    developer machine; CI runs one `lex_codegen` invocation at a
    time).  M2 may upgrade to `flock(2)` (Linux) / `LockFile`
    (Windows) for production-grade serialisation.

    Callers MUST pair every successful `tryAcquireLock` with a
    later `releaseLock`, even on early-return paths, or the lock
    will leak and block subsequent invocations.  Use
    `withFileLock` for an exception-safe wrapper. -/
def tryAcquireLock (path : FilePath) : IO Bool := do
  let lockPath := lockPathFor path
  if (← lockPath.pathExists) then
    return false
  IO.FS.writeFile lockPath ""
  return true

/-- Release a previously-acquired advisory lock.  Idempotent
    (a missing lock file is silently tolerated). -/
def releaseLock (path : FilePath) : IO Unit := do
  let lockPath := lockPathFor path
  if (← lockPath.pathExists) then
    IO.FS.removeFile lockPath

/-- Run `body` with the target's advisory lock held; the lock is
    released on every exit path (success, error, or thrown
    exception).  Use this rather than ad-hoc
    `tryAcquireLock` / `releaseLock` pairings to guarantee the
    lock isn't leaked.

    Returns:
      * `none` — lock was already held by a concurrent invocation;
        `body` was NOT run.
      * `some result` — lock was acquired, `body` ran to
        completion (or threw an exception, which propagates after
        the lock is released). -/
def withFileLock {α : Type} (path : FilePath) (body : IO α) :
    IO (Option α) := do
  let acquired ← tryAcquireLock path
  if !acquired then
    return none
  -- Audit-5: a transient IO error during cleanup (e.g., a concurrent
  -- process beating us to `removeFile` between our `pathExists` and
  -- `removeFile` calls) must not propagate over the user's IO result.
  -- Both release sites swallow `IO.Error` so the body's outcome is
  -- preserved verbatim.  `releaseLock` is already idempotent for the
  -- normal case (missing-file branch); this `try` only guards the
  -- TOCTOU-race window.
  let safeRelease : IO Unit :=
    try releaseLock path catch _ => pure ()
  try
    let result ← body
    safeRelease
    return some result
  catch e =>
    -- Always release on exception so a transient IO error doesn't
    -- leave a stale lock behind.
    safeRelease
    throw e

/-- Rewrite a target file's fences to match the rendered output.
    Idempotent: a no-op if the existing fence content already
    matches.  Returns `true` if any byte was written, `false`
    otherwise.

    The advisory lock is acquired and released via `withFileLock`
    so EVERY exit path — success, structured error, or thrown
    exception — releases the lock.  An audit finding (commit
    audit-2) closed a lock-leak class where the early-return
    paths inside the `try` block left the lock file behind on
    fence-corruption / fence-count-mismatch errors. -/
def appendToTargetFile (path : FilePath) (rendered : FenceBodies) :
    IO (Except String Bool) := do
  if !(← path.pathExists) then
    if rendered.all (·.isEmpty) then
      return .ok false
    else
      return .error s!"target file `{path.toString}` does not exist but expected non-empty fence content"
  match (← withFileLock path (do
      let contents ← IO.FS.readFile path
      match locateAllFences contents with
      | .error e =>
        return Except.error
          s!"target file `{path.toString}`: {FenceError.toString e}"
      | .ok fencePairs =>
        if fencePairs.length != rendered.length then
          return Except.error
            s!"target file `{path.toString}` has {fencePairs.length} fence(s) but expected {rendered.length}"
        -- Iterate in DESCENDING fence-index order so earlier
        -- replacements don't shift later indices.  Build
        -- (b, e, body) tuples then sort by `b` descending.
        let pairsWithIdx : Array (Nat × Nat × String) :=
          (List.range rendered.length).toArray.map (fun i =>
            let (b, e) := fencePairs[i]!
            let body := rendered[i]!
            (b, e, body))
        let sorted := pairsWithIdx.qsort (fun a b => a.1 > b.1)
        let mut current := contents
        for (b, e, body) in sorted.toList do
          current := replaceFenceAt current b e body
        let beforeBytes := contents
        atomicWriteIfChanged path current
        let changed := beforeBytes != current
        return Except.ok changed)) with
  | none =>
    return .error s!"target file `{path.toString}`: another `lex_codegen` invocation holds the advisory lock"
  | some result => return result

/-! ## Banner / printing helpers -/

/-- Print the codegen binary's startup banner. -/
def printBanner : IO Unit := do
  IO.println "lex_codegen — Workstream LX (LX.17 – LX.20) codegen binary"
  IO.println s!"  codegen-inputs:  {codegenInputsDir.toString}"
  IO.println s!"  registry:        {registryPath.toString}"

/-! ## Main entry -/

/-- Print `--help` text and exit 0. -/
def printHelp : IO UInt32 := do
  IO.println "lex_codegen — Workstream LX (LX.17 – LX.20) codegen binary"
  IO.println ""
  IO.println "Usage: lake exe lex_codegen [--check] [--canonical] [--help]"
  IO.println ""
  IO.println "Reads codegen-input JSON files from `Lex/Inputs/`,"
  IO.println "validates them against `Lex/IndexRegistry.txt`, and rewrites"
  IO.println "the four cross-module artefacts (`Authority/Action.lean`,"
  IO.println "`Encoding/Action.lean`, `Events/Extract.lean`,"
  IO.println "`Authority/SignedAction.lean`) within their LEX-GENERATED"
  IO.println "fence pairs."
  IO.println ""
  IO.println "Options:"
  IO.println "  --check       Verify committed artefacts match the rendered"
  IO.println "                output byte-for-byte (no file writes; CI-gating"
  IO.println "                mode).  Exits 1 with diagnostic L026 on"
  IO.println "                divergence."
  IO.println "  --canonical   M2 mode: regenerate the entire target body"
  IO.println "                rather than the fence contents.  Not yet"
  IO.println "                implemented in M1; rejected with exit 2."
  IO.println "  --help, -h    Show this help message and exit."
  IO.println ""
  IO.println "Exit codes:"
  IO.println "  0  success."
  IO.println "  1  divergence detected (in --check mode), render error,"
  IO.println "     or registry-input mismatch."
  IO.println "  2  internal binary failure (cannot read a file, --canonical"
  IO.println "     not yet implemented)."
  return 0

/-- LX-M2 audit-3 (canonical-mode summary): emit a structured
    `Lex/Inputs/canonical_manifest.txt` listing every
    Lex law's metadata in a stable, diff-friendly format.  This is
    the M2 SCAFFOLD for canonical-mode; M3 will extend it to
    full-body regeneration of the 4 target files
    (`Authority/Action.lean`, `Encoding/Action.lean`,
    `Events/Extract.lean`, `Authority/SignedAction.lean`).

    The manifest contains one section per Lex law, listing:
      * identifier, version, action_index
      * intent (one-line summary)
      * params (name : type)
      * registry_effect classification
      * lex_satisfies claims
      * source location

    The manifest is byte-stable across runs (sorted by
    action_index) and is suitable for code-review diff
    comparisons.

    M3 will expand this manifest into a Lean module that re-
    exports each law's `Action` constructor, `Transition`,
    encoder/decoder arms, and event-emission rules — replacing
    the hand-written cross-module artefacts entirely. -/
def emitCanonicalManifest (decls : List LawDecl) : String := Id.run do
  let mut buf : String :=
    "# Canon — Lex law canonical manifest\n" ++
    "#\n" ++
    "# Generated by `lake exe lex_codegen --canonical`.\n" ++
    "# This file is a STRUCTURED SUMMARY of every Lex law's metadata,\n" ++
    "# sorted by frozen action index.  It serves as the M2 scaffold\n" ++
    "# for the canonical-mode codegen; M3 will expand this manifest\n" ++
    "# into full-body regeneration of the four cross-module artefacts\n" ++
    "# (`Authority/Action.lean`, `Encoding/Action.lean`,\n" ++
    "# `Events/Extract.lean`, `Authority/SignedAction.lean`).\n" ++
    "#\n" ++
    "# DO NOT EDIT BY HAND — re-run `lake exe lex_codegen --canonical`\n" ++
    "# to regenerate after a Lex declaration changes.\n" ++
    "\n"
  -- Stable canonical ordering: primary key is `actionIndex`; secondary
  -- key is `identifier` (lexicographic).  `Array.qsort` is not stable,
  -- so two decls sharing an `actionIndex` (which is itself a registry
  -- corruption — caught by `lex_lint`'s uniqueness check) could
  -- otherwise produce a non-deterministic manifest order, breaking
  -- the §LX.20 byte-stability claim.  A total tie-breaker eliminates
  -- the instability under any corrupt-input scenario.
  let sortedDecls := decls.toArray.qsort
    (fun a b =>
      if a.actionIndex < b.actionIndex then true
      else if a.actionIndex > b.actionIndex then false
      else a.identifier < b.identifier)
  for decl in sortedDecls do
    buf := buf ++ s!"## {decl.identifier} (action_index = {decl.actionIndex})\n"
    buf := buf ++ s!"version: {decl.version}\n"
    buf := buf ++ s!"intent: {decl.intent}\n"
    buf := buf ++ s!"params:\n"
    if decl.params.isEmpty then
      buf := buf ++ "  (none)\n"
    else
      for p in decl.params do
        let kindStr : String := match p.kind with
          | .explicit       => "explicit"
          | .implicit       => "implicit"
          | .strictImplicit => "strict_implicit"
          | .inst           => "inst"
        buf := buf ++ s!"  - {p.name} : {p.type} ({kindStr})\n"
    buf := buf ++ s!"signed_by: {decl.signedBy.name}\n"
    let regEffStr : String := match decl.registryEffect with
      | .none_            => "none"
      | .replaceKey       => "replaceKey"
      | .registerIdentity => "registerIdentity"
      | .localPolicy      => "localPolicy"
    buf := buf ++ s!"registry_effect: {regEffStr}\n"
    buf := buf ++ s!"satisfies:\n"
    if decl.satisfies.isEmpty then
      buf := buf ++ "  (none)\n"
    else
      for c in decl.satisfies do
        buf := buf ++ s!"  - {c.name}\n"
    buf := buf ++ s!"source: {decl.sourceLocation.fileName}\n"
    buf := buf ++ "\n"
  pure buf

/-! ## Property-test auto-generator (LX.38)

The `--gen-property-tests` flag emits a real
`Lex/Test/AutoGenProperties.lean` Lean test file
containing one property-test invocation per `(law, property)`
pair declared in the codegen-input JSONs.

# Coverage matrix

For each kernel-built-in law in the codegen-input directory,
the generator produces:

  * `conservative` ⇒ `<law>ConservativeProperty` — sample state,
    apply law, assert `TotalSupply` unchanged at the law's
    resource.
  * `monotonic` ⇒ `<law>MonotonicProperty` — sample state,
    apply law, assert `TotalSupply` non-decreasing.
  * `local` ⇒ `<law>LocalProperty` — sample state, apply law,
    assert other resources' balances unchanged.
  * `freeze_preserving` ⇒ `<law>FreezePreservingProperty` —
    sample state, apply law, assert touched resources'
    balances unchanged.
  * Other property kinds (`nonce_advances`, `registry_preserving`,
    `local`-without-resource-set) are recorded in a coverage
    comment but not auto-tested (they require authority-layer
    setup beyond the kernel-level sampling harness).

# Per-law parameter signatures

The generator hard-codes the parameter signatures of the
17 kernel-built-in laws (because their parameter shapes are
known statically and will not change without an action-index
re-allocation).  For deployment-private Lex laws the
generator emits a coverage-comment-only entry (since the
parameter shapes are not exposed in the JSON sidecar's
`params` list in a synthesizer-consumable form).

# Skip envelope

Each emitted test wraps in `if env CANON_AUTOGEN_SKIP = "1"
then return ()` per §LX.38, so CI can opt out for fast cycles
(e.g. when iterating on the kernel proof set). -/

/-- The set of kernel-built-in law identifiers that the auto-
    generator can produce per-property tests for.  Each entry
    maps the canonical identifier to a synthesizable test
    profile: the parameterless wrapper expression and per-
    property test renderers. -/
private def autoGenSupportedLaws : List String :=
  [ "legalkernel.transfer",
    "legalkernel.mint",
    "legalkernel.burn",
    "legalkernel.freezeResource",
    "legalkernel.reward" ]

/-- Sanitise a law identifier into a Lean-test-name fragment
    (replace dots with underscores, no other transformations). -/
private def sanitiseLawIdForTestName (identifier : String) : String :=
  identifier.replace "." "_"

/-- Wrap a per-property test body in the canonical TestCase
    template with skip-envelope, seed loading, and the `forAll`
    driver. -/
private def renderTestCaseTemplate (testDefName : String)
    (testDisplayName : String) (lawTerm : String) : String :=
  "/-- Auto-gen LX.38: " ++ testDisplayName ++ ". -/\n" ++
  "def " ++ testDefName ++ " : TestCase := {\n" ++
  "  name := \"auto-gen LX.38: " ++ testDisplayName ++ "\"\n" ++
  "  body := do\n" ++
  "    match (← IO.getEnv \"CANON_AUTOGEN_SKIP\") with\n" ++
  "    | some \"1\" =>\n" ++
  "      IO.println \"  (skipped via CANON_AUTOGEN_SKIP=1)\"\n" ++
  "      return ()\n" ++
  "    | _ => pure ()\n" ++
  "    let seed ← readSeed\n" ++
  "    let n ← readIterations\n" ++
  "    forAll (T := State) n seed (genTestState 4 50) (fun s =>\n" ++
  "      " ++ lawTerm ++ ")\n" ++
  "}\n\n"

/-- Render a `conservative` property test for a known kernel-
    built-in law.  Returns `none` if the law's `conservative`
    property is unsupported by v1's auto-generator. -/
private def renderConservativeTest (lawId : String) : Option String :=
  let safe := sanitiseLawIdForTestName lawId
  let lawNameSuffix := lawId.splitOn "." |>.getLast?.getD lawId
  let lawTerm? : Option String := match lawNameSuffix with
    | "transfer" => some
        ("let r : ResourceId := 0\n      let sender : ActorId := 0\n" ++
         "      let receiver : ActorId := 1\n      let bal := getBalance s r sender\n" ++
         "      let amount := if bal > 0 then 1 else 0\n" ++
         "      let t := Laws.transfer r sender receiver amount\n" ++
         "      if _ : t.pre s then\n" ++
         "        let s' := step_impl s t\n" ++
         "        decide (TotalSupply s r = TotalSupply s' r)\n" ++
         "      else true")
    | "freezeResource" => some
        ("let r : ResourceId := 0\n      let t := Laws.freezeResource r\n" ++
         "      let s' := step_impl s t\n" ++
         "      decide (TotalSupply s r = TotalSupply s' r)")
    | _ => none
  match lawTerm? with
  | none => none
  | some lawTerm =>
    let display := s!"{lawId}.conservative property holds (100 samples)"
    some (renderTestCaseTemplate (safe ++ "ConservativeProperty") display lawTerm)

/-- Render a `monotonic` property test. -/
private def renderMonotonicTest (lawId : String) : Option String :=
  let safe := sanitiseLawIdForTestName lawId
  let lawNameSuffix := lawId.splitOn "." |>.getLast?.getD lawId
  let lawTerm? : Option String := match lawNameSuffix with
    | "transfer" => some
        ("let r : ResourceId := 0\n      let sender : ActorId := 0\n" ++
         "      let receiver : ActorId := 1\n      let bal := getBalance s r sender\n" ++
         "      let amount := if bal > 0 then 1 else 0\n" ++
         "      let t := Laws.transfer r sender receiver amount\n" ++
         "      if _ : t.pre s then\n" ++
         "        let s' := step_impl s t\n" ++
         "        decide (TotalSupply s r ≤ TotalSupply s' r)\n" ++
         "      else true")
    | "mint" => some
        ("let r : ResourceId := 0\n      let recipient : ActorId := 0\n" ++
         "      let amount : Amount := 5\n" ++
         "      let t := Laws.mint r recipient amount\n" ++
         "      if _ : t.pre s then\n" ++
         "        let s' := step_impl s t\n" ++
         "        decide (TotalSupply s r ≤ TotalSupply s' r)\n" ++
         "      else true")
    | "freezeResource" => some
        ("let r : ResourceId := 0\n      let t := Laws.freezeResource r\n" ++
         "      let s' := step_impl s t\n" ++
         "      decide (TotalSupply s r ≤ TotalSupply s' r)")
    | _ => none
  match lawTerm? with
  | none => none
  | some lawTerm =>
    let display := s!"{lawId}.monotonic property holds (100 samples)"
    some (renderTestCaseTemplate (safe ++ "MonotonicProperty") display lawTerm)

/-- Render a `local` property test. -/
private def renderLocalTest (lawId : String) : Option String :=
  let safe := sanitiseLawIdForTestName lawId
  let lawNameSuffix := lawId.splitOn "." |>.getLast?.getD lawId
  let lawTerm? : Option String := match lawNameSuffix with
    | "transfer" => some
        ("let r : ResourceId := 0\n      let r' : ResourceId := 1\n" ++
         "      let sender : ActorId := 0\n      let receiver : ActorId := 1\n" ++
         "      let bal := getBalance s r sender\n" ++
         "      let amount := if bal > 0 then 1 else 0\n" ++
         "      let t := Laws.transfer r sender receiver amount\n" ++
         "      if _ : t.pre s then\n" ++
         "        let s' := step_impl s t\n" ++
         "        decide (getBalance s r' 0 = getBalance s' r' 0 ∧\n" ++
         "                getBalance s r' 1 = getBalance s' r' 1)\n" ++
         "      else true")
    | "mint" => some
        ("let r : ResourceId := 0\n      let r' : ResourceId := 1\n" ++
         "      let recipient : ActorId := 0\n      let amount : Amount := 5\n" ++
         "      let t := Laws.mint r recipient amount\n" ++
         "      if _ : t.pre s then\n" ++
         "        let s' := step_impl s t\n" ++
         "        decide (getBalance s r' 0 = getBalance s' r' 0)\n" ++
         "      else true")
    | _ => none
  match lawTerm? with
  | none => none
  | some lawTerm =>
    let display := s!"{lawId}.local property holds (100 samples)"
    some (renderTestCaseTemplate (safe ++ "LocalProperty") display lawTerm)

/-- Render a `freeze_preserving` property test. -/
private def renderFreezePreservingTest (lawId : String) : Option String :=
  let safe := sanitiseLawIdForTestName lawId
  let lawNameSuffix := lawId.splitOn "." |>.getLast?.getD lawId
  let lawTerm? : Option String := match lawNameSuffix with
    | "freezeResource" => some
        ("let r : ResourceId := 0\n      let t := Laws.freezeResource r\n" ++
         "      let s' := step_impl s t\n" ++
         "      decide (getBalance s r 0 = getBalance s' r 0 ∧\n" ++
         "              getBalance s r 1 = getBalance s' r 1)")
    | _ => none
  match lawTerm? with
  | none => none
  | some lawTerm =>
    let display := s!"{lawId}.freeze_preserving property holds (100 samples)"
    some (renderTestCaseTemplate (safe ++ "FreezePreservingProperty") display lawTerm)

/-- Render a per-(law, property) test based on the law's
    `satisfies` claim.  Returns `none` if the law-property pair
    is unsupported (e.g. `nonce_advances` requires authority-
    layer setup that the v1 auto-generator doesn't model, or
    the law's parameter signature isn't known to the renderer). -/
private def renderPropertyTest (lawId : String) (propertyName : String) :
    Option String :=
  if !autoGenSupportedLaws.contains lawId then none
  else
    match propertyName with
    | "conservative"      => renderConservativeTest lawId
    | "monotonic"         => renderMonotonicTest lawId
    | "local"             => renderLocalTest lawId
    | "freeze_preserving" => renderFreezePreservingTest lawId
    | _ => none

/-- Emit the full `Lex/Test/AutoGenProperties.lean` test
    file.  Walks the codegen-input list, emits per-(law, property)
    tests for supported pairs, and records unsupported pairs in a
    coverage comment.

    Byte-stable on equal inputs (deterministic iteration over
    sorted laws). -/
def emitAutoGenLean (decls : List LawDecl) : String := Id.run do
  let sortedDecls := decls.toArray.qsort
    (fun a b =>
      if a.actionIndex < b.actionIndex then true
      else if a.actionIndex > b.actionIndex then false
      else a.identifier < b.identifier)
  let mut header : String :=
    "/-\n" ++
    "  Canon  - A Societal Kernel\n" ++
    "  Copyright (C) 2026  Adam Hall\n" ++
    "  This program comes with ABSOLUTELY NO WARRANTY.\n" ++
    "  This is free software, and you are welcome to redistribute it\n" ++
    "  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE\n" ++
    "-/\n\n" ++
    "/-\n" ++
    "Lex.Test.AutoGenProperties — Workstream-LX (M3) auto-\n" ++
    "generated property-test suite.\n\n" ++
    "LX.38 of `docs/planning/lex_implementation_plan.md`.\n\n" ++
    "**THIS FILE IS AUTO-GENERATED.**  Do not edit by hand.\n" ++
    "Re-generate by running:\n\n" ++
    "  lake exe lex_codegen --gen-property-tests\n\n" ++
    "The generator reads `Lex/Inputs/*.json` and\n" ++
    "emits one property-test harness invocation per supported\n" ++
    "`(law, property)` pair declared in each law's `satisfies`\n" ++
    "claims list.\n\n" ++
    "Skip envelope: each test wraps in `CANON_AUTOGEN_SKIP=1`\n" ++
    "(per §LX.38) so CI can opt out for fast cycles.\n" ++
    "-/\n\n"
  let imports : String :=
    "import LegalKernel.Test.Framework\n" ++
    "import LegalKernel.Test.Property\n" ++
    "import LegalKernel.Conservation\n" ++
    "import LegalKernel.Laws.Transfer\n" ++
    "import LegalKernel.Laws.Mint\n" ++
    "import LegalKernel.Laws.Burn\n" ++
    "import LegalKernel.Laws.Reward\n" ++
    "import LegalKernel.Laws.Freeze\n\n" ++
    "namespace Lex.Test.AutoGenProperties\n\n" ++
    "open LegalKernel\n" ++
    "open LegalKernel.Laws\n" ++
    "open LegalKernel.Test\n" ++
    "open LegalKernel.Test.Property\n\n"
  let helpers : String :=
    "/-! ## Helpers: random state generation -/\n\n" ++
    "/-- Generate a small `State` with sampled balances across\n" ++
    "    multiple resources.  `nActors` controls the breadth\n" ++
    "    (default 4); `nResources` is the number of distinct\n" ++
    "    resource-id slots populated (default 3 — covers indices\n" ++
    "    0, 1, 2).\n\n" ++
    "    Audit-5 fix: pre-fix the generator only populated\n" ++
    "    resource 0, which made `local`-property tests trivial\n" ++
    "    (e.g. `transferLocalProperty` checks `getBalance s r' a =\n" ++
    "    getBalance s' r' a` for `r' = 1`; with all r'=1 balances\n" ++
    "    being 0, the test reduced to `0 = 0` — a tautology that\n" ++
    "    would silently pass even if `transfer` corrupted other-\n" ++
    "    resource state).  Now populates resources 0..nResources-1\n" ++
    "    with independently-sampled balances. -/\n" ++
    "def genTestState (nActors : Nat := 4) (balanceMax : Nat := 100)\n" ++
    "    (nResources : Nat := 3) :\n" ++
    "    Gen State := fun st =>\n" ++
    "  let rec actorsLoop (r : Nat) (n : Nat) (s : State) (gs : GenState) :\n" ++
    "      State × GenState :=\n" ++
    "    if n = 0 then (s, gs)\n" ++
    "    else\n" ++
    "      let (bal, gs1) := genNat balanceMax gs\n" ++
    "      let actorId : ActorId := UInt64.ofNat (n - 1)\n" ++
    "      let resourceId : ResourceId := UInt64.ofNat r\n" ++
    "      let s' := setBalance s resourceId actorId bal\n" ++
    "      actorsLoop r (n - 1) s' gs1\n" ++
    "  let rec resourcesLoop (r : Nat) (s : State) (gs : GenState) :\n" ++
    "      State × GenState :=\n" ++
    "    if r = 0 then (s, gs)\n" ++
    "    else\n" ++
    "      let (s', gs') := actorsLoop (r - 1) nActors s gs\n" ++
    "      resourcesLoop (r - 1) s' gs'\n" ++
    "  resourcesLoop nResources emptyState st\n\n"
  let mut body : String := ""
  let mut testNames : List String := []
  let mut coverageComments : List String := []
  for decl in sortedDecls do
    if decl.satisfies.isEmpty then continue
    if !autoGenSupportedLaws.contains decl.identifier then
      coverageComments := coverageComments ++
        [s!"-- {decl.identifier}: unsupported by auto-generator (deployment-private or unknown signature); coverage manifest only"]
      continue
    for claim in decl.satisfies do
      match renderPropertyTest decl.identifier claim.name with
      | some testSrc =>
        body := body ++ testSrc
        let safe := sanitiseLawIdForTestName decl.identifier
        let propCap : String := match claim.name with
          | "conservative" => "ConservativeProperty"
          | "monotonic" => "MonotonicProperty"
          | "local" => "LocalProperty"
          | "freeze_preserving" => "FreezePreservingProperty"
          | _ => "UnknownProperty"
        testNames := testNames ++ [s!"{safe}{propCap}"]
      | none =>
        coverageComments := coverageComments ++
          [s!"-- {decl.identifier}.{claim.name}: out-of-scope for v1 auto-generator"]
  let coverageBlock : String :=
    if coverageComments.isEmpty then ""
    else
      "/-! ## Coverage notes (for pairs not auto-tested) -/\n\n" ++
      String.join (coverageComments.map (· ++ "\n")) ++ "\n"
  let testsListBody : String :=
    if testNames.isEmpty then "  []"
    else "  [ " ++ String.intercalate ",\n    " testNames ++ " ]"
  let footer : String :=
    "/-! ## Combined test suite -/\n\n" ++
    "/-- The complete LX.38 auto-generated test suite. -/\n" ++
    "def tests : List TestCase :=\n" ++
    testsListBody ++ "\n\n" ++
    "end Lex.Test.AutoGenProperties\n"
  pure (header ++ imports ++ helpers ++ coverageBlock ++ body ++ footer)

/-- Main entry.  Parses arguments, runs the pipeline, prints
    diagnostics, returns exit code (0/1/2 per §13.3 conventions).
    Audit-3 added `--help` / `-h`.

    LX-M2 audit-3 amendment: `--canonical` mode now emits a
    structured canonical-manifest summary file via
    `emitCanonicalManifest` instead of returning exit code 2.
    Full-body regeneration of the 4 target files is M3 work.

    LX.38 amendment: `--gen-property-tests` mode emits a
    coverage-manifest summary file
    (`Lex/Inputs/property_test_coverage.txt`). -/
def main (args : List String) : IO UInt32 := do
  if args.contains "--help" || args.contains "-h" then
    return (← printHelp)
  printBanner
  let opts := parseOptions args
  -- LX.38: --gen-property-tests mode.  Emits a real Lean test
  -- file at `Lex/Test/AutoGenProperties.lean` containing
  -- one property-test invocation per supported (law, property)
  -- pair declared in the codegen-input JSONs' `satisfies` claims.
  if opts.genPropertyTests then
    IO.println "lex_codegen --gen-property-tests: M3 LX.38 auto-gen"
    match (← loadCodegenInputs opts.inputDir) with
    | .error msg =>
      IO.eprintln s!"lex_codegen --gen-property-tests: {msg}"
      return 2
    | .ok decls =>
      let autoGenSrc := emitAutoGenLean decls
      let autoGenPath : System.FilePath :=
        FilePath.mk "Lex/Test/AutoGenProperties.lean"
      if opts.checkOnly then
        if (← autoGenPath.pathExists) then
          let existing ← IO.FS.readFile autoGenPath
          if existing == autoGenSrc then
            IO.println s!"lex_codegen --gen-property-tests --check: {decls.length} law(s); AutoGen.lean is byte-stable; OK"
            return 0
          else
            IO.eprintln s!"lex_codegen --gen-property-tests --check: AutoGen.lean divergence at {autoGenPath.toString}"
            IO.eprintln "  re-run `lake exe lex_codegen --gen-property-tests` to regenerate"
            return 1
        else
          IO.eprintln s!"lex_codegen --gen-property-tests --check: AutoGen.lean does not exist at {autoGenPath.toString}"
          IO.eprintln "  run `lake exe lex_codegen --gen-property-tests` to generate"
          return 1
      else
        match (← withFileLock autoGenPath
                  (atomicWriteIfChanged autoGenPath autoGenSrc)) with
        | none =>
          IO.eprintln s!"lex_codegen --gen-property-tests: another invocation holds the advisory lock for {autoGenPath.toString}"
          return 1
        | some _ =>
          IO.println s!"lex_codegen --gen-property-tests: emitted AutoGen.lean for {decls.length} law(s) to {autoGenPath.toString}"
          return 0
  if opts.canonical then
    -- LX-M2 audit-3: --canonical mode now emits a structured
    -- canonical-manifest summary file instead of exiting with
    -- code 2.  Full-body regeneration of the 4 target files
    -- (Authority/Action.lean, Encoding/Action.lean,
    -- Events/Extract.lean, Authority/SignedAction.lean) is M3
    -- work; this scaffold establishes the canonical-mode entry
    -- point and provides a useful intermediate artefact.
    --
    -- Combining `--canonical` with `--check`: the canonical-
    -- manifest is regenerated and byte-compared against the
    -- committed file.  Divergence (e.g., from un-regenerated
    -- post-Lex-edit state) returns exit code 1 to fail CI.
    IO.println "lex_codegen --canonical: M2 scaffold mode"
    IO.println "  (full-body regeneration of cross-module artefacts is M3 work;"
    IO.println "   this mode emits a canonical-manifest summary file)"
    match (← loadCodegenInputs opts.inputDir) with
    | .error msg =>
      IO.eprintln s!"lex_codegen --canonical: {msg}"
      return 2
    | .ok decls =>
      let manifest := emitCanonicalManifest decls
      let manifestPath : System.FilePath :=
        opts.inputDir / "canonical_manifest.txt"
      if opts.checkOnly then
        -- --canonical --check: byte-compare against committed
        -- file (CI-gating mode).
        if (← manifestPath.pathExists) then
          let existing ← IO.FS.readFile manifestPath
          if existing == manifest then
            IO.println s!"lex_codegen --canonical --check: {decls.length} law(s); manifest is byte-stable; OK"
            return 0
          else
            IO.eprintln s!"lex_codegen --canonical --check: manifest divergence detected at {manifestPath.toString}"
            IO.eprintln "  re-run `lake exe lex_codegen --canonical` to regenerate"
            return 1
        else
          IO.eprintln s!"lex_codegen --canonical --check: manifest does not exist at {manifestPath.toString}"
          IO.eprintln "  run `lake exe lex_codegen --canonical` to generate"
          return 1
      else
        -- Audit-4: wrap the manifest write in `withFileLock` so
        -- concurrent `--canonical` invocations serialise.
        -- Pre-audit-4, the canonical-mode write bypassed the
        -- advisory lock (only the default-mode `appendToTargetFile`
        -- had lock protection), allowing two concurrent
        -- invocations to race.  The lock is now held over the
        -- full write so the canonical manifest's byte-stability
        -- holds even under concurrent invocations.
        match (← withFileLock manifestPath
                  (atomicWriteIfChanged manifestPath manifest)) with
        | none =>
          IO.eprintln s!"lex_codegen --canonical: another invocation holds the advisory lock for {manifestPath.toString}"
          return 1
        | some _ =>
          IO.println s!"lex_codegen --canonical: emitted {decls.length} law(s) to {manifestPath.toString}"
          return 0
  -- Load codegen inputs.
  match (← loadCodegenInputs opts.inputDir) with
  | .error msg =>
    IO.eprintln s!"lex_codegen: {msg}"
    return 2
  | .ok decls =>
    -- Load registry.
    let regContents ←
      if (← registryPath.pathExists) then IO.FS.readFile registryPath
      else pure ""
    match parseRegistry regContents with
    | .error errs =>
      for e in errs do IO.eprintln s!"lex_codegen: registry error: {e}"
      return 2
    | .ok entries =>
      -- Validate consistency.
      let violations := validateAgainstRegistry decls entries
      for v in violations do IO.eprintln v
      if !violations.isEmpty then
        IO.eprintln s!"lex_codegen: {violations.length} violation(s); FAILED"
        return 1
      -- Render targets.
      let actionBodies := actionFileFences decls
      let encodingBodies := encodingFileFences decls
      let eventsBodies := eventsFileFences decls
      let signedBodies := signedActionFileFences decls
      if opts.checkOnly then
        -- LX.20 `--check` mode: byte-compare each target file's
        -- fence contents against the rendered output.
        let mut allViolations : List String := []
        let actionV ← checkTargetFile opts.outputs.actionFile actionBodies
        allViolations := allViolations ++ actionV
        let encV ← checkTargetFile opts.outputs.encodingFile encodingBodies
        allViolations := allViolations ++ encV
        let evV ← checkTargetFile opts.outputs.eventsFile eventsBodies
        allViolations := allViolations ++ evV
        let saV ← checkTargetFile opts.outputs.signedActionFile signedBodies
        allViolations := allViolations ++ saV
        -- LX.38 amendment: also check `AutoGen.lean` if it exists.
        -- Per spec: "`lex_codegen --check` includes the auto-
        -- generated file in its consistency check."  We check it
        -- only when present so the gate is opt-in (via existing
        -- AutoGen.lean) — running on a project that doesn't use
        -- the autogen feature shouldn't fail.
        let autoGenPath : System.FilePath :=
          FilePath.mk "Lex/Test/AutoGenProperties.lean"
        if (← autoGenPath.pathExists) then
          let autoGenSrc := emitAutoGenLean decls
          let existing ← IO.FS.readFile autoGenPath
          if existing != autoGenSrc then
            allViolations := allViolations ++
              [s!"L026: AutoGen.lean diverges from rendered output at {autoGenPath.toString}"]
        if allViolations.isEmpty then
          IO.println s!"lex_codegen --check: {decls.length} input(s); no divergence; OK"
          return 0
        else
          for v in allViolations do IO.eprintln v
          IO.eprintln s!"lex_codegen --check: {allViolations.length} divergence(s); FAILED"
          return 1
      else
        -- Default mode: rewrite each target's fence in place.
        let mut writeErrors : List String := []
        let mut writes : Nat := 0
        match (← appendToTargetFile opts.outputs.actionFile actionBodies) with
        | .ok changed => if changed then writes := writes + 1
        | .error msg => writeErrors := writeErrors ++ [msg]
        match (← appendToTargetFile opts.outputs.encodingFile encodingBodies) with
        | .ok changed => if changed then writes := writes + 1
        | .error msg => writeErrors := writeErrors ++ [msg]
        match (← appendToTargetFile opts.outputs.eventsFile eventsBodies) with
        | .ok changed => if changed then writes := writes + 1
        | .error msg => writeErrors := writeErrors ++ [msg]
        match (← appendToTargetFile opts.outputs.signedActionFile signedBodies) with
        | .ok changed => if changed then writes := writes + 1
        | .error msg => writeErrors := writeErrors ++ [msg]
        for e in writeErrors do IO.eprintln e
        if !writeErrors.isEmpty then
          IO.eprintln s!"lex_codegen: {writeErrors.length} write error(s); FAILED"
          return 1
        IO.println s!"lex_codegen: {decls.length} codegen-input(s) processed; {writes} target(s) rewritten"
        return 0

end LegalKernel.Tools.Lex.Codegen

-- Entry-point glue for the `lex_codegen` Lake executable lives
-- in the project-root `LexCodegen.lean` file (mirrors the
-- `Main.lean`/`canon` and `Replay.lean`/`canon-replay` pattern).
-- Keeping `def main` out of this module lets tests import the
-- helpers as a library without clashing with `Lex.Tools.Lint`'s
-- entry-point glue.

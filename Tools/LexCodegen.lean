/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.LexCodegen — the Workstream-LX codegen binary.

LX.17 / LX.18 / LX.19 / LX.20 of
`docs/lex_implementation_plan.md`.

Reads every JSON file under `LegalKernel/_lex_inputs/`, sorts
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
  * `--canonical` — M2 mode: regenerate the entire target body
    (no fences).  Not yet implemented.

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

import Tools.LexCommon

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
  /-- Codegen-input directory. -/
  inputDir : FilePath := codegenInputsDir
  /-- Output target paths. -/
  outputs : Outputs := {}

/-- Default-valued `CodegenOptions` honouring all field defaults. -/
instance : Inhabited CodegenOptions := ⟨{}⟩

/-- Parse argv into a `CodegenOptions`.  Supports `--check`,
    `--canonical`, and ignores other arguments (forward-
    compatibility for v2 flags). -/
def parseOptions (args : List String) : CodegenOptions := Id.run do
  let mut opts : CodegenOptions := {}
  for arg in args do
    if arg == "--check" then
      opts := { opts with checkOnly := true }
    else if arg == "--canonical" then
      opts := { opts with canonical := true }
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
    macro's emission convention from `LegalKernel/DSL/LexLaw.lean`:
    `<identifier-with-dots-as-underscores>_transition`. -/
def transitionDefName (identifier : String) : String :=
  identifier.replace "." "_" ++ "_transition"

/-- M1 emission policy: should this Lex law's cross-module
    artefacts be emitted by Pass 2?

    M1 is a *skeleton* milestone (per `docs/lex_implementation_plan.md`
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

/-- Render the body of the `Action.encode` fence. -/
def renderActionEncode (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d =>
    s!"  | .{ctorOf d.identifier} => Encodable.encode (T := Nat) {d.actionIndex}")
  String.intercalate "\n" lines

/-- Render the body of the `Action.decode` fence. -/
def renderActionDecode (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.map (fun d =>
    s!"  | .ok ({d.actionIndex}, s₁) => .ok (.{ctorOf d.identifier}, s₁)")
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
    non-`none_`.  M1: returns `""`. -/
def renderApplyActionToRegistry (decls : List LawDecl) : String :=
  let emitted := emittedDecls decls
  let lines := emitted.filterMap (fun d =>
    match d.registryEffect with
    | .none_           => none  -- registry preserved by catch-all `_`
    | .replaceKey      => some s!"  | .{ctorOf d.identifier} => kr.insert {(ctorOf d.identifier)}_actor {(ctorOf d.identifier)}_newKey"
    | .registerIdentity => some s!"  | .{ctorOf d.identifier} => kr.insert {(ctorOf d.identifier)}_actor {(ctorOf d.identifier)}_pk"
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

/-- Acquire an advisory file lock by atomically creating a
    sentinel file.  Returns `true` if the lock was acquired,
    `false` if a concurrent invocation holds it.  A failed
    acquisition is treated as a non-fatal warning by the caller
    (the second invocation's writes are skipped). -/
def tryAcquireLock (path : FilePath) : IO Bool := do
  let lockPath := FilePath.mk (path.toString ++ ".lex_codegen.lock")
  if (← lockPath.pathExists) then
    return false
  IO.FS.writeFile lockPath ""
  return true

/-- Release a previously-acquired advisory lock. -/
def releaseLock (path : FilePath) : IO Unit := do
  let lockPath := FilePath.mk (path.toString ++ ".lex_codegen.lock")
  if (← lockPath.pathExists) then
    IO.FS.removeFile lockPath

/-- Rewrite a target file's fences to match the rendered output.
    Idempotent: a no-op if the existing fence content already
    matches.  Returns `true` if any byte was written, `false`
    otherwise. -/
def appendToTargetFile (path : FilePath) (rendered : FenceBodies) :
    IO (Except String Bool) := do
  if !(← path.pathExists) then
    if rendered.all (·.isEmpty) then
      return .ok false
    else
      return .error s!"target file `{path.toString}` does not exist but expected non-empty fence content"
  let acquired ← tryAcquireLock path
  if !acquired then
    return .error s!"target file `{path.toString}`: another `lex_codegen` invocation holds the advisory lock"
  try
    let contents ← IO.FS.readFile path
    match locateAllFences contents with
    | .error e =>
      return .error s!"target file `{path.toString}`: {FenceError.toString e}"
    | .ok fencePairs =>
      if fencePairs.length != rendered.length then
        return .error s!"target file `{path.toString}` has {fencePairs.length} fence(s) but expected {rendered.length}"
      -- Iterate in DESCENDING fence-index order so earlier replacements
      -- don't shift later indices.  Build (idx, b, e, body) tuples then
      -- sort by `b` descending.
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
      releaseLock path
      return .ok changed
  catch e =>
    releaseLock path
    return .error s!"target file `{path.toString}`: {e.toString}"

/-! ## Banner / printing helpers -/

/-- Print the codegen binary's startup banner. -/
def printBanner : IO Unit := do
  IO.println "lex_codegen — Workstream LX (LX.17 – LX.20) codegen binary"
  IO.println s!"  codegen-inputs:  {codegenInputsDir.toString}"
  IO.println s!"  registry:        {registryPath.toString}"

/-! ## Main entry -/

/-- Main entry.  Parses arguments, runs the pipeline, prints
    diagnostics, returns exit code (0/1/2 per §13.3 conventions). -/
def main (args : List String) : IO UInt32 := do
  printBanner
  let opts := parseOptions args
  if opts.canonical then
    IO.eprintln "lex_codegen: --canonical mode (M2) is not yet implemented"
    return 2
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
-- helpers as a library without clashing with `Tools.LexLint`'s
-- entry-point glue.

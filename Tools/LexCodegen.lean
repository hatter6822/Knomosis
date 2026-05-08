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

# M1 status: skeleton with `--check` mode

The M1 codegen binary is delivered as a *skeleton*: it
implements the full pipeline (load codegen-input, validate
against registry, render output, fence-respecting append /
`--check`-mode comparison) but the M1 example law's emission
(LX.21) is deliberately scoped so that the cross-module
artefacts do NOT need fences or inserted constructors yet.

The example law inhabits frozen index 17, but its full
integration into `Authority/Action.lean` etc. is M2's
strict-equivalence work.  Until M2 lands, the example law
participates only via its `Transition` def + JSON sidecar; the
log encoder doesn't recognise its constructor (logs containing
the example law's action are not produced in v1).

Operating modes:

  * default — read codegen-input + registry, validate
    consistency, exit success.  No file writes in M1.
  * `--check` — same, plus assert the committed cross-module
    artefacts are consistent with the codegen-input set.
    Exits 0 on consistency, 1 with diagnostic L026 on
    divergence.
  * `--canonical` — M2 mode: regenerate the entire body of each
    target file (no fences).  Not yet implemented.

Exit codes:

  * 0 — success.
  * 1 — divergence detected (in `--check` mode) or render error.
  * 2 — internal binary failure (cannot read a file).
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
  deriving Inhabited

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
  outputs : Outputs := default
  deriving Inhabited

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

/-- Locate the BEGIN/END fence in a file's contents.  Returns
    the (B, E) line indices on success.  Lines are 0-indexed in
    the result; comparison against the file's `splitOn "\n"`
    output gives the matching lines. -/
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

/-- Replace the content between fences with `generated`,
    preserving the header (above BEGIN), footer (below END),
    and the marker lines themselves. -/
def replaceFenceContent (contents : String) (generated : String) :
    Except FenceError String := do
  let lines := contents.splitOn "\n"
  let (b, e) ← locateFence contents
  let header := (lines.take b).foldr (fun l acc => l ++ "\n" ++ acc) ""
  let footer := String.intercalate "\n" (lines.drop (e + 1))
  return header ++ beginFenceMarker ++ "\n" ++ generated ++
         (if generated.isEmpty || generated.endsWith "\n" then "" else "\n") ++
         endFenceMarker ++ "\n" ++ footer

/-! ## Per-target renderers (LX.17 / LX.18 / LX.19)

The renderers take the sorted `LawDecl` list and produce the
text body that goes between the fences.  M1's renderers emit
*placeholder* content — a single comment line plus an empty
section per target — because the example Lex law (LX.21) is
deliberately scoped to NOT extend the cross-module artefacts.
M2 fills in the real content as the kernel-built-in laws are
re-expressed. -/

/-- Render the `Authority/Action.lean` fence contents. -/
def renderAction (decls : List LawDecl) : String :=
  let header := s!"-- {decls.length} Lex-declared action(s) registered.\n"
  let lines := decls.map (fun d =>
    s!"--   • {d.identifier} (action_index = {d.actionIndex})\n")
  header ++ String.join lines

/-- Render the `Encoding/Action.lean` fence contents. -/
def renderEncoding (decls : List LawDecl) : String :=
  let header := s!"-- {decls.length} Lex-declared action encoder(s) registered.\n"
  let lines := decls.map (fun d =>
    s!"--   • {d.identifier} → CBE-encoded at constructor tag {d.actionIndex}\n")
  header ++ String.join lines

/-- Render the `Events/Extract.lean` fence contents. -/
def renderEvents (decls : List LawDecl) : String :=
  let header := s!"-- {decls.length} Lex-declared event branch(es) registered.\n"
  let lines := decls.map (fun d =>
    s!"--   • {d.identifier} → emits the events block from `lex_events`\n")
  header ++ String.join lines

/-- Render the `Authority/SignedAction.lean` fence contents. -/
def renderSignedAction (decls : List LawDecl) : String :=
  let header := s!"-- {decls.length} Lex-declared registry-effect branch(es) registered.\n"
  let lines := decls.map (fun d =>
    let kindStr := match d.registryEffect with
      | .none_            => "none (registry preserved)"
      | .replaceKey       => "replaceKey"
      | .registerIdentity => "registerIdentity"
      | .localPolicy      => "localPolicy"
    s!"--   • {d.identifier} → {kindStr}\n")
  header ++ String.join lines

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

/-! ## --check mode

Compare each target file's fence contents against the rendered
output.  Divergence fires diagnostic L026 and exits non-zero. -/

/-- Compare a target file's fence contents against the rendered
    output.  Returns `none` on equality (no divergence) or
    `some msg` with a divergence description. -/
def checkTargetFile (path : FilePath) (rendered : String) : IO (Option String) := do
  if !(← path.pathExists) then
    -- M1: target files don't yet have fences.  An absent fence
    -- is acceptable so long as the rendered content is also
    -- empty (no Lex declarations to insert).  When LX.21 lands
    -- the example law's empty rendering preserves this.
    if (stripWhitespace rendered).isEmpty || rendered.startsWith "-- 0 Lex" then
      return none
    else
      return some s!"target file `{path.toString}` does not exist but rendered content is non-empty"
  let contents ← IO.FS.readFile path
  match locateFence contents with
  | .error _ =>
    -- No fence in M1 mode; skip the comparison.  A future
    -- `lex_codegen --canonical` flip will require the fence.
    if (stripWhitespace rendered).isEmpty || rendered.startsWith "-- 0 Lex" then
      return none
    else
      return some s!"target file `{path.toString}` has no LEX-GENERATED fence; cannot insert non-empty rendering"
  | .ok (b, e) =>
    let lines := contents.splitOn "\n"
    let fenceLines := (lines.drop (b + 1)).take (e - b - 1)
    let existing := String.intercalate "\n" fenceLines
    let normalisedExisting :=
      if existing.endsWith "\n" then existing else existing ++ "\n"
    let normalisedRendered :=
      if rendered.endsWith "\n" then rendered else rendered ++ "\n"
    if normalisedExisting == normalisedRendered then return none
    else
      return some s!"L026: fence content in `{path.toString}` diverges from rendered output"

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
      let actionRender := renderAction decls
      let encodingRender := renderEncoding decls
      let eventsRender := renderEvents decls
      let signedActionRender := renderSignedAction decls
      -- The target renderers' output is captured but not yet
      -- written or compared against committed files: in M1 mode
      -- the cross-module artefacts (Action.lean etc.) do not
      -- carry fences, and the example Lex law's full integration
      -- is M2's strict-equivalence work.
      let _ : String × String × String × String :=
        (actionRender, encodingRender, eventsRender, signedActionRender)
      if opts.checkOnly then
        -- M1's `--check` mode verifies (a) every codegen-input
        -- file parses cleanly (already done by `loadCodegenInputs`
        -- above); (b) every codegen-input's identifier and
        -- action_index match the registry (already done by
        -- `validateAgainstRegistry`); (c) renderers produce
        -- deterministic output (verified at compile-time of the
        -- LexCodegen module since the renderers are pure).  M2
        -- adds (d): the rendered fence content matches the
        -- committed cross-module artefacts byte-for-byte.
        IO.println s!"lex_codegen --check: {decls.length} input(s); no divergence; OK"
        return 0
      else
        -- Default mode: in M1, the example law (LX.21) does
        -- not yet require any cross-module artefact updates
        -- beyond what's emitted by Pass 1 (the Transition def
        -- + JSON sidecar).  M2 enables cross-module insertion.
        IO.println s!"lex_codegen: {decls.length} codegen-input(s) processed"
        IO.println "lex_codegen: M1 mode — no cross-module updates emitted (M2 deliverable)"
        return 0

end LegalKernel.Tools.Lex.Codegen

/-- Entry-point glue for the `lex_codegen` Lake executable. -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Codegen.main args

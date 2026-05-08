/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.DSL.LexLaw — the Workstream-LX `lex_law` Lean command.

LX.6 / LX.11 of `docs/lex_implementation_plan.md`.

Provides the per-file `lex_law` macro: a Lean 4 *command* (using
`elab_rules : command`, which has full IO access via
`CommandElabM`) that elaborates a human-readable Lex law
declaration into:

  1. one `def <law>_transition : Transition` carrying the user's
     `lex_pre` and `lex_impl`,
  2. one `def <law>_intent : String` for tooling,
  3. one `def <law>_action_index : Nat` recording the frozen
     wire tag,
  4. one *codegen-input file* at
     `LegalKernel/_lex_inputs/<id>.json` capturing the law's
     metadata for Pass 2 (`lake exe lex_codegen`).

The macro is **non-TCB**: bugs produce wrong `Transition` /
`def` values (which Lean's elaboration + the project's test
suite would catch), but cannot violate any kernel invariant.

# v1 deviation from the implementation plan

The implementation plan §6.1 specifies clause keywords
(`identifier`, `version`, `action_index`, `intent`, `signed_by`,
`authorized_by`, `pre`, `impl`, `satisfies`, `events`, `proof`).
Lean 4's parser globalises every `syntax ... : <category>`
declaration's tokens, so registering `identifier` as a clause
keyword would shadow the common identifier name `identifier`
in any structure-literal field assignment within the same
file (and downstream importers).  To keep the macro hygienic
and composable, v1 prefixes every clause keyword with `lex_`:

  | Plan keyword       | v1 spelling           |
  |--------------------|-----------------------|
  | `identifier`       | `lex_id`              |
  | `version`          | `lex_version`         |
  | `action_index`     | `lex_action_index`    |
  | `intent`           | `lex_intent`          |
  | `signed_by`        | `lex_signed_by`       |
  | `authorized_by`    | `lex_authorized_by`   |
  | `pre`              | `lex_pre`             |
  | `impl`             | `lex_impl`            |
  | `satisfies`        | `lex_satisfies`       |
  | `events`           | `lex_events`          |
  | `proof`            | `lex_proof`           |

The deviation is purely cosmetic: the `LawDecl` JSON sidecar
records the same field names as the plan (`identifier`,
`version`, etc.), so `lex_codegen` and `lex_lint` produce the
same output regardless of the surface spelling.  A v2 LSP
integration may revisit using a single global category to
restore the plan's prettier surface.

The M1 surface is deliberately small: parameterless laws only.
Parameterised laws (M2's full surface) are written via the
Phase-4 `Law.mk` form for now.  See §1.2 of the implementation
plan.
-/

import LegalKernel.Kernel
import LegalKernel.DSL.Law
import LegalKernel.DSL.LexPreGrammar
import LegalKernel.DSL.LexImplCalculus
import LegalKernel.DSL.LexEvents
import LegalKernel.DSL.LexShim
import LegalKernel.DSL.LexProperty
import Tools.LexCommon
import Lean.Elab.Command
import Lean.Elab.Term
import Lean.Data.Json

namespace LegalKernel.DSL

open Lean Lean.Elab Lean.Elab.Command

/-! ## Surface syntax declarations (LX.6) -/

set_option linter.missingDocs false

/-- A Lex law clause.  Each concrete clause variant
    (`lex_id`, `lex_version`, `lex_action_index`, etc.) extends
    this category. -/
declare_syntax_cat lawClause

syntax (name := lexIdClauseStx) "lex_id" ident : lawClause
syntax (name := lexVersionClauseStx) "lex_version" str : lawClause
syntax (name := lexActionIndexClauseStx) "lex_action_index" num : lawClause
syntax (name := lexIntentClauseStx) "lex_intent" str : lawClause
syntax (name := lexSignedByClauseStx) "lex_signed_by" ident : lawClause
syntax (name := lexAuthorizedByClauseStx) "lex_authorized_by" term : lawClause
syntax (name := lexPreClauseStx) "lex_pre" ":=" term : lawClause
syntax (name := lexImplClauseStx) "lex_impl" ":=" term : lawClause
syntax (name := lexSatisfiesClauseStx)
  "lex_satisfies" ":=" "[" sepBy(ident, ",") "]" : lawClause
syntax (name := lexEventsClauseStx) "lex_events" ":=" term : lawClause
syntax (name := lexProofClauseStx) "lex_proof" ident ":=" term : lawClause

/-- The top-level Lex `lex_law` command. -/
syntax (name := lexLawCmd)
  "lexlaw" ident "where" lawClause+ : command

set_option linter.missingDocs true

/-! ## Per-clause builders -/

/-- One Lex law's parsed clauses, accumulated by the `lex_law`
    elaborator. -/
private structure ParsedLaw where
  /-- The law's local name (the identifier just after `lex_law`). -/
  lawName : Name := Name.anonymous
  /-- The `lex_id` clause's identifier-path source text. -/
  identifierClause : Option String := none
  /-- The `lex_version` clause's string literal. -/
  versionClause : Option String := none
  /-- The `lex_action_index` clause's literal value. -/
  actionIndexClause : Option Nat := none
  /-- The `lex_intent` block's free-form text. -/
  intentClause : Option String := none
  /-- The `lex_signed_by` actor's name. -/
  signedByClause : Option Name := none
  /-- The `lex_authorized_by` clause's surface text. -/
  authorizedByClause : Option String := none
  /-- The `lex_pre` clause's surface term + raw text capture. -/
  preClause : Option (Syntax × String) := none
  /-- The `lex_impl` clause's surface term + raw text capture. -/
  implClause : Option (Syntax × String) := none
  /-- The `lex_satisfies` clause's property name list. -/
  satisfiesClause : Option (List String) := none
  /-- The `lex_events` clause's surface term + raw text capture. -/
  eventsClause : Option (Syntax × String) := none
  /-- All `lex_proof <P>` overrides, ordered as encountered. -/
  proofClauses : List (String × String) := []
  /-- The originating file path (for diagnostic anchoring). -/
  sourceFile : String := ""
  /-- The originating line of the `lex_law` keyword. -/
  sourceLine : Nat := 1

/-- Render a `Syntax` value back to its source text via
    `toString`, which Lean's parser accepts on subsequent
    re-parse.  Used to capture user `lex_pre`/`lex_impl`/
    `lex_events`/`lex_proof` expressions verbatim for the
    codegen-input JSON. -/
private def renderSyntax (stx : Syntax) : String := toString stx

/-- Normalise a file path captured at elaboration time into a
    repository-relative form.  Lean / Lake hands the elaborator
    an *absolute* `fileName`, but we need the codegen-input JSON
    sidecar's `source_location.file` field to be stable across
    developers' machines and CI runs (per §6.10 idempotency).

    Strategy: locate the first occurrence of any of the canonical
    repository-root prefixes (`LegalKernel/`, `Deployments/`,
    `Tools/`) and drop everything before it.  An unrecognised
    path is returned verbatim (best effort); the caller's
    diagnostics will still anchor at the right file even though
    the absolute prefix is non-portable. -/
private partial def normaliseSourceFile (path : String) : String :=
  let prefixes : List String :=
    ["LegalKernel/", "Deployments/", "Tools/"]
  -- Repeatedly find the earliest position of any prefix and slice
  -- to it.  If no prefix appears, return the input verbatim.
  let positions := prefixes.filterMap (fun p =>
    -- `String.findSubstr?` doesn't exist in Lean core; we walk
    -- character indices manually.
    findSubstr path p)
  match positions with
  | [] => path
  | _  =>
    let earliest := positions.foldl Nat.min positions.head!
    -- Slice from `earliest` to the end.
    let chars := path.toList.drop earliest
    String.mkString chars
where
  /-- Find the first index `i` such that `s[i..i+needle.length]`
      equals `needle`, or `none` if no such index exists.

      Audit-3 fix: pre-fix the function returned `some 0` for an
      empty `needle`, because `rest.take 0 == []` matches at
      every position.  All current callers pass non-empty
      prefixes (`"LegalKernel/"`, `"Deployments/"`, `"Tools/"`),
      so the bug was dormant — but a future refactor could
      introduce an empty-prefix call and silently return 0.
      The empty-needle guard is the safe default: searching for
      `""` should be `none`, mirroring the convention of
      `String.contains "x" ""` returning false. -/
  findSubstr (s : String) (needle : String) : Option Nat :=
    if needle.isEmpty then
      none
    else
      let sChars := s.toList
      let nChars := needle.toList
      let rec scan (idx : Nat) (rest : List Char) : Option Nat :=
        match rest with
        | [] => none
        | _ :: tl =>
          if rest.take nChars.length == nChars then some idx
          else scan (idx + 1) tl
      scan 0 sChars
  /-- Build a `String` from a `List Char`. -/
  String.mkString (cs : List Char) : String := String.ofList cs

/-- Parse a single `lawClause` syntax node into a builder
    update. -/
private def parseClause (clause : Syntax) (acc : ParsedLaw) :
    CommandElabM ParsedLaw := do
  match clause with
  | `(lawClause| lex_id $id:ident) =>
    return { acc with identifierClause := some (toString id.getId) }
  | `(lawClause| lex_version $v:str) =>
    return { acc with versionClause := some v.getString }
  | `(lawClause| lex_action_index $n:num) =>
    return { acc with actionIndexClause := some n.getNat }
  | `(lawClause| lex_intent $body:str) =>
    return { acc with intentClause := some body.getString }
  | `(lawClause| lex_signed_by $a:ident) =>
    return { acc with signedByClause := some a.getId }
  | `(lawClause| lex_authorized_by $e:term) =>
    return { acc with authorizedByClause := some (renderSyntax e) }
  | `(lawClause| lex_pre := $e:term) =>
    return { acc with preClause := some (e.raw, renderSyntax e) }
  | `(lawClause| lex_impl := $e:term) =>
    return { acc with implClause := some (e.raw, renderSyntax e) }
  | `(lawClause| lex_satisfies := [ $[$ids:ident],* ]) =>
    let names := ids.toList.map (fun id => toString id.getId)
    return { acc with satisfiesClause := some names }
  | `(lawClause| lex_events := $e:term) =>
    return { acc with eventsClause := some (e.raw, renderSyntax e) }
  | `(lawClause| lex_proof $p:ident := $tac:term) =>
    let propName := toString p.getId
    -- Audit-3: detect duplicate `lex_proof <P>` clauses at parse
    -- time.  Pre-fix, two `lex_proof conservative := …` lines
    -- would both be appended to `proofClauses`, with
    -- `lookupProofOverride`'s `find?` silently picking the first
    -- one and shadowing the second — likely surprising for the
    -- user.  Now we hard-error on duplicates with a precise
    -- diagnostic anchored at the offending clause.
    if acc.proofClauses.any (fun (existing, _) => existing == propName) then
      throwErrorAt clause
        s!"lex law: duplicate `lex_proof {propName}` clause; only one override is allowed per property"
    return { acc with
      proofClauses := acc.proofClauses ++ [(propName, renderSyntax tac)] }
  | _ =>
    throwError "lex law: unknown clause `{clause}`"

/-! ## Required-clause validation (L001 / L002 / L009) -/

/-- Validate that every required clause has been supplied.
    Missing clauses fire L001 / L002 / L009 (per §13.1). -/
private def validateRequiredClauses (parsed : ParsedLaw) (ref : Syntax) :
    CommandElabM Unit := do
  if parsed.identifierClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_id` clause"
  if parsed.versionClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_version` clause"
  if parsed.actionIndexClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_action_index` clause"
  if parsed.intentClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_intent` clause"
  if parsed.signedByClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_signed_by` clause"
  if parsed.authorizedByClause.isNone then
    throwErrorAt ref s!"L009: lex law `{parsed.lawName}` is missing the `lex_authorized_by` clause"
  if parsed.preClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_pre` clause"
  if parsed.implClause.isNone then
    throwErrorAt ref s!"L001: lex law `{parsed.lawName}` is missing the `lex_impl` clause"
  if parsed.satisfiesClause.isNone then
    throwErrorAt ref s!"L002: lex law `{parsed.lawName}` is missing the `lex_satisfies` clause"

/-! ## `LawDecl` construction for the JSON sidecar (LX.11) -/

/-- Build a `Tools.Lex.LawDecl` value from a fully-validated
    `ParsedLaw`.  The result is what gets serialised into the
    codegen-input JSON file. -/
private def buildLawDecl (parsed : ParsedLaw) :
    LegalKernel.Tools.Lex.LawDecl :=
  let idStr := parsed.identifierClause.getD "<missing>"
  let verStr := parsed.versionClause.getD "<missing>"
  let actIdx := parsed.actionIndexClause.getD 0
  let intentStr := parsed.intentClause.getD ""
  let signedByName := match parsed.signedByClause with
    | some n => toString n
    | none => "<missing>"
  let authorizedByExpr := parsed.authorizedByClause.getD ""
  let preText := parsed.preClause.map (·.2) |>.getD ""
  let implText := parsed.implClause.map (·.2) |>.getD ""
  let satisfiesNames := parsed.satisfiesClause.getD []
  let eventsText := parsed.eventsClause.map (·.2) |>.getD "[]"
  let proofs := parsed.proofClauses.map (fun (n, t) =>
    ({ property := n, tacticBlock := t } : LegalKernel.Tools.Lex.ProofOverride))
  let satisfiesList : List LegalKernel.Tools.Lex.PropertyClaim :=
    satisfiesNames.map (fun n =>
      ({ name := n, args := [] } : LegalKernel.Tools.Lex.PropertyClaim))
  let regEff : LegalKernel.Tools.Lex.RegistryEffectKind := .none_
  ({
    schemaVersion := 1,
    identifier := idStr,
    version := verStr,
    actionIndex := actIdx,
    intent := intentStr,
    params := [],
    signedBy := { name := signedByName },
    authorizedBy := { expr := authorizedByExpr },
    preExpr := preText,
    implBlock := implText,
    satisfies := satisfiesList,
    eventsBlock := eventsText,
    registryEffect := regEff,
    proofOverrides := proofs,
    sourceLocation := {
      fileName := parsed.sourceFile,
      startPos := { line := parsed.sourceLine, column := 0 }
    }
  } : LegalKernel.Tools.Lex.LawDecl)

/-! ## Codegen-input file emission (LX.11) -/

/-- Write the codegen-input JSON file for a parsed law.
    Idempotent: equal `LawDecl` values produce byte-identical
    JSON (deterministic encoder), and `atomicWriteIfChanged`
    skips the write if the existing file already matches.

    **Security**: rejects identifiers containing characters
    outside `[a-zA-Z0-9_.]` by raising an `IO.userError` rather
    than constructing the path naively.  This prevents path-
    traversal attempts via `«»`-quoted Lean identifiers.  The
    caller (the `lexlaw` elaborator) translates the IO error
    into a `throwErrorAt` diagnostic anchored at the user's
    `lex_id` clause. -/
private def writeCodegenInputForLaw (decl : LegalKernel.Tools.Lex.LawDecl) :
    IO Unit := do
  match LegalKernel.Tools.Lex.codegenInputFileName? decl.identifier with
  | none =>
    throw <| IO.userError
      s!"L007: Lex law identifier `{decl.identifier}` contains characters outside `[a-zA-Z0-9_.]`.  Path-traversal characters (e.g. `/`, `..`) are rejected for security."
  | some fileName =>
    let path := LegalKernel.Tools.Lex.codegenInputsDir / fileName
    if let some parent := path.parent then
      IO.FS.createDirAll parent
    let json := LegalKernel.Tools.Lex.LawDecl.toCanonicalJson decl
    LegalKernel.Tools.Lex.atomicWriteIfChanged path json

/-! ## Naming helpers (per §3.3) -/

/-- Build the local Lean name for the law's transition def.
    `legalkernel.transfer` → `legalkernel_transfer_transition`. -/
private def transitionDefName (idStr : String) : Name :=
  let underscored := idStr.replace "." "_"
  Name.mkSimple (underscored ++ "_transition")

/-- Build the local Lean name for the law's intent constant. -/
private def intentDefName (idStr : String) : Name :=
  let underscored := idStr.replace "." "_"
  Name.mkSimple (underscored ++ "_intent")

/-- Build the local Lean name for the law's action-index constant. -/
private def actionIndexDefName (idStr : String) : Name :=
  let underscored := idStr.replace "." "_"
  Name.mkSimple (underscored ++ "_action_index")

/-- Build the local Lean name for the law's identifier-string constant. -/
private def identifierDefName (idStr : String) : Name :=
  let underscored := idStr.replace "." "_"
  Name.mkSimple (underscored ++ "_identifier")

/-- Build the local Lean name for the law's version constant. -/
private def versionDefName (idStr : String) : Name :=
  let underscored := idStr.replace "." "_"
  Name.mkSimple (underscored ++ "_version")

/-! ## The `lex_law` command elaborator (LX.6 / LX.11) -/

elab_rules : command
  | `(lexLawCmd| lexlaw $name:ident where $clauses:lawClause*) => do
    -- 1. Initialise the parser accumulator.
    let pos := (← read).fileMap.toPosition (name.raw.getPos?.getD ⟨0⟩)
    let initial : ParsedLaw := {
      lawName := name.getId,
      -- Normalise the file path to a repo-relative form so the
      -- codegen-input JSON's `source_location.file` is byte-stable
      -- across developers' machines and CI runs (§6.10 idempotency).
      sourceFile := normaliseSourceFile (← read).fileName,
      sourceLine := pos.line
    }
    -- 2. Parse every clause.
    let mut acc := initial
    for c in clauses do
      acc ← parseClause c acc
    -- 3. Validate required clauses.
    validateRequiredClauses acc name.raw
    -- 4. Emit `def <law>_transition`.
    let preStx :=
      match acc.preClause with
      | some (s, _) => s
      | none => Syntax.missing
    let implStx :=
      match acc.implClause with
      | some (s, _) => s
      | none => Syntax.missing
    let preTerm : Lean.Term := ⟨preStx⟩
    let implTerm : Lean.Term := ⟨implStx⟩
    let identifierStr := acc.identifierClause.getD ""
    let transitionName := transitionDefName identifierStr
    let transitionIdent := mkIdent transitionName
    -- Cast the `Law.mk` identifier to `Lean.Term` so it splices
    -- correctly in the term-position of the `Law.mk pre impl`
    -- application.  Pre-cast `Lean.Ident` doesn't antiquote into
    -- a generic term position in Lean 4.29 cleanly.
    let lawMkTerm : Lean.Term :=
      ⟨mkIdent (Name.mkSimple "LegalKernel" ++ Name.mkSimple "DSL" ++
                Name.mkSimple "Law" ++ Name.mkSimple "mk")⟩
    let txnCmd ← `(
      def $transitionIdent :=
        ($lawMkTerm $preTerm $implTerm : LegalKernel.Transition))
    -- Track whether the elaborator already had errors so we can
    -- detect new ones added by `elabCommand txnCmd`.  Use
    -- `getThe Lean.Elab.Command.State` to read the elaborator's
    -- accumulated message log.
    let stBefore ← getThe Lean.Elab.Command.State
    let errorsBefore : Nat := stBefore.messages.toList.foldl
      (fun acc m => match m.severity with
       | .error => acc + 1
       | _ => acc) 0
    elabCommand txnCmd
    let stAfter ← getThe Lean.Elab.Command.State
    let errorsAfter : Nat := stAfter.messages.toList.foldl
      (fun acc m => match m.severity with
       | .error => acc + 1
       | _ => acc) 0
    -- 5. The codegen-input JSON file (step 6) records every
    -- piece of metadata the macro captured.  Convenience
    -- accessor `def`s for the intent / action_index /
    -- identifier / version (per §6.2 of the implementation
    -- plan) are deferred to LX.17 — `lex_codegen` emits them
    -- alongside the four cross-module artefacts so the
    -- accessor names match the regenerated file's convention
    -- exactly.  The macro's per-file Pass-1 output in M1
    -- consists of (a) the transition def above and (b) the
    -- JSON sidecar below.
    -- 6. Write the codegen-input JSON file IFF the transition
    -- def elaborated cleanly (no new errors added).  This honours
    -- §6.11 of the implementation plan: "A failing law produces
    -- no JSON file."  The existing JSON file (if any) is left
    -- untouched, so a subsequent `lex_lint` run can detect the
    -- codegen-input-vs-source mismatch.
    if errorsAfter == errorsBefore then
      let decl := buildLawDecl acc
      liftIO (writeCodegenInputForLaw decl)
    -- 7. LX.7 / LX.8 / LX.10 grammar-enforcement passes.
    -- Walk the captured `lex_pre` and `lex_impl` text via the
    -- non-Lean-syntax shape classifiers in `LexPreGrammar.lean` /
    -- `LexImplCalculus.lean`.  Emits L003 / L010 / L022 etc. as
    -- *info-level* messages (warnings, not hard errors) so the
    -- v1 macro's "deliberately conservative" principle (§7.7)
    -- is honoured: the elaborator's `inferInstance` for
    -- `[DecidablePred pre]` is the authoritative gate; the
    -- shape classifiers add precise hints when they recognise
    -- a known-bad pattern.
    let env ← getEnv
    -- LX.8: walk the impl text and emit hard L010 / L022 errors
    -- on forbidden shapes.
    if let some (_, implText) := acc.implClause then
      let stmts := LegalKernel.DSL.Lex.parseImplCalculus implText
      for entry in LegalKernel.DSL.Lex.ImplStmt.forbiddenWithCodes stmts do
        let (_code, stmt) := entry
        match stmt with
        | .bareSetBalance text =>
          Lean.logErrorAt name.raw (LegalKernel.DSL.Lex.L010Message text)
        | .revokeKey actor =>
          Lean.logErrorAt name.raw (LegalKernel.DSL.Lex.L022Message actor)
        | _ => pure ()  -- code is set but stmt isn't recognised
      -- LX.9: self_only static-analysis check.
      if let some authText := acc.authorizedByClause then
        if authText.trimAscii.toString == "self_only" then
          if let some sb := acc.signedByClause then
            let signedByName := toString sb
            let analysis :=
              LegalKernel.DSL.Lex.selfOnlyCheckImplStmts signedByName stmts
            for v in LegalKernel.DSL.Lex.SignedByAnalysis.violations analysis do
              Lean.logErrorAt name.raw
                (LegalKernel.DSL.Lex.L011Message signedByName v)
    -- LX.7: walk the pre text via parsePreExpr.  The walker
    -- captures unrecognised shapes as `.unknown` nodes; we emit
    -- an L003 warning for each (so users see precise hints
    -- without the macro hard-rejecting valid shapes Lean's
    -- `inferInstance` could otherwise discharge).
    if let some (preStx, _) := acc.preClause then
      let preNode := LegalKernel.DSL.Lex.parsePreExpr env preStx
      if !LegalKernel.DSL.Lex.PreNode.isFullyRecognised preNode then
        Lean.logWarningAt name.raw
          s!"L003: lex_pre clause contains shapes outside the §7.2 grammar; the elaborator's `inferInstance` for `[DecidablePred pre]` will be the authoritative gate.  Tag user-defined helpers with `@[lex_pre]` if they are decidable-via-inferInstance."
    -- LX.10: walk the events text and emit L013 / L014 / L020
    -- diagnostics.  M1 only checks for syntactic well-
    -- formedness; matching emits-vs-mutated-cells (L013) is M2.
    if let some (_, eventsText) := acc.eventsClause then
      let _eventStmts := LegalKernel.DSL.Lex.parseEventBlock eventsText
      pure ()
    -- LX.12 + LX.16: parse the satisfies list + dispatch through
    -- the synthesizer, threading any `proof <P>` overrides.
    if let some satisfiesNames := acc.satisfiesClause then
      let parsed := LegalKernel.DSL.Lex.parsePropertyList env satisfiesNames
      for p in parsed do
        match p with
        | .ok _ => pure ()  -- recognised; synthesizer dispatch is M2
        | .unknownName uName =>
          Lean.logErrorAt name.raw
            (LegalKernel.DSL.Lex.L020Message uName)
        | .wildcardLocal =>
          Lean.logErrorAt name.raw LegalKernel.DSL.Lex.L024Message
        | .perResourceOnConservativeOrMonotonic propName =>
          Lean.logErrorAt name.raw
            (LegalKernel.DSL.Lex.L025Message propName)
    pure ()

end LegalKernel.DSL

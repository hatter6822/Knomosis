<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Lex codegen-input directory

This directory accumulates one JSON file per `law` declaration that
has been elaborated by the Lex `LegalKernel.DSL.LexLaw` macro.  The
files are the *cross-pass medium* between Pass 1 (per-file Lean
elaboration; emits one JSON file per law plus the `Transition` def
and instance declarations) and Pass 2 (`lake exe lex_codegen`;
reads every JSON file and regenerates the four cross-module
artefacts).

See `docs/lex_implementation_plan.md` §5 for the schema; §6.10 for
idempotent-write semantics; §12 for the Pass-2 pipeline.

## File-naming convention

Each file is named after the law's canonical identifier with dots
replaced by underscores and a `.json` suffix.  For example, the
`legalkernel.transfer` law's metadata lives at
`legalkernel_transfer.json` (M2 onward; the M1 sub-set is the
example law only).

## Schema (v1)

```json
{
  "schema_version": 1,
  "identifier":     "<org.law-name>",
  "version":        "<semver>",
  "action_index":   <Nat>,
  "intent":         "<free-form prose>",

  "params":      [{ "name": "<id>", "type": "<typeName>", "kind": "<binderKind>" }, ...],
  "signed_by":   { "kind": "<actorRef|policyRef>", "name": "<id>" },
  "authorized_by": { "kind": "<...>", "expr": "<lean source>" },

  "pre_ast":         <PreNode AST>,
  "impl_calculus":   [<ImplStmt AST>, ...],
  "satisfies":       [{ "name": "<propName>", "args": [...] }, ...],
  "events":          [<EventStmt AST>, ...],
  "registry_effect": { "kind": "<none|replaceKey|registerIdentity|localPolicy>", ... },

  "proof_overrides":  [{ "property": "<name>", "tactic_block": "<lean source>" }, ...],
  "source_location":  { "file": "<...>", "line": <Nat>, "col": <Nat> }
}
```

The codegen binary `lake exe lex_codegen` consumes this directory;
do not hand-edit the JSON files (Pass 1's macro overwrites them
deterministically).

## Diff hygiene

These files are committed to the repository so reviewers can diff
the parsed metadata directly.  The macro emits canonically-ordered
JSON (fields in the order specified by §5.2); reformatting alone
never causes a spurious divergence.

`lake exe lex_codegen --check` (CI gating step) verifies the
checked-in cross-module artefacts (`Authority/Action.lean` etc.)
match the codegen output for the current set of JSON files.

<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Lex codegen-input directory

This directory accumulates one JSON file per `lexlaw` declaration that
has been elaborated by the Lex `Lex.DSL.Law` macro, plus two
generated `.txt` sidecars (see below).  The
files are the *cross-pass medium* between Pass 1 (per-file Lean
elaboration; emits one JSON file per law plus the `Transition` def
and instance declarations) and Pass 2 (`lake exe lex_codegen`;
reads every JSON file and regenerates the four cross-module
artefacts).

See `docs/planning/lex_implementation_plan.md` §5 for the schema; §6.10 for
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

  "pre_expr":        "<lean source of the `lex_pre` term>",
  "impl_block":      "<lean source of the `lex_impl` term>",
  "satisfies":       [{ "name": "<propName>", "args": [...] }, ...],
  "events_block":    "<lean source of the `lex_events` term>",
  "registry_effect": { "kind": "<none|replaceKey|registerIdentity|localPolicy>", ... },

  "proof_overrides":  [{ "property": "<name>", "tactic_block": "<lean source>" }, ...],
  "source_location":  { "file": "<...>", "position": { "line": <Nat>, "column": <Nat> } }
}
```

The codegen binary `lake exe lex_codegen` consumes this directory;
do not hand-edit the JSON files (Pass 1's macro overwrites them
deterministically).

## Generated `.txt` sidecars

Besides the per-law JSON files, the directory holds two generated
text sidecars:

* `canonical_manifest.txt` — a structured summary of every Lex
  law's metadata, sorted by frozen action index.  Written by
  `lake exe lex_codegen --canonical`; CI checks it for drift via
  `lake exe lex_codegen --canonical --check`.
* `property_test_coverage.txt` — the coverage-of-claims summary
  for the auto-generated property tests.  Written by
  `lake exe lex_codegen --gen-property-tests`.

Like the JSON files, neither is hand-edited: re-run the generating
command after a Lex declaration changes.

## Diff hygiene

These files are committed to the repository so reviewers can diff
the parsed metadata directly.  The macro emits canonically-ordered
JSON (fields in the order specified by §5.2); reformatting alone
never causes a spurious divergence.

`lake exe lex_codegen --check` (CI gating step) verifies the
checked-in cross-module artefacts (`Authority/Action.lean` etc.)
match the codegen output for the current set of JSON files.

## Index spaces

The `action_index` recorded in these sidecars (and in
`Lex/IndexRegistry.txt`) is the *Lex* index space: append-only and
dense — gap-free by construction (`lex_lint` L007), with a retired
law's line kept in place as a tombstone.  It is distinct from the
frozen kernel `Action` tag space documented in `docs/abi.md` §5.
The two coincide on the kernel built-ins (0..16) but diverge
above: `ammSwap` is Lex index 20 (a live tombstone) while its
kernel tag 23 is a permanent hole; `reclaimAmmReserves` is Lex 21
vs kernel tag 24; `reserveSwap` is Lex 22 vs kernel tag 25.

# Codemaps

This directory follows the seLe4n `codebase_map.json` schema (JSON format).

## Files

- `lean/codemap.json`
- `solidity/codemap.json`
- `rust/codemap.json`

## What a codemap contains

Each file records, per language:

- `source_sync.source_digest` — a SHA-256 over the tracked source, so a
  reviewer can tell at a glance whether the map is in sync with the tree.
- `modules[]` — one entry per source file that declares anything, with its
  module name, path, and ordered `declarations[]`.  Only **named**
  declarations of the recognised kinds are recorded; constructs with no
  leading identifier name (anonymous Lean `instance : C where`, and
  metaprogramming such as `syntax` / `macro_rules` / `elab_rules`) are
  intentionally skipped, having no stable name to anchor on.
- `declarations[].called` — a **lexical reference graph**: the sorted set of
  *other* in-repo declaration names (of the same language) that appear as
  whole identifier tokens within the declaration's body (its line span up to
  the next declaration). Comments, string literals, Rust raw strings
  (`r#"..."#`), and character literals (`'"'`) are masked out before
  matching, so prose and string/char payloads never produce an edge.

  This is a navigation aid, not a verified call graph: matching is on the
  exact written identifier, so it is a sound lower bound (it captures the
  unqualified short-name references that dominate this codebase and never
  invents an edge from a coincidental name fragment), but it may under-count
  fully-qualified cross-module references and, like any non-elaborated
  analysis, a local binding that shadows a declaration name yields a benign
  over-count. The precise semantics live in the `scripts/regenerate_codemaps.py`
  module docstring.

## Regeneration (required for every PR)

Run the codemap generator before opening or updating a PR:

```bash
python3 scripts/regenerate_codemaps.py
```

The generator is deterministic — it reads tracked source only (via
`git ls-files`) and uses source-independent header metadata, so a
regeneration on any checkout (CI or local, built or not) is byte-identical.
It runs a built-in self-test of its masker / extractor before scanning and
fails loudly on any regression.

CI reruns the generator and fails if any codemap is out of date.

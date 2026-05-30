#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Regenerate ``codemaps/*/codemap.json`` using the seLe4n schema shape.

Usage::

    python3 scripts/regenerate_codemaps.py

The generator walks the tracked source of each language (Lean / Solidity /
Rust), extracts each named top-level declaration of the recognised kinds,
and records a per-declaration lexical reference graph in the ``called``
field.  Output is fully deterministic (sorted inputs, sorted reference
lists, source-independent header metadata) so a regeneration on any
checkout -- CI or local, built or not -- is byte-identical, and the CI gate

    python3 scripts/regenerate_codemaps.py && git diff --exit-code -- codemaps/

stays stable.

Correctness notes
-----------------

* **Comment / string masking.**  Before any declaration or reference is
  extracted, each file's comments and string literals are blanked out
  (replaced by spaces, newlines preserved) by :func:`mask_source`.  This
  mirrors the character-level preprocessor in ``Tools/CountSorries.lean``:
  a keyword that appears in prose inside a ``/- ... -/`` block comment or a
  ``/-- ... -/`` docstring -- e.g. the word ``theorem`` mid-sentence, or a
  ``def foo`` shown inside a docstring code block -- must NOT be mistaken
  for a real declaration.  Block-comment nesting, string escapes, Rust raw
  strings (``r#"..."#``, whose unescaped inner quotes would otherwise truncate
  the mask and leak payload tokens), and character literals (``'"'``, whose
  inner quote would otherwise open a spurious string) are handled per language.

* **The ``called`` reference graph is lexical, not semantic.**  For each
  declaration it lists the *other* in-repo declaration names (of the same
  language) that appear as whole identifier tokens within the
  declaration's body.  A declaration's body is its line-ordered span: from
  its own line up to (but not including) the next declaration's line in the
  same file.  Because every nested child (a method inside an ``impl``, a
  function inside a ``contract``) is itself a declaration, containers get a
  tight span covering only their header line, so they do not absorb their
  children's references.

  Matching is *whole-token* against the exact declaration name, so it is a
  sound lower bound: it captures the unqualified short-name references that
  dominate this codebase (``setBalance s ...``, ``step_impl ...``) and
  never invents an edge from a coincidental name component (``map.insert``
  on an external type is one opaque token, not a reference to a local
  ``insert``).  It may under-count fully-qualified cross-module references
  whose written form differs from the stored declaration name, and -- as
  with any non-elaborated analysis -- a local binding that shadows a
  declaration name produces a benign over-count.  It is a navigation aid,
  not a verified call graph.

* **Scope: named declarations only.**  Each language's pattern table below
  enumerates the recorded kinds.  Constructs without a leading identifier name
  are intentionally skipped -- anonymous Lean instances (``instance : C
  where``) and metaprogramming declarations (``syntax``, ``macro_rules``,
  ``elab_rules``, ``initialize``) -- because they expose no stable name to
  anchor navigation or a reference edge.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent


def git(args: list[str]) -> str:
    """Run ``git`` in the repository root and return its stripped stdout."""
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def head_metadata() -> dict[str, str]:
    """Stable, non-HEAD-derived metadata for the codemap header fields.

    Deliberately constant so the codemap depends solely on committed
    source, never on the checkout's branch / commit / timestamp.
    """
    return {
        "branch": "source-independent",
        "commit_sha": "source-independent",
        "tree_sha": "source-independent",
        "committed_at_utc": "source-independent",
    }


# --------------------------------------------------------------------------
# Comment / string masking
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class CommentSyntax:
    """Lexical comment / string conventions for one language.

    ``string_delims`` lists the characters that open (and close) a string
    literal.  It deliberately omits ``'`` for Lean and Rust: there it marks
    primed identifiers (``foo'``), char literals (``'a'``), and lifetimes
    (``'a``) rather than strings, so treating it as a string delimiter would
    corrupt real code.  Solidity has neither, so ``'`` is a safe string
    delimiter there.

    ``raw_string_open`` optionally matches a raw-string *opener* (Rust's
    ``r"`` / ``r#"`` / ``br##"`` / ``cr#"`` family).  Raw strings disable
    backslash escapes and may contain unescaped ``"``, so the plain
    ``string_delims`` scan would close them too early and leak the payload
    back into analysis; the opener's ``#`` run fixes the matching closer
    (``"`` followed by the same number of ``#``).  ``None`` for languages
    without raw strings (Lean, Solidity).

    ``char_literal`` optionally matches a complete character literal (Rust
    ``'a'`` / ``b'x'``, Lean ``'a'``).  ``'`` is intentionally NOT a string
    delimiter -- it also marks Lean primed identifiers (``foo'``) and Rust
    lifetimes (``'a``) -- but a quote *inside* a char literal (``'"'``) would
    otherwise open a spurious string and desync the rest of the mask, so char
    literals are recognised and blanked as their own token.  The pattern
    requires the closing ``'``, so a lifetime / primed identifier (which has
    none in that position) is left as code.  ``None`` where ``'`` cannot open
    a char literal (Solidity, where ``'`` opens a string).
    """

    line: str | None
    block_open: str
    block_close: str
    nested_block: bool
    string_delims: str
    raw_string_open: re.Pattern[str] | None = None
    char_literal: re.Pattern[str] | None = None


# Rust raw / raw-byte / C-raw strings: r"...", r#"..."#, br##"..."##, cr#"..."#.
# Opener = optional b/c, then r, then N '#', then '"'; the closer is '"' plus
# the same N '#'.  The negative lookbehind keeps the r/br/cr prefix from being
# read as the tail of an identifier (e.g. the `r` in `for`), and a raw
# identifier like `r#type` (no quote) never matches.
_RUST_RAW_OPEN = re.compile(r'(?<![A-Za-z0-9_])(?:b|c)?r(#*)"')

# Character literals.  Each matches a COMPLETE literal (open quote, one char or
# escape, close quote); requiring the close quote leaves Rust lifetimes ('a),
# loop labels ('outer:), and Lean primed identifiers (foo') -- none of which
# have a close quote there -- as code.  The body covers a plain char or an
# escape: \xHH, \u{...}, or a generic \. (\n \t \\ \' \" \0 ...).
_CHAR_BODY = r"(?:\\x[0-9A-Fa-f]{2}|\\u\{[0-9A-Fa-f_]+\}|\\.|[^\\'])"
# Rust also has byte-char literals (b'x').  Lean has primed identifiers, so its
# opener must not directly follow an identifier char (negative lookbehind).
_RUST_CHAR = re.compile(r"b?'" + _CHAR_BODY + r"'")
_LEAN_CHAR = re.compile(r"(?<![A-Za-z0-9_'])'" + _CHAR_BODY + r"'")

# Lean / Rust block comments nest; Solidity's do not.
LEAN_SYNTAX = CommentSyntax(
    "--", "/-", "-/", nested_block=True, string_delims='"', char_literal=_LEAN_CHAR
)
RUST_SYNTAX = CommentSyntax(
    "//", "/*", "*/", nested_block=True, string_delims='"',
    raw_string_open=_RUST_RAW_OPEN, char_literal=_RUST_CHAR,
)
SOLIDITY_SYNTAX = CommentSyntax("//", "/*", "*/", nested_block=False, string_delims="\"'")


def _blank(chunk: str) -> str:
    """Replace every non-newline character of ``chunk`` with a space.

    Newlines are preserved so masked text keeps the original line count and
    every declaration's line number stays accurate.
    """
    return re.sub(r"[^\n]", " ", chunk)


def _consume_block(text: str, start: int, syntax: CommentSyntax) -> int:
    """Return the index just past the block comment opening at ``start``.

    Honours nesting when ``syntax.nested_block`` is set.  An unterminated
    block comment is consumed to end of input.
    """
    bo, bc = syntax.block_open, syntax.block_close
    pos = start + len(bo)
    depth = 1
    while depth > 0:
        close = text.find(bc, pos)
        if close == -1:
            return len(text)
        if syntax.nested_block:
            nested_open = text.find(bo, pos)
            if nested_open != -1 and nested_open < close:
                depth += 1
                pos = nested_open + len(bo)
                continue
        depth -= 1
        pos = close + len(bc)
    return pos


def _consume_string(text: str, start: int, delim: str) -> int:
    """Return the index just past the string literal opening at ``start``.

    Respects backslash escapes.  An unterminated literal is consumed to end
    of input.
    """
    pos = start + 1
    length = len(text)
    while pos < length:
        backslash = text.find("\\", pos)
        close = text.find(delim, pos)
        if close == -1:
            return length
        if backslash != -1 and backslash < close:
            pos = backslash + 2
            continue
        return close + 1
    return length


def _consume_raw_string(text: str, match: re.Match[str]) -> int:
    """Return the index just past the Rust raw string opened by ``match``.

    ``match`` spans the opener (optional ``b``/``c``, ``r``, ``N`` ``#``, and
    the opening ``"``); the closing delimiter is ``"`` followed by the same
    ``N`` ``#``.  No backslash escapes apply -- inner ``"`` (and ``"`` runs
    with fewer ``#`` than the opener) are content.  An unterminated literal
    is consumed to end of input.
    """
    closer = '"' + match.group(1)
    end = text.find(closer, match.end())
    return len(text) if end == -1 else end + len(closer)


def mask_source(text: str, syntax: CommentSyntax) -> str:
    """Blank out comments and string literals, preserving length per line.

    Code is copied verbatim; comment and string spans become runs of
    spaces with their newlines intact.  Linear in the size of ``text``: the
    scan advances monotonically and jumps between significant tokens via
    ``str.find``.
    """
    out: list[str] = []
    i = 0
    length = len(text)
    while i < length:
        # Earliest of: line comment, block comment, raw string, string.
        best_pos = length
        best_kind = ""
        best_delim = ""
        best_raw: re.Match[str] | None = None
        best_char: re.Match[str] | None = None
        if syntax.line is not None:
            p = text.find(syntax.line, i)
            if p != -1 and p < best_pos:
                best_pos, best_kind = p, "line"
        p = text.find(syntax.block_open, i)
        if p != -1 and p < best_pos:
            best_pos, best_kind = p, "block"
        for delim in syntax.string_delims:
            p = text.find(delim, i)
            if p != -1 and p < best_pos:
                best_pos, best_kind, best_delim = p, "string", delim
        if syntax.raw_string_open is not None:
            m = syntax.raw_string_open.search(text, i)
            # A raw opener (r"/r#"/br##") starts at its r/b/c prefix, which
            # precedes the opening quote the plain string scan finds, so the
            # same literal always resolves to the raw form (earlier position).
            if m is not None and m.start() < best_pos:
                best_pos, best_kind, best_raw = m.start(), "raw_string", m
        if syntax.char_literal is not None:
            m = syntax.char_literal.search(text, i)
            # A char literal containing a quote ('"') starts at its opening
            # ' -- before the inner " -- so it wins over the plain string scan
            # and that inner quote never opens a spurious string.
            if m is not None and m.start() < best_pos:
                best_pos, best_kind, best_char = m.start(), "char", m

        if best_kind == "":
            out.append(text[i:])
            break

        out.append(text[i:best_pos])  # verbatim code preceding the token
        if best_kind == "line":
            end = text.find("\n", best_pos)
            end = length if end == -1 else end
        elif best_kind == "block":
            end = _consume_block(text, best_pos, syntax)
        elif best_kind == "raw_string":
            assert best_raw is not None  # set in lockstep with best_kind
            end = _consume_raw_string(text, best_raw)
        elif best_kind == "char":
            assert best_char is not None  # set in lockstep with best_kind
            end = best_char.end()
        else:
            end = _consume_string(text, best_pos, best_delim)
        out.append(_blank(text[best_pos:end]))
        i = end
    return "".join(out)


# --------------------------------------------------------------------------
# Declaration extraction
# --------------------------------------------------------------------------

_IMPL_GENERICS = re.compile(r"^<")
_WS = re.compile(r"\s+")


def _normalize_impl_name(remainder: str) -> str | None:
    """Derive a stable name for a Rust ``impl`` from the text after ``impl``.

    Strips leading generic parameters (``impl<T> ...``), cuts at a ``where``
    clause or the opening brace, and collapses whitespace.  Preserves the
    full subject so ``impl Trait for Type`` is named ``"Trait for Type"``
    (not just ``"Trait"``), making it unambiguous against a bare
    ``impl Type``.
    """
    s = remainder.strip()
    if _IMPL_GENERICS.match(s):  # drop the leading <...> generic params
        depth = 0
        cut = -1
        for idx, ch in enumerate(s):
            if ch == "<":
                depth += 1
            elif ch == ">":
                depth -= 1
                if depth == 0:
                    cut = idx
                    break
        if cut == -1:
            return None
        s = s[cut + 1 :].strip()
    where = re.search(r"\bwhere\b", s)
    if where:
        s = s[: where.start()]
    brace = s.find("{")
    if brace != -1:
        s = s[:brace]
    s = _WS.sub(" ", s).strip()
    return s or None


def extract_declarations(
    masked: str, patterns: list[tuple[str, re.Pattern[str]]]
) -> list[dict]:
    """Extract top-level declarations from already-masked source.

    Each line is matched (after leading-whitespace stripping) against the
    ordered ``patterns``; the first match wins.  Operating on masked source
    means comment / string content cannot produce a spurious declaration.
    """
    declarations: list[dict] = []
    for idx, line in enumerate(masked.splitlines(), start=1):
        src = line.strip()
        if not src:
            continue
        for kind, regex in patterns:
            m = regex.match(src)
            if not m:
                continue
            name = m.group(1)
            if kind == "impl":
                name = _normalize_impl_name(name)
                if name is None:
                    break
            declarations.append({"kind": kind, "name": name, "line": idx, "called": []})
            break
    return declarations


# --------------------------------------------------------------------------
# Lexical reference graph (the ``called`` field)
# --------------------------------------------------------------------------


def assign_called(
    modules: list[dict],
    masked_by_path: dict[str, str],
    ident_re: re.Pattern[str],
) -> None:
    """Populate each declaration's ``called`` list in place.

    ``called`` is the sorted set of *other* declaration names (drawn from
    the whole-language name set in ``modules``) that occur as identifier
    tokens within the declaration's line-ordered body span.  See the module
    docstring for the precise (lexical, lower-bound) semantics.
    """
    all_names = {
        decl["name"] for module in modules for decl in module["declarations"]
    }
    for module in modules:
        masked_lines = masked_by_path[module["path"]].splitlines()
        decls = module["declarations"]
        for k, decl in enumerate(decls):
            start = decl["line"]
            end = decls[k + 1]["line"] if k + 1 < len(decls) else len(masked_lines) + 1
            body = "\n".join(masked_lines[start - 1 : end - 1])
            referenced = set(ident_re.findall(body)) & all_names
            referenced.discard(decl["name"])
            decl["called"] = sorted(referenced)


# --------------------------------------------------------------------------
# Map assembly
# --------------------------------------------------------------------------


def build_map(
    *,
    language_scope: str,
    files: list[str],
    syntax: CommentSyntax,
    patterns: list[tuple[str, str]],
    ident_pattern: str,
    module_name_fn: Callable[[str], str],
    head: dict[str, str],
) -> dict:
    """Assemble one language's codemap.

    Reads each tracked file exactly once: the raw bytes feed both the
    source digest (over all files, in sorted order) and -- after decoding
    and masking -- the declaration / reference extraction.
    """
    compiled = [(kind, re.compile(pattern)) for kind, pattern in patterns]
    ident_re = re.compile(ident_pattern)

    digest = hashlib.sha256()
    modules: list[dict] = []
    masked_by_path: dict[str, str] = {}
    declaration_count = 0

    for rel in sorted(files):
        raw = (ROOT / rel).read_bytes()
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(raw)

        masked = mask_source(raw.decode("utf-8", errors="ignore"), syntax)
        declarations = extract_declarations(masked, compiled)
        if not declarations:
            continue
        masked_by_path[rel] = masked
        modules.append(
            {
                "module": module_name_fn(rel),
                "path": rel,
                "declaration_count": len(declarations),
                "declarations": declarations,
            }
        )
        declaration_count += len(declarations)

    assign_called(modules, masked_by_path, ident_re)

    return {
        "schema_version": "1.0.0",
        "repository": {
            "name": "hatter6822/Knomosis",
            "url": "https://github.com/hatter6822/Knomosis",
            "head": head,
        },
        "source_sync": {
            "scope": [language_scope],
            "digest_algorithm": "sha256",
            "source_digest": digest.hexdigest(),
        },
        "summary": {
            "module_count": len(modules),
            "declaration_count": declaration_count,
        },
        "modules": modules,
    }


def write_json(path: Path, data: dict) -> None:
    """Write ``data`` as pretty-printed JSON with a trailing newline."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# Language configuration
# --------------------------------------------------------------------------

# Optional declaration modifiers / attributes preceding a Lean keyword.
LEAN_PREFIX = r"^(?:(?:private|protected|noncomputable|unsafe|partial)\s+)*(?:@[\[\]A-Za-z0-9_.,\s-]+\s*)*"
# Lean identifiers admit interior / trailing `?` and `!` (e.g. `find?_insert`,
# `getElem?_some`), so the name class matches LEAN_IDENT below; a class without
# them silently truncates such names (and collides distinct ones).
LEAN_NAME = r"([A-Za-z0-9_'.!?]+)"

LEAN_PATTERNS: list[tuple[str, str]] = [
    ("namespace", r"^namespace\s+" + LEAN_NAME),
    ("theorem", LEAN_PREFIX + r"theorem\s+" + LEAN_NAME),
    ("lemma", LEAN_PREFIX + r"lemma\s+" + LEAN_NAME),
    ("def", LEAN_PREFIX + r"def\s+" + LEAN_NAME),
    ("abbrev", LEAN_PREFIX + r"abbrev\s+" + LEAN_NAME),
    ("structure", LEAN_PREFIX + r"structure\s+" + LEAN_NAME),
    ("class", LEAN_PREFIX + r"class\s+" + LEAN_NAME),
    ("inductive", LEAN_PREFIX + r"inductive\s+" + LEAN_NAME),
    ("instance", LEAN_PREFIX + r"instance\s+" + LEAN_NAME),
    ("opaque", LEAN_PREFIX + r"opaque\s+" + LEAN_NAME),
    ("axiom", LEAN_PREFIX + r"axiom\s+" + LEAN_NAME),
]
# Lean identifiers: dotted, may carry primes and trailing ? / !.
LEAN_IDENT = r"[A-Za-z_][A-Za-z0-9_'!?]*(?:\.[A-Za-z_][A-Za-z0-9_'!?]*)*"

_SOL_NAME = r"([A-Za-z_][A-Za-z0-9_]*)"
SOLIDITY_PATTERNS: list[tuple[str, str]] = [
    ("abstract_contract", r"^abstract\s+contract\s+" + _SOL_NAME),
    ("contract", r"^contract\s+" + _SOL_NAME),
    ("interface", r"^interface\s+" + _SOL_NAME),
    ("library", r"^library\s+" + _SOL_NAME),
    ("struct", r"^struct\s+" + _SOL_NAME),
    ("enum", r"^enum\s+" + _SOL_NAME),
    ("event", r"^event\s+" + _SOL_NAME),
    ("error", r"^error\s+" + _SOL_NAME),
    ("modifier", r"^modifier\s+" + _SOL_NAME),
    ("function", r"^function\s+" + _SOL_NAME),
    # Special functions have no trailing name; the keyword is the name.
    ("constructor", r"^(constructor)\b"),
    ("receive", r"^(receive)\b"),
    ("fallback", r"^(fallback)\b"),
]
# Solidity references: member access folds into one opaque token.
SOLIDITY_IDENT = r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"

_RUST_VIS = r"(?:pub(?:\([^)]*\))?\s+)?"
# Modifiers that may precede a `fn` keyword, in Rust's canonical order; the
# optional `extern "ABI"` captures the cdylib FFI surface (`pub unsafe extern
# "C" fn knomosis_verify_ecdsa`).
_RUST_PREFIX = _RUST_VIS + r'(?:const\s+)?(?:unsafe\s+)?(?:async\s+)?(?:extern\s+(?:"[^"]*"\s+)?)?'
_RUST_NAME = r"([A-Za-z_][A-Za-z0-9_]*)"
RUST_PATTERNS: list[tuple[str, str]] = [
    ("mod", _RUST_VIS + r"mod\s+" + _RUST_NAME),
    ("struct", _RUST_PREFIX + r"struct\s+" + _RUST_NAME),
    ("union", _RUST_PREFIX + r"union\s+" + _RUST_NAME),
    ("enum", _RUST_PREFIX + r"enum\s+" + _RUST_NAME),
    ("trait", _RUST_PREFIX + r"trait\s+" + _RUST_NAME),
    ("type", _RUST_PREFIX + r"type\s+" + _RUST_NAME),
    # `fn` precedes `const` / `static`: a `const fn` is a function, and its
    # prefix already admits a leading `const`, so matching `fn` first avoids
    # recording `const fn foo` as a const literally named `fn`.
    ("fn", _RUST_PREFIX + r"fn\s+" + _RUST_NAME),
    ("const", _RUST_VIS + r"const\s+" + _RUST_NAME),
    ("static", _RUST_VIS + r"static\s+(?:mut\s+)?" + _RUST_NAME),
    ("macro", r"^macro_rules!\s+" + _RUST_NAME),
    # Captured broadly; the name is normalized by _normalize_impl_name.
    ("impl", r"^(?:unsafe\s+)?impl\b(.*)$"),
]
# Rust references: path segments fold into one opaque token.
RUST_IDENT = r"[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*"


def run_self_tests() -> None:
    """Fail loudly if the masker / extractor / reference graph regresses.

    Mirrors the startup self-check in ``Tools/CountSorries.lean``: the subtle
    logic -- comment / string masking with nesting and escapes, the
    declaration patterns, the ``impl`` name normalizer, and the reference
    graph -- is exercised on synthetic inputs before any file is scanned, so
    a regression fails the regeneration gate immediately instead of silently
    corrupting committed output.
    """
    lean = [(k, re.compile(p)) for k, p in LEAN_PATTERNS]
    rust = [(k, re.compile(p)) for k, p in RUST_PATTERNS]
    sol = [(k, re.compile(p)) for k, p in SOLIDITY_PATTERNS]
    # (description, source, syntax, compiled patterns, expected (kind, name) list)
    cases: list[tuple[str, str, CommentSyntax, list, list[tuple[str, str]]]] = [
        ("lean block comment", "/-\ndef fake\n-/\ndef real", LEAN_SYNTAX, lean, [("def", "real")]),
        ("lean nested block", "/- a /- b\ndef fake -/ c\ntheorem g -/\ndef real", LEAN_SYNTAX, lean, [("def", "real")]),
        ("lean docstring code", "/-! eg\n  def shown : Nat := 0\n-/\ndef real : Nat := 1", LEAN_SYNTAX, lean, [("def", "real")]),
        ("lean string literal", 'def real := "theorem nope"', LEAN_SYNTAX, lean, [("def", "real")]),
        ("lean escaped quote", 'def real := "x \\" def still"', LEAN_SYNTAX, lean, [("def", "real")]),
        ("lean line comment", "-- def fake\ndef real", LEAN_SYNTAX, lean, [("def", "real")]),
        ("lean attribute", "@[simp] theorem t : True := trivial", LEAN_SYNTAX, lean, [("theorem", "t")]),
        ("lean ?/! names", "def find?_insert : Nat := 0", LEAN_SYNTAX, lean, [("def", "find?_insert")]),
        # A quote inside a char literal must not open a string and swallow the
        # next declaration (regression: would mask to EOF and drop `real`).
        ("lean char quote desync", "def has_quote := '\"'\ndef real := 0", LEAN_SYNTAX, lean,
         [("def", "has_quote"), ("def", "real")]),
        # A primed identifier's `'` is not a char-literal opener.
        ("lean primed ident vs char", "def s' := '\"'", LEAN_SYNTAX, lean, [("def", "s'")]),
        ("rust block + string", '/* fn a */\nlet s = "fn b";\npub fn real() {}', RUST_SYNTAX, rust, [("fn", "real")]),
        ("rust nested block", "/* a /* b fn x */ c */\nfn real() {}", RUST_SYNTAX, rust, [("fn", "real")]),
        ("rust impl for", "impl<'a> Foo<'a> for Bar where Bar: X {", RUST_SYNTAX, rust, [("impl", "Foo<'a> for Bar")]),
        ("rust lifetime not string", "fn f<'a>(x: &'a str) {}\nfn g() {}", RUST_SYNTAX, rust, [("fn", "f"), ("fn", "g")]),
        ("rust macro_rules", "macro_rules! m {", RUST_SYNTAX, rust, [("macro", "m")]),
        ("rust raw string", 'pub fn real() { let s = r#"struct Fake { fn nope() }"#; }', RUST_SYNTAX, rust, [("fn", "real")]),
        ("rust raw string multiline", "fn real() {\n    let s = r#\"\n    fn fake_decl() {}\n    \"#;\n}", RUST_SYNTAX, rust, [("fn", "real")]),
        ("rust raw string hash-balanced", 'fn real() { let s = br##"a "# still in"##; }', RUST_SYNTAX, rust, [("fn", "real")]),
        # Char / byte-char literals containing a quote must not open a string.
        ("rust char quote desync", "fn quote() { let c = '\"'; }\nfn real() {}", RUST_SYNTAX, rust,
         [("fn", "quote"), ("fn", "real")]),
        ("rust byte char quote", "fn quote() { let b = b'\"'; }\nfn real() {}", RUST_SYNTAX, rust,
         [("fn", "quote"), ("fn", "real")]),
        # A lifetime's `'` has no close quote, so it stays code (not a char).
        ("rust lifetime vs char", "fn real<'a>(x: &'a str) {}", RUST_SYNTAX, rust, [("fn", "real")]),
        ("solidity single-quote", "function real() { emit E('contract X'); }", SOLIDITY_SYNTAX, sol, [("function", "real")]),
        ("solidity specials", "constructor() {}\nreceive() external {}\nfallback() external {}", SOLIDITY_SYNTAX, sol,
         [("constructor", "constructor"), ("receive", "receive"), ("fallback", "fallback")]),
    ]
    for desc, src, syntax, patterns, expected in cases:
        got = [(d["kind"], d["name"]) for d in extract_declarations(mask_source(src, syntax), patterns)]
        if got != expected:
            raise SystemExit(
                f"regenerate_codemaps self-test FAILED [{desc}]\n  expected {expected}\n  got      {got}"
            )

    # Reference graph: an unqualified call is recorded; a call inside a comment
    # is masked away; self-references are excluded.
    ref_src = "def callee : Nat := 0\ndef caller : Nat := callee\n-- def caller also names callee\n"
    masked = mask_source(ref_src, LEAN_SYNTAX)
    modules = [{"path": "t", "declarations": extract_declarations(masked, lean)}]
    assign_called(modules, {"t": masked}, re.compile(LEAN_IDENT))
    called = {d["name"]: d["called"] for d in modules[0]["declarations"]}
    if called != {"callee": [], "caller": ["callee"]}:
        raise SystemExit(f"regenerate_codemaps self-test FAILED [reference graph]\n  got {called}")

    # A raw string in a body must not leak its payload as references: the
    # `helper` mention inside the raw string is masked, so `run` has no edge.
    raw_ref = 'fn helper() {}\nfn run() {\n    let s = r#"helper() not an edge"#;\n}\n'
    masked_raw = mask_source(raw_ref, RUST_SYNTAX)
    modules_raw = [{"path": "t", "declarations": extract_declarations(masked_raw, rust)}]
    assign_called(modules_raw, {"t": masked_raw}, re.compile(RUST_IDENT))
    called_raw = {d["name"]: d["called"] for d in modules_raw[0]["declarations"]}
    if called_raw != {"helper": [], "run": []}:
        raise SystemExit(
            f"regenerate_codemaps self-test FAILED [raw-string reference graph]\n  got {called_raw}"
        )


def main() -> None:
    run_self_tests()
    head = head_metadata()
    # Discover source via `git ls-files` (tracked files only).  This keeps
    # the codemap independent of build artefacts (`.lake/`, `target/`,
    # `out/`) and of gitignored vendored dependencies (`solidity/lib/`),
    # so a regeneration on a CI checkout that has not vendored those
    # third-party trees produces byte-identical output to a developer's
    # fully-built tree.  Without this, the regeneration gate would drift
    # whenever the scanned tree differs from the committed source set.
    tracked = git(["ls-files"]).splitlines()
    lean_files = [
        f for f in tracked if f.endswith(".lean") and ".lake/" not in f and "/build/" not in f
    ]
    sol_files = [f for f in tracked if f.endswith(".sol")]
    rust_files = [f for f in tracked if f.endswith(".rs") and "/target/" not in f]

    lean_map = build_map(
        language_scope="**/*.lean",
        files=lean_files,
        syntax=LEAN_SYNTAX,
        patterns=LEAN_PATTERNS,
        ident_pattern=LEAN_IDENT,
        module_name_fn=lambda p: p.replace("/", ".").removesuffix(".lean"),
        head=head,
    )
    solidity_map = build_map(
        language_scope="**/*.sol",
        files=sol_files,
        syntax=SOLIDITY_SYNTAX,
        patterns=SOLIDITY_PATTERNS,
        ident_pattern=SOLIDITY_IDENT,
        module_name_fn=lambda p: Path(p).stem,
        head=head,
    )
    rust_map = build_map(
        language_scope="**/*.rs",
        files=rust_files,
        syntax=RUST_SYNTAX,
        patterns=RUST_PATTERNS,
        ident_pattern=RUST_IDENT,
        module_name_fn=lambda p: p.removesuffix(".rs").replace("/", "::"),
        head=head,
    )

    write_json(ROOT / "codemaps/lean/codemap.json", lean_map)
    write_json(ROOT / "codemaps/solidity/codemap.json", solidity_map)
    write_json(ROOT / "codemaps/rust/codemap.json", rust_map)


if __name__ == "__main__":
    main()

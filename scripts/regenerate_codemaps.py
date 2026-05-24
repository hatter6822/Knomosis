#!/usr/bin/env python3
"""Regenerate codemaps/*/codemap.json using the seLe4n schema shape.

Usage:
  python3 scripts/regenerate_codemaps.py
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent


def git(args: list[str]) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def head_metadata() -> dict[str, str]:
    """Return stable, non-HEAD-derived metadata for codemap header fields."""
    return {
        "branch": "source-independent",
        "commit_sha": "source-independent",
        "tree_sha": "source-independent",
        "committed_at_utc": "source-independent",
    }


def source_digest(files: list[str]) -> str:
    h = hashlib.sha256()
    for rel in sorted(files):
        p = ROOT / rel
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(p.read_bytes())
    return h.hexdigest()


def collect(files: list[str], patterns: list[tuple[str, str]]) -> tuple[list[dict], int]:
    modules: list[dict] = []
    total = 0
    compiled = [(kind, re.compile(pattern)) for kind, pattern in patterns]
    for rel in sorted(files):
        lines = (ROOT / rel).read_text(encoding="utf-8", errors="ignore").splitlines()
        declarations: list[dict] = []
        for idx, line in enumerate(lines, start=1):
            src = line.strip()
            for kind, regex in compiled:
                m = regex.match(src)
                if m:
                    declarations.append({"kind": kind, "name": m.group(1), "line": idx, "called": []})
                    break
        if declarations:
            modules.append({
                "module": "",
                "path": rel,
                "declaration_count": len(declarations),
                "declarations": declarations,
            })
            total += len(declarations)
    return modules, total


def build_map(*, language_scope: str, files: list[str], patterns: list[tuple[str, str]], module_name_fn: Callable[[str], str], head: dict[str, str]) -> dict:
    modules, decl_count = collect(files, patterns)
    for m in modules:
        m["module"] = module_name_fn(m["path"])

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
            "source_digest": source_digest(files),
        },
        "summary": {"module_count": len(modules), "declaration_count": decl_count},
        "modules": modules,
    }


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    head = head_metadata()
    # Discover source via `git ls-files` (tracked files only).  This keeps
    # the codemap independent of build artefacts (`.lake/`, `target/`,
    # `out/`) and of gitignored vendored dependencies (`solidity/lib/`),
    # so a regeneration on a CI checkout that has not vendored those
    # third-party trees produces byte-identical output to a developer's
    # fully-built tree.  Without this, the regeneration gate would drift
    # whenever the scanned tree differs from the committed source set.
    tracked = git(["ls-files"]).splitlines()
    lean_files = [f for f in tracked if f.endswith(".lean") and ".lake/" not in f and "/build/" not in f]
    sol_files = [f for f in tracked if f.endswith(".sol")]
    rust_files = [f for f in tracked if f.endswith(".rs") and "/target/" not in f]

    lean_prefix = r"^(?:(?:private|protected|noncomputable|unsafe|partial)\s+)*(?:@[\[\]A-Za-z0-9_.,\s-]+\s*)*"
    lean_patterns = [
        ("namespace", r"^namespace\s+([A-Za-z0-9_.']+)"),
        ("theorem", lean_prefix + r"theorem\s+([A-Za-z0-9_'.]+)"),
        ("lemma", lean_prefix + r"lemma\s+([A-Za-z0-9_'.]+)"),
        ("def", lean_prefix + r"def\s+([A-Za-z0-9_'.]+)"),
        ("abbrev", lean_prefix + r"abbrev\s+([A-Za-z0-9_'.]+)"),
        ("structure", lean_prefix + r"structure\s+([A-Za-z0-9_'.]+)"),
        ("class", lean_prefix + r"class\s+([A-Za-z0-9_'.]+)"),
        ("inductive", lean_prefix + r"inductive\s+([A-Za-z0-9_'.]+)"),
        ("instance", lean_prefix + r"instance\s+([A-Za-z0-9_'.]+)"),
        ("opaque", lean_prefix + r"opaque\s+([A-Za-z0-9_'.]+)"),
        ("axiom", lean_prefix + r"axiom\s+([A-Za-z0-9_'.]+)"),
    ]

    sol_patterns = [
        ("abstract_contract", r"^abstract\s+contract\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("contract", r"^contract\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("interface", r"^interface\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("library", r"^library\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("struct", r"^struct\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("enum", r"^enum\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("event", r"^event\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("error", r"^error\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("modifier", r"^modifier\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("function", r"^function\s+([A-Za-z_][A-Za-z0-9_]*)"),
    ]

    rust_prefix = r"^(?:pub(?:\([^)]*\))?\s+)?(?:const\s+)?(?:unsafe\s+)?(?:async\s+)?"
    rust_patterns = [
        ("mod", r"^(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("struct", rust_prefix + r"struct\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("enum", rust_prefix + r"enum\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("trait", rust_prefix + r"trait\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("type", rust_prefix + r"type\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("const", r"^(?:pub(?:\([^)]*\))?\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("static", r"^(?:pub(?:\([^)]*\))?\s+)?static\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("fn", rust_prefix + r"fn\s+([A-Za-z_][A-Za-z0-9_]*)"),
        ("impl", r"^(?:unsafe\s+)?impl(?:<[^>]+>)?\s+([A-Za-z_][A-Za-z0-9_:<>]*)"),
    ]

    lean_map = build_map(language_scope="**/*.lean", files=lean_files, patterns=lean_patterns, module_name_fn=lambda p: p.replace("/", ".").removesuffix(".lean"), head=head)
    solidity_map = build_map(language_scope="**/*.sol", files=sol_files, patterns=sol_patterns, module_name_fn=lambda p: Path(p).stem, head=head)
    rust_map = build_map(language_scope="**/*.rs", files=rust_files, patterns=rust_patterns, module_name_fn=lambda p: p.removesuffix(".rs").replace("/", "::"), head=head)

    write_json(ROOT / "codemaps/lean/codemap.json", lean_map)
    write_json(ROOT / "codemaps/solidity/codemap.json", solidity_map)
    write_json(ROOT / "codemaps/rust/codemap.json", rust_map)


if __name__ == "__main__":
    main()

-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Tools.Common — shared constants and helpers for the Phase 1
audit executables (`tcb_audit`, `count_sorries`).

Centralising the kernel-TCB file list and the read helper lets a
Phase-2 amendment that promotes a new module to the TCB touch a
single file rather than two parallel definitions.

This module is **not** part of the trusted computing base: the
audit tools are diagnostic, and a bug in this file would only
manifest as a CI failure or a false negative that the parallel
`grep` check in CLAUDE.md catches.
-/

namespace LegalKernel.Tools

/-- Files that constitute the kernel trusted computing base.

    Both audit tools depend on this list:
    - `tcb_audit` parses each file's `import` lines and rejects any
      not on `tcb_allowlist.txt`;
    - `count_sorries` checks that each file has zero `sorry` in
      proof position.

    Adding a new file here is a TCB expansion (Genesis Plan §13.6 /
    CLAUDE.md "Two reviewer rule") and triggers the corresponding
    audit-list update in `tcb_allowlist.txt`. -/
def kernelTcbFiles : List String :=
  [ "LegalKernel/Kernel.lean"
  , "LegalKernel/RBMapLemmas.lean"
  , "LegalKernel/Laws/Transfer.lean"
  ]

/-- Subset of `kernelTcbFiles` whose imports the `tcb_audit` tool
    enumerates and compares against the allowlist.  Excludes the
    transfer law (which is allowed to import other laws and
    `LegalKernel.*` siblings beyond the kernel) — only the trusted
    *core* files have a strict allowlist. -/
def tcbCoreFiles : List String :=
  [ "LegalKernel/Kernel.lean"
  , "LegalKernel/RBMapLemmas.lean"
  ]

/-- Project-internal modules that any TCB core file may import freely
    (i.e. without an entry in `tcb_allowlist.txt`).  Listed explicitly
    rather than allowing the entire `LegalKernel.*` namespace — the
    looser policy would let a kernel core file silently depend on a
    non-TCB module like `LegalKernel.Laws.Transfer`, expanding the
    trusted base without the §13.6 amendment process. -/
def tcbInternalImports : List String :=
  [ "LegalKernel.Kernel"
  , "LegalKernel.RBMapLemmas"
  ]

/-- Path to the TCB import allowlist consumed by `tcb_audit`. -/
def tcbAllowlistPath : String := "tcb_allowlist.txt"

/-! ## Source masking

Comment / string / char-literal masking, shared by `count_sorries`
(which must not count a `sorry` written inside a docstring) and
`stub_audit` (which must not match a placeholder EXPRESSION written
inside one).

It lived in `Tools.CountSorries` and `stub_audit` did without, which
is why documenting a removed default as `:= ByteArray.empty` inside a
docstring made the gate fire on its own explanation.  One lexer, both
gates.
-/

/-- Lexical state of the character-level preprocessor. -/
inductive LexState
  /-- Ordinary code; characters pass through unchanged. -/
  | code
  /-- Inside a `"…"` string literal; characters become spaces.
      `escaped` is `true` immediately after a backslash, so the next
      `"` does not close the string. -/
  | inString (escaped : Bool)
  /-- Inside a `/- … -/` block comment (or `/-- … -/` docstring) at
      the given nesting depth.  Lean allows nested block comments. -/
  | inBlockComment (depth : Nat)
  /-- Inside a `-- …` line comment; characters become spaces until
      the next newline. -/
  | inLineComment

/-- Mask one character given the current state, returning the
    `(replacement, newState)` pair.  `'\n'` is preserved verbatim in
    every state so line numbering matches the original file. -/
def maskStep : LexState → Char → Char → Char × LexState
  | .code, '/', '-'           => (' ', .inBlockComment 1)
  | .code, '-', '-'           => (' ', .inLineComment)
  | .code, '"', _             => (' ', .inString false)
  | .code, c, _               => (c, .code)
  | .inString true, _, _      => (' ', .inString false)
  | .inString false, '\\', _  => (' ', .inString true)
  | .inString false, '"', _   => (' ', .code)
  | .inString false, '\n', _  => ('\n', .inString false)
  | .inString false, _, _     => (' ', .inString false)
  | .inLineComment, '\n', _   => ('\n', .code)
  | .inLineComment, _, _      => (' ', .inLineComment)
  | .inBlockComment d, '/', '-' => (' ', .inBlockComment (d + 1))
  | .inBlockComment 1, '-', '/' => (' ', .code)
  | .inBlockComment (d + 1), '-', '/' => (' ', .inBlockComment d)
  | .inBlockComment d, '\n', _ => ('\n', .inBlockComment d)
  | .inBlockComment d, _, _   => (' ', .inBlockComment d)

/-- Blank the interior of every closed Lean CHARACTER literal, as a
    pre-pass before the comment / string lexer runs.

    `maskStep` sees only one character of lookahead, so it cannot tell
    the `"` in the character literal `'"'` (three characters) or `'\"'`
    (four) from a string opener.  It therefore treated such a file as
    entering a string literal and blanked the entire remainder of the
    text — every `sorry` after the first one became invisible to the
    zero-sorry gate.  Recognising the literals up front removes the
    ambiguity without giving the lexer more lookahead.

    Only the fully closed shapes are matched.  A bare `'` is
    deliberately NOT an opener: `'` is a legal identifier character in
    Lean and occurs as a prime in hundreds of kernel declarations, so
    an opener rule would blank real code.  A prime that happens to sit
    two characters from another prime therefore matches spuriously —
    harmlessly, because the replacement is whitespace and a
    single-character literal can never spell `sorry`.  Newlines are
    preserved in every position so line numbering survives. -/
def maskCharLiterals (cs : List Char) : List Char :=
  -- Accumulator-passing so the walk stays tail-recursive: this runs
  -- over a whole source file's character list, and a non-tail form
  -- overflows the stack on the larger kernel modules.
  let rec go (acc : List Char) : List Char → List Char
    -- `'\e'` — escaped character literal.
    | '\'' :: '\\' :: esc :: '\'' :: rest =>
        go (' ' :: (if esc = '\n' then '\n' else ' ') :: ' ' :: ' ' :: acc) rest
    -- `'c'` — plain character literal.
    | '\'' :: c :: '\'' :: rest =>
        go (' ' :: (if c = '\n' then '\n' else ' ') :: ' ' :: acc) rest
    | c :: rest => go (c :: acc) rest
    | []        => acc.reverse
  go [] cs

/-- Walk a list of characters, blanking out comments and string
    literals.  After this pass, the only `sorry` substrings remaining
    are those in code position.  Character literals are blanked by the
    `maskCharLiterals` pre-pass first, so the lexer never mistakes the
    quote inside one for a string opener. -/
def maskNonCode (cs : List Char) : List Char :=
  let rec go (st : LexState) (acc : List Char) : List Char → List Char
    | []           => acc.reverse
    | [c]          =>
        -- Last character: no lookahead.  Mask under the current state
        -- treating the lookahead as a non-special placeholder.
        let (c', _) := maskStep st c ' '
        go st (c' :: acc) []
    | c₁ :: c₂ :: rest =>
        let (c', st') := maskStep st c₁ c₂
        match st, st', c₁, c₂ with
        | .code, .inBlockComment _, '/', '-'  => go st' (' ' :: ' ' :: acc) rest
        | .code, .inLineComment, '-', '-'      => go st' (' ' :: ' ' :: acc) rest
        | .inBlockComment _, .code, '-', '/'   => go st' (' ' :: ' ' :: acc) rest
        | .inBlockComment _, .inBlockComment _, '/', '-' =>
            go st' (' ' :: ' ' :: acc) rest
        | _, _, _, _                            => go st' (c' :: acc) (c₂ :: rest)
  go .code [] (maskCharLiterals cs)

/-- Read a file, returning `none` on any read error.  Folds the
    `IO.FS.readFile`-then-`toBaseIO`-then-`match` pattern that
    appears in both audit tools. -/
def readFileSafe (path : String) : IO (Option String) := do
  match (← (IO.FS.readFile path).toBaseIO) with
  | .error _ => pure none
  | .ok s    => pure (some s)

end LegalKernel.Tools

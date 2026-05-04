/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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

/-- Read a file, returning `none` on any read error.  Folds the
    `IO.FS.readFile`-then-`toBaseIO`-then-`match` pattern that
    appears in both audit tools. -/
def readFileSafe (path : String) : IO (Option String) := do
  match (← (IO.FS.readFile path).toBaseIO) with
  | .error _ => pure none
  | .ok s    => pure (some s)

end LegalKernel.Tools

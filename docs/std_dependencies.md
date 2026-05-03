# Std dependency audit (Phase 1 WU 1.13)

This note records every `Std`-library lemma that the trusted-core
modules of Canon (`LegalKernel.Kernel`, `LegalKernel.RBMapLemmas`)
depend on, with stability notes.  The audit is the deliverable for
Phase 1 work unit 1.13 (Genesis Plan §12) and is intended to be
reviewed alongside any toolchain bump.

## Scope

The TCB equals **Lean core + this repository**.  No `batteries`,
no `Mathlib`, no third-party Lake packages.  The `tcb_audit` tool
(`lake exe tcb_audit`) enforces this at the *direct-import* level by
comparing each TCB module's `import` lines to `tcb_allowlist.txt`.

This document goes one layer deeper: it enumerates the **specific
lemmas** (not just modules) the TCB invokes.  A toolchain bump that
removes or renames any of these lemmas will surface as a build
break; this list tells reviewers what to expect.

## Scanning method

The list below was assembled by reading the TCB source files in
their entirety and recording each `Std.*` (or `TreeMap.*` /
`DTreeMap.*` after the `open Std`) symbol that appears in a proof
or term position.  Symbols used only inside Lean's own elaborator
(e.g. `simp` lemmas implicit in `simp [getBalance, setBalance]`)
are *not* enumerated; the focus is on names that would have to be
re-resolved if the underlying lemma were renamed.

## Direct lemma dependencies

### `LegalKernel/Kernel.lean`

The kernel module depends on `Std.Data.TreeMap` only at the
*type-and-constructor* level — `TreeMap`, `TreeMap.empty` (the
`∅` notation), `TreeMap.insert`, the `[k]?` `GetElem?` instance,
and `Option.getD`.  No `Std.TreeMap.*` lemmas are invoked
directly: the §4.3 balance lemmas defer their pointwise reasoning
to `LegalKernel.RBMapLemmas`.

| Std symbol | Source | Used in | Stability |
|---|---|---|---|
| `Std.TreeMap` (type) | `Std.Data.TreeMap` | `BalanceMap`, `State` | type-level, very stable |
| `Std.TreeMap.empty` (`∅` notation) | `Std.Data.TreeMap` | `setBalance` | API-stable |
| `Std.TreeMap.insert` | `Std.Data.TreeMap` | `setBalance` | API-stable |
| `Std.TreeMap.getElem?` (via `[k]?`) | `Std.Data.TreeMap` | `getBalance`, `setBalance` | API-stable |
| `Option.getD` | `Init.Data.Option` | `getBalance`, `setBalance` | core, very stable |

### `LegalKernel/RBMapLemmas.lean`

The §8.3 RBMap proof library is where every non-trivial `Std`
lemma lives.

| Std lemma | Module | Used in | Stability notes |
|---|---|---|---|
| `Std.TreeMap.getElem?_insert_self` | `Std.Data.TreeMap.Lemmas` | `find?_insert_self` (WU 1.1) | `@[simp]`, post-rename name; was `Std.RBMap.find?_insert_self` in std4. |
| `Std.TreeMap.getElem?_insert` | `Std.Data.TreeMap.Lemmas` | `find?_insert_other` (WU 1.1) | `@[grind =]`; used together with `LawfulEqCmp.compare_eq_iff_eq` to discharge the "different key" branch. |
| `Std.LawfulEqCmp.eq_of_compare` | `Init.Data.Order.Ord` | `find?_insert_other` (WU 1.1) | core, very stable |
| `Std.TreeMap.foldl_eq_foldl_toList` | `Std.Data.TreeMap.Lemmas` | `sumValues_eq_toList_sum` (WU 1.4 bridge) | first-stable form; equivalent in spirit to "fold respects toList order". |
| `List.sum_eq_foldl_nat` | `Init.Data.List.Nat.Sum` | `sumValues_eq_values_sum` (WU 1.4) | core; `xs.sum = xs.foldl 0 (· + ·)` for `Nat`-lists.  Bridges between the kernel's `foldl`-based `sumValues` and Lean core's standard `List.sum` for `Nat`-permutation theorems. |
| `Std.TreeMap.toList_insert_perm` | `Std.Data.TreeMap.Lemmas` | `sumValues_insert_absent` (WU 1.2) | core property; permutation form chosen to match `List.Perm.sum_nat`. |
| `Std.TreeMap.mem_iff_isSome_getElem?` | `Std.Data.TreeMap.Lemmas` | `sumValues_insert_absent`, `not_mem_erase_self` | API-stable |
| `Std.TreeMap.mem_toList_iff_getElem?_eq_some` | `Std.Data.TreeMap.Lemmas` | `sumValues_insert_absent` | requires `[LawfulEqCmp cmp]`. |
| `Std.TreeMap.getElem?_erase` | `Std.Data.TreeMap.Lemmas` | `insert_equiv_erase_insert`, `self_equiv_erase_insert` | `@[grind =]`. |
| `Std.TreeMap.getElem?_erase_self` | `Std.Data.TreeMap.Lemmas` | `not_mem_erase_self` | `@[simp]`. |
| `Std.TreeMap.getElem?_congr` | `Std.Data.TreeMap.Lemmas` | `self_equiv_erase_insert` | for the `cmp k k' = .eq` symmetry. |
| `Std.TreeMap.Equiv.foldl_eq` | `Std.Data.TreeMap.Lemmas` | `sumValues_of_equiv` (WU 1.3 helper) | the bridge from `~m` equivalence to fold equality. |
| `Std.DTreeMap.Equiv.of_forall_constGet?_eq` | `Std.Data.DTreeMap.Lemmas` | `equiv_of_getElem_eq` (WU 1.3 helper) | the "extensionality at the `getElem?` map" lemma; constructs a `DTreeMap.Equiv` that the `TreeMap.Equiv` constructor wraps. |
| `List.Perm.sum_nat` | `Init.Data.List.Perm` | `sumValues_insert_absent` (WU 1.2) | permutation invariance of `Nat`-sum; core. |
| `List.Perm.map` | `Init.Data.List.Perm` | `sumValues_insert_absent` (WU 1.2) | core; used to lift `Perm` from key-value pairs to value-only lists. |
| `List.filter_eq_self` | `Init.Data.List.Lemmas` | `sumValues_insert_absent` (WU 1.2) | core; characterises identity filtering. |
| `LawfulBEq.eq_of_beq` | `Init.Core` | `sumValues_insert_absent` (WU 1.2) | core; `(a == b) → (a = b)` for lawful BEq. |
| `decide_eq_true_eq` | `Init.Core` | `sumValues_insert_absent` (WU 1.2) | core. |

### Implicit type-class instances (UInt64 path)

The kernel's `BalanceMap = TreeMap UInt64 Nat compare` relies on the
following typeclass instances landing automatically at use sites:

| Instance | Defines | Source |
|---|---|---|
| `Ord UInt64` | `compare : UInt64 → UInt64 → Ordering` | `Init.Data.Ord.UInt` |
| `TransOrd UInt64` (i.e. `TransCmp compare`) | transitivity of compare | `Init.Data.Ord.UInt` |
| `LawfulEqOrd UInt64` (i.e. `LawfulEqCmp compare`) | `compare a b = .eq ↔ a = b` | `Init.Data.Ord.UInt` |
| `BEq UInt64` (deriving `DecidableEq`) | `==` | `Init.Data.UInt.Basic` |
| `LawfulBEq UInt64` | `(a == b) ↔ (a = b)` | derived from `DecidableEq` |

The combination `[LawfulEqCmp cmp] [LawfulBEq κ] → [LawfulBEqCmp cmp]`
(line 433 of `Init/Data/Order/Ord.lean`) lets the
`toList_insert_perm` lemma apply at `cmp = compare` even though we
only declare the `LawfulEqCmp` and `LawfulBEq` instances directly.

## Stability and toolchain bumps

* The `getElem?_*` family was renamed from `find?_*` between std4
  and Lean core; the §8.3 spec preserves the older names in code
  comments but the actual proofs reference the post-rename
  identifiers.
* The `~m` equivalence relation moved from `RBMap.Equiv` to
  `TreeMap.Equiv` in Lean 4.10+.  The `equiv_iff_toList_eq`
  characterisation is stable.
* `Std.DTreeMap.Equiv.of_forall_constGet?_eq` is a relatively
  recent addition (Lean 4.27+).  If a toolchain regression removes
  it, `LegalKernel.RBMap.equiv_of_getElem_eq` can be re-implemented
  via `equiv_iff_toList_eq` plus a `getElem?` ↔ `toList` translation,
  at the cost of a longer proof.
* `List.Perm.sum_nat` is a Lean-core export (`Init.Data.List.Perm`);
  removing it would block the entire fold-lemma family.

## Review obligation

Per Genesis Plan §12 WU 1.13:

> **Acceptance:** list reviewed by 1+ formal-methods reviewer.

The two-reviewer rule of §13.6 / CLAUDE.md applies to any change to
`Kernel.lean` or `RBMapLemmas.lean`; this audit document tracks the
*surface* the reviewers should be inspecting.  Bumping the Lean
toolchain version requires:

1. Re-running `lake build` (catches signature changes).
2. Re-running `lake exe tcb_audit` (catches new direct imports).
3. Re-running `lake exe count_sorries` (catches regressions to
   incomplete proofs).
4. Re-walking this document line-by-line and updating any moved or
   renamed lemmas.

A toolchain bump PR that does not touch this file requires a
reviewer note explaining why no `Std` lemma signatures changed.

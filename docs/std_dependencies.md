<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

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

## Phase 2 deltas (informational)

The Phase-2 economic-invariants modules (`LegalKernel/Conservation.lean`,
`LegalKernel/Laws/{Mint,Burn,Freeze}.lean`, and the Phase-2 additions
to `LegalKernel/Laws/Transfer.lean`) are **non-TCB**.  Their `Std`
dependencies are therefore *not* tracked in the audit table above.
They use the same `Std.TreeMap` API surface as the TCB plus the
following additional core lemmas (recorded here for reviewer
convenience, not for TCB-audit purposes):

| Std symbol                       | Module                         | Used in                                    |
|----------------------------------|--------------------------------|--------------------------------------------|
| `Std.TreeMap.foldl_eq_foldl_toList` | `Std.Data.TreeMap.Lemmas`   | `Conservation.sumValues_emptyc` (private)  |
| `Std.TreeMap.isEmpty_toList`     | `Std.Data.TreeMap.Lemmas`      | `Conservation.sumValues_emptyc` (private)  |
| `Std.TreeMap.isEmpty_emptyc`     | `Std.Data.TreeMap.Lemmas`      | `Conservation.sumValues_emptyc` (private)  |
| `Std.TreeMap.not_mem_emptyc`     | `Std.Data.TreeMap.Lemmas`      | `Conservation.totalSupply_setBalance`      |
| `Std.TreeMap.mem_iff_isSome_getElem?` | `Std.Data.TreeMap.Lemmas` | `Conservation.totalSupply_setBalance`      |
| `List.isEmpty_iff`               | `Init.Data.List.Lemmas`        | `Conservation.sumValues_emptyc` (private)  |
| `Nat.pos_iff_ne_zero`            | `Init.Data.Nat.Basic`          | `Laws.mint_not_conservative`, `Laws.burn_not_conservative` |
| `Nat.le_refl`                    | `Init.Data.Nat.Basic`          | `Laws.burn_not_conservative` (precondition discharge) |

A future Phase-2 amendment that promotes any of these modules to TCB
status (e.g., a deployment that needs a hardened `Conservation.lean`)
must move the relevant rows into the audit table above and update
`tcb_allowlist.txt` if any new direct imports appear.

## Phase 3 deltas (informational)

The Phase-3 authority-layer modules (`LegalKernel/Authority/*`) are
**non-TCB**.  They are pure deployment infrastructure — bugs there can
weaken authority guarantees (replay protection, registration check),
but cannot violate any kernel invariant.  Their `Std` dependencies
are recorded here for reviewer convenience, not for TCB-audit
purposes.

| Std symbol                       | Module                         | Used in                                    |
|----------------------------------|--------------------------------|--------------------------------------------|
| `Std.TreeMap` (type)             | `Std.Data.TreeMap`             | `Authority.KeyRegistry`, `NonceState.next` |
| `Std.TreeMap.empty` (`∅`)        | `Std.Data.TreeMap`             | `KeyRegistry.empty`, `NonceState.empty`    |
| `Std.TreeMap.insert`             | `Std.Data.TreeMap`             | `KeyRegistry.register`, `advanceNonce`, `applyActionToRegistry` |
| `Std.TreeMap.erase`              | `Std.Data.TreeMap`             | `KeyRegistry.revoke`                       |
| `Std.TreeMap.contains`           | `Std.Data.TreeMap`             | `KeyRegistry.mergeLeftBiased`              |
| `Std.TreeMap.foldl`              | `Std.Data.TreeMap`             | `KeyRegistry.mergeLeftBiased`              |
| `Std.TreeMap.getElem?` (`m[k]?`) | `Std.Data.TreeMap`             | `expectsNonce`, `Admissible` registry lookup |
| `Nat.lt_succ_self`               | `Init.Data.Nat.Basic`          | `expectsNonce_after_advance_gt_old`        |
| `Nat.not_succ_le_self`           | `Init.Data.Nat.Basic`          | `expectsNonce_after_advance_ne_old`        |
| `Nat.ne_of_lt`                   | `Init.Data.Nat.Basic`          | `replay_impossible`                        |
| `instDecidableOr`                | `Init.Core`                    | `AuthorityPolicy.union.decAuth`            |
| `instDecidableAnd`               | `Init.Core`                    | `AuthorityPolicy.intersect.decAuth`, `singleton.decAuth` |

The Phase-3 modules also reuse the §8.3 RBMap library lemmas
(`RBMap.find?_insert_self`, `RBMap.find?_insert_other`) — these are
already on the TCB allowlist via the kernel's import of
`LegalKernel.RBMapLemmas`.

The opaque `Verify : PublicKey → ByteArray → Signature → Bool` and
`signingInput : Action → ActorId → Nonce → SigningInput` are *not*
`Std` dependencies; they are deployment-supplied (Phase 5 / Phase 4
respectively) and the kernel makes no assumption about their
implementations beyond determinism (which is automatic for `opaque`
declarations).

## Phase-4 prelude deltas (informational)

The Phase-4-prelude positive-incentive modules
(`LegalKernel/Laws/Reward.lean`,
`LegalKernel/Laws/DistributeOthers.lean`,
`LegalKernel/Laws/ProportionalDilute.lean`) and the monotonicity-tier
extensions to `LegalKernel/Conservation.lean` are **non-TCB**.  Their
`Std` dependencies are recorded here for reviewer convenience.

| Std symbol                       | Module                         | Used in                                                |
|----------------------------------|--------------------------------|--------------------------------------------------------|
| `Std.TreeMap.foldl`              | `Std.Data.TreeMap`             | `distributeOthers.apply_impl`, `proportionalDilute.apply_impl`, `sumOthers` |
| `Std.TreeMap.toList`             | `Std.Data.TreeMap`             | `proportionalDilute` filter-sum infrastructure         |
| `Std.TreeMap.distinct_keys_toList` | `Std.Data.TreeMap.Lemmas`    | `state_filter_sum_eq_sumOthers` (R.14 dust-bound)      |
| `List.filter`                    | `Init.Data.List.Basic`         | `proportionalDilute` per-actor exclusion logic         |
| `Nat.div`                        | `Init.Data.Nat.Basic`          | `proportionalDilute` (floor division)                  |
| `Nat.mul_div_le`                 | `Init.Data.Nat.Basic`          | `proportionalDilute_distributed_le_totalReward`        |
| `Nat.add_le_add`                 | `Init.Data.Nat.Basic`          | monotonicity-instance proofs                           |

No new `tcb_allowlist.txt` entries are introduced by the Phase-4
prelude; the new laws stay strictly within the deployment-facing
infrastructure layer.

<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Std dependency audit

This note records every `Std`-library lemma that the trusted-core
modules of Knomosis (`LegalKernel.Kernel`, `LegalKernel.RBMapLemmas`)
depend on, with stability notes.  The audit originated as the
deliverable for Phase 1 work unit 1.13 (Genesis Plan §12) and has
since been extended (EI.0.a / EI.2 / WG.5); it is intended to be
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

## Later phases (informational)

Phases 4 (DSL + CBE encoding), 5 (runtime + log + replay + snapshot),
6 (disputes and adjudication), the Ethereum-integration Workstreams
A – F (`LegalKernel/Bridge/*`), Workstream LP (actor-scoped policies),
and Workstream LX (Lex law-declaration language) are all strictly
**non-TCB** and do not introduce any new TCB allowlist entries.
The `Std` dependencies for these phases are documented in their
respective module headers and not re-tabulated here:

* **Phase 4 (CBE encoding)** — `Std.TreeMap.toList` for the
  canonical sorted-pair encoding of `BalanceMap` / `NonceState` /
  `KeyRegistry`; `Std.TreeMap.ofList` for the canonicalised decode
  path.  No new TreeMap lemmas beyond the existing audit surface.
* **Phase 5 (runtime)** — the runtime modules use `IO`, `ByteArray`,
  and `String` from Lean core; no new `Std.TreeMap` surface.
* **Phase 6 (disputes)** — reuses the §8.3 RBMap library and the
  Phase-3 nonce / registry surface.  No new `Std` lemmas.
* **Ethereum Workstream B (`Bridge/AddressBook.lean`)** — adds two
  `Std.TreeMap` instances over `EthAddress = Fin (2^160)` for the
  forward / reverse address book.  Uses `Fin`'s default
  `Ord` / `DecidableEq` instances; no custom comparator needed.
* **Ethereum Workstream C (`Bridge/State.lean`)** — adds two
  `Std.TreeMap` instances for `consumed : DepositId → DepositRecord`
  and `pending : WithdrawalId → PendingWithdrawal`.  Both keyed on
  `Nat` with the default `compare`.
* **Ethereum Workstream D (`Bridge/WithdrawalRoot.lean`)** — adds
  `Vector ByteArray smtHeight` (Lean core) for fixed-length sibling
  paths.  No new `Std.TreeMap` surface.
* **Ethereum Workstream F (cross-stack verification)** — pure
  `Test/` infrastructure: adds JSON-fixture I/O via
  `Lean.Json` (Lean core, not `Std`) and parametric per-fixture
  driver harness.  No new `Std.TreeMap` surface.
* **Workstream LP (`Authority/LocalPolicy.lean` /
  `Authority/LocalPolicySemantics.lean`)** — reuses
  `Std.Data.TreeMap` over `ActorId` for the `LocalPolicies` table;
  no new TreeMap lemmas.
* **Workstream LX (`DSL/LexLaw.lean`, `DSL/LexDeployment.lean`,
  `Tools/Lex*.lean`)** — pure macro / IO / parsing infrastructure
  using `Lean.Syntax`, `Lean.Json`, `IO.FS.*` from Lean core.  No
  new `Std.TreeMap` lemmas.  The macro pipeline does not touch the
  TCB allowlist surface.

A toolchain bump that touches the post-Phase-1 modules is checked
by `lake build` directly; this audit document tracks the *TCB*
surface specifically.

## EI.0.a — Encoder-injectivity Std-lemma audit (informational)

This subsection is the deliverable for Workstream EI sub-sub-unit
EI.0.a (`docs/planning/encoder_injectivity_plan.md` §4.0).  It
records the exact `Std.Data.TreeMap` lemma signatures the
encoder-injectivity proof recipe (§2.2 of that plan) relies on, as
observed in the **pinned** toolchain (`lean-toolchain` ⇒
`leanprover/lean4:v4.29.1`).  The audit is read-only: no source
change is implied.

**Toolchain inspected.**  `leanprover/lean4:v4.29.1`, source path
`~/.elan/toolchains/leanprover-lean4-v4.29.1/src/lean/Std/Data/TreeMap/Lemmas.lean`.

**Audit result.**  Every lemma the plan's §2.2 lift-chain calls out
is present in the pinned Std core under the literal name the plan
uses (or a one-token rename that the call sites at
`Encoding/State.lean:539` and `Encoding/LocalPolicy.lean:563`
already adopt).  No `Std.TreeMap` companion lemma is missing, so
sub-sub-unit EI.1.a is **a no-op** for this toolchain — the
TCB-tier `RBMapLemmas.lean` is **not** touched by Workstream EI.

| Plan-side name (EI §2.2) | Actual Std-core name | Source location (Lemmas.lean) | Signature summary |
|--------------------------|----------------------|--------------------------------|-------------------|
| `equiv_iff_toList_eq` | `Std.TreeMap.equiv_iff_toList_eq` | line 4348 | `[TransCmp cmp] : t₁ ~m t₂ ↔ t₁.toList = t₂.toList` |
| `getElem?_eq_of_Equiv` | `Std.TreeMap.Equiv.getElem?_eq` | line 3958 | `[TransCmp cmp] {k : α} (h : t₁ ~m t₂) : t₁[k]? = t₂[k]?` |
| `toList_isSorted` (sortedness) | `Std.TreeMap.ordered_keys_toList` | line 885 | `[TransCmp cmp] : (toList t).Pairwise (fun a b => cmp a.1 b.1 = .lt)` |
| `toList_nodup` (distinctness) | `Std.TreeMap.distinct_keys_toList` | line 881 | `[TransCmp cmp] : (toList t).Pairwise (fun a b => ¬ cmp a.1 b.1 = .eq)` |
| `equiv_refl` | `Std.TreeMap.Equiv.rfl` | line 3927 | `Equiv t t` (`@[refl, simp]`) |
| `equiv_symm` | `Std.TreeMap.Equiv.symm` | line 3929 | `Equiv t₁ t₂ → Equiv t₂ t₁` (`@[symm]`) |
| `equiv_trans` | `Std.TreeMap.Equiv.trans` | line 3932 | `Equiv t₁ t₂ → Equiv t₂ t₃ → Equiv t₁ t₃` (`instTrans` instance) |
| `Equiv.toList_eq` | `Std.TreeMap.Equiv.toList_eq` | line 3989 | `[TransCmp cmp] (h : t₁ ~m t₂) : t₁.toList = t₂.toList` |
| `Equiv.foldl_eq` (already in use) | `Std.TreeMap.Equiv.foldl_eq` | (per `RBMapLemmas.lean` line 225) | bridges `~m` to fold equality |

**Notes.**

* The plan's `getElem?_eq_of_Equiv` is the same lemma as Std's
  `Std.TreeMap.Equiv.getElem?_eq` — the Std API places the lemma
  inside the `Equiv` namespace and elides the `_of_Equiv` suffix
  because the `Equiv` hypothesis is the namespace's `variable`.
  The two existing call sites already invoke the
  `equiv_iff_toList_eq.mp` direction, which factors through
  `Equiv.toList_eq` and therefore exercises the same surface.
* `Std.TreeMap.Equiv.toList_eq` (line 3989) is a strictly stronger
  direction than `equiv_iff_toList_eq.mp` because it does not
  require the iff packaging — it is the direct
  `~m → toList = toList` arrow.  EI's per-sub-state proofs will
  use whichever of the two reads most cleanly at the call site.
* `Pairwise` is `Init.Data.List.Pairwise` (Lean core), imported at
  the head of `Std.Data.TreeMap.Lemmas`.  Sortedness and
  distinctness are therefore independent of `Mathlib` / `batteries`.
* The instance-level `@[refl]`, `@[symm]`, and the `instTrans`
  declaration mean `Std.TreeMap.Equiv` is a setoid in Std-core; EI
  proofs can use the `rfl` / `symm` / `calc` tactics on `~m` chains
  without re-deriving the algebraic structure.

**Conditional sub-unit status.**  EI sub-sub-unit `EI.1.a` is the
contingency that would land **only if** any row above were absent
from Std core (forcing a project-internal derivation in the
TCB-tier `RBMapLemmas.lean`).  Because every row is present, EI.1.a
is dropped from the workstream; the `EI` total sub-sub-unit count
moves from 47 nominal to **46 actually-landing**.  The single
remaining conditional unit is `EI.7.a` (an
`EthAddress.toBytes_injective` audit, independent of this Std
sweep), so certain-to-land stays at **45**.  The two-reviewer
§13.6 gate for TCB-tier changes is **not triggered** by EI.0.a.

**Re-audit obligation.**  A toolchain bump that touches
`Std.Data.TreeMap.Lemmas` must re-run this audit by grep-ing the
listed lemma names against the new toolchain's
`Std/Data/TreeMap/Lemmas.lean`.  If any row goes missing, EI.1.a
ships before the bump lands; the §13.6 two-reviewer rule applies
to the resulting TCB-tier change.

## EI.2 — Std lemmas consumed (informational)

This subsection records the *additional* Std-core lemmas that EI.2's
shipped proofs (`LegalKernel/Encoding/StateInjective.lean`) consume
beyond the EI.0.a audit set.  All entries are present in the pinned
toolchain (`leanprover/lean4:v4.29.1`).  Re-audit on toolchain bump
mirrors the EI.0.a obligation above.

| Std-core name | Source location | Role in EI.2 |
|---------------|------------------|---------------|
| `Std.TreeMap.equiv_iff_toList_eq` | `Std/Data/TreeMap/Lemmas.lean:4348` | EI.2.a final step: lift `toList = toList` to `Equiv`. |
| `Std.TreeMap.Equiv.rfl` | `Std/Data/TreeMap/Lemmas.lean:3927` | `State.Equiv.refl` discharges inner-map case. |
| `Std.TreeMap.Equiv.symm` | `Std/Data/TreeMap/Lemmas.lean:3929` | `State.Equiv.symm` flips inner-map orientation. |
| `Std.TreeMap.Equiv.getElem?_eq` | `Std/Data/TreeMap/Lemmas.lean:3958` | `State.Equiv.getBalance_eq` derives `bm₁[a]? = bm₂[a]?` from `bm₁.Equiv bm₂`. |
| `Std.TreeMap.mem_toList_iff_getElem?_eq_some` | `Std/Data/TreeMap/Lemmas.lean:853` | EI.2.d: bridges `t[k]? = some v` to `(k, v) ∈ t.toList`. |
| `Std.TreeMap.mem_keys` | `Std/Data/TreeMap/Lemmas.lean:818` | EI.2.d outer-key agreement: `r ∈ t.keys ↔ r ∈ t`. |
| `Std.TreeMap.map_fst_toList_eq_keys` | `Std/Data/TreeMap/Lemmas.lean:838` | EI.2.d outer-key derivation: rewrites `keys` as `toList.map Prod.fst`. |
| `UInt64.toNat_inj` | `Init/Data/UInt/Lemmas.lean:169` | EI.2.a key bijection: `a.toNat = b.toNat → a = b`. |
| `UInt64.toNat_lt` | `Init/Data/UInt/Lemmas.lean:332` | EI.2.a / EI.2.d key bound: `a.toNat < 2^64`. |
| `List.map_inj_right` | `Init/Data/List/Lemmas.lean:1138` | EI.2.a inner-list lift: `map f l = map f l' ↔ l = l'` (under `f` injective). |
| `List.mem_map` | `Init/Data/List/Lemmas.lean:1113` | EI.2.a / EI.2.d per-pair bound discharge. |
| `List.length_map` | `Init/Data/List/Lemmas.lean:1069` | Length-preservation under `map`. |
| `List.getElem_map` | core | Per-index projection of `map`. |
| `List.ext_getElem` | core | EI.2.d outer-key derivation: extensional list equality. |
| `List.mem_iff_getElem` | core | EI.2.d locates `(r, bm)` at an index in `toList`. |
| `List.getElem_mem` | core | EI.2.d inner-map step: `l[i] ∈ l`. |

Note: `Std.TreeMap.mem_toList_iff_getElem?_eq_some` and
`Std.TreeMap.mem_keys` both require `[LawfulEqCmp cmp]`, which is
discharged on `(compare : UInt64 → UInt64 → Ordering)` via Lean
core's `instance : LawfulEqOrd UInt64`
(`Init/Data/Ord/UInt.lean:90`).  `ActorId` and `ResourceId` resolve
through `UInt64` via their `abbrev` aliases.

## WG.5 — Workstream-E TCB import refresh (informational)

This subsection is the deliverable for Workstream WG.5
(`docs/planning/ethereum_workstream_g_plan.md` §WG.5).  It
records the post-Workstream-E status of the TCB import allowlist
and confirms no Bridge-module imports leaked into the TCB-core
file set (`Kernel.lean` + `RBMapLemmas.lean`).

**Audit method.**

  1. Run `lake exe tcb_audit` — expected: PASS.
  2. Enumerate the direct imports of every
     `LegalKernel/Bridge/*.lean` file:

     ```bash
     grep -E "^import" LegalKernel/Bridge/*.lean | sort -u
     ```

  3. Confirm every external import is on the existing
     allowlist (`tcb_allowlist.txt`).
  4. Confirm no Bridge module appears in
     `Tools.Common.tcbInternalImports` (which enumerates the
     project-internal modules TCB-core files may import).

**Audit findings (2026-05-20).**

The Bridge layer's direct import set is entirely
**project-internal**: every Bridge module imports only other
`LegalKernel.*` modules.  No new external Std-library or
batteries imports are introduced.  The transitive closure
through `Kernel.lean` brings `Std.Data.TreeMap` (already on
the allowlist) and the Lean-core distribution (out of scope
per the audit method).

  * `lake exe tcb_audit` — PASS (2 TCB modules; allowlist has
    1 entry; every TCB import is allowlisted).
  * `tcb_allowlist.txt` — **unchanged** (no new entries).
  * `Tools.Common.tcbInternalImports` — **unchanged**
    (`LegalKernel.Kernel`, `LegalKernel.RBMapLemmas` only).
  * No Bridge module imports `Std.*` directly other than
    through `LegalKernel.Kernel` / `LegalKernel.RBMapLemmas`,
    which already inherit `Std.Data.TreeMap` from the
    allowlist.

**Per-Bridge-module Std-surface (informational).**

Reuses the existing Phase-3 / Phase-4 surface; no new Std
lemmas beyond what is documented in "Later phases
(informational)" above.

  * `Bridge/AddressBook.lean` — `Std.TreeMap` over
    `EthAddress = Fin (2^160)` (forward + reverse).
  * `Bridge/State.lean` — `Std.TreeMap` over
    `DepositId = Nat` (consumed) and
    `WithdrawalId = Nat` (pending).
  * `Bridge/WithdrawalRoot.lean` — `Vector ByteArray smtHeight`
    (Lean core, not `Std.TreeMap`).
  * `Bridge/Eip712.lean` — pure byte-arithmetic; no `Std.TreeMap`.
  * `Bridge/BridgeActor.lean` /
    `Bridge/Admissible.lean` /
    `Bridge/Accounting.lean` — pure data + algebraic; no new
    `Std.TreeMap` surface.

**Two-reviewer gate status.**  Per WG.5's acceptance criteria,
the two-reviewer gate is triggered if and only if
`tcb_allowlist.txt` or `Tools.Common.tcbInternalImports`
changes.  Neither changed; the gate is **NOT triggered** for
WG.5.

**Re-audit obligation.**  A toolchain bump or a new Bridge
module added under `LegalKernel/Bridge/*.lean` must re-run
this audit by:

  1. Re-running `lake exe tcb_audit` (must remain PASS).
  2. Grep-ing the new Bridge module's imports for any
     external (non-`LegalKernel.*`) entries.
  3. If a new external import is needed, it lands in a
     separate two-reviewer PR that updates both
     `tcb_allowlist.txt` AND this section.

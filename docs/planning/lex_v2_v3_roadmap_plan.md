<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Lex v2 / v3 — Forward Roadmap Plan

This document plans the post-M3 evolution of the Lex
law-declaration language: the v2 milestone (medium-effort
capability additions) and the v3 milestone (long-horizon
substantive extensions).  M1, M2, and M3 are complete per
CLAUDE.md.

The audit identified 16 forward-roadmap items + 6 deferred lint
codes from `docs/planning/lex_implementation_plan.md` and
`docs/law_language_design.md`.  This document groups them into
coherent landing milestones, sequences them, and specifies
acceptance criteria for each.

## Status

  * **Workstream prefix:** `LX2` (v2) and `LX3` (v3).
  * **Effort estimate:** v2 ≈ 8–12 calendar weeks for one
    full-time Lex engineer; v3 ≈ 16–24 calendar weeks (open-
    ended; depends on whether the resource-roles design lands
    fully).
  * **Build-posture target:** all Lex audit binaries
    (`lex_lint`, `lex_codegen --check`) remain green throughout;
    no new sorries; no axiom introductions.
  * **TCB delta:** zero.  All Lex extensions live in
    `Lex/DSL/`, `Lex/Tools/`, `Lex/Bin/` (non-TCB).
  * **Trust-assumption delta:** zero.

## Table of contents

  * §1 Milestone summary (v2 and v3 scopes)
  * §2 v2 work-unit specifications (LX2.1 – LX2.7)
  * §3 v3 work-unit specifications (LX3.1 – LX3.6)
  * §4 Deferred lint-code roadmap (the 6 deferred L-codes)
  * §5 Sequencing and PR structure
  * §6 Quality gates
  * §7 Risk register
  * §8 Acceptance criteria
  * §9 References

## §1 Milestone summary

### v2 scope (medium-effort additions)

| ID | Description | Source |
|----|-------------|--------|
| LX2.1 | Refinement direction: weakening `pre` under author opt-in | `law_language_design.md` §14.1 |
| LX2.2 | Compositional property dispatch over fold-of-flow | §14.4 |
| LX2.3 | Deployment-ID derivation sub-language | §14.6 |
| LX2.4 | `@[lex_pre]` decidability auditing | §14.8 |
| LX2.5 | Signer-identity strengthening lift | §14.9 |
| LX2.6 | Auto-generate property tests *default-on* | LX.38 wiring |
| LX2.7 | Manifest-attestor signing flow | post-M3 |

### v3 scope (substantive extensions)

| ID | Description | Source |
|----|-------------|--------|
| LX3.1 | Resource-role phantom-typed wrappers | `law_language_design.md` §6.7 + §14.7 |
| LX3.2 | LSP integration | `law_language_design.md` §9.5 |
| LX3.3 | `Action.revokeKey` constructor + L022 enablement | kernel amendment |
| LX3.4 | Arbitrary registry-mutating laws + L012 enablement | beyond `replaceKey` / `registerIdentity` |
| LX3.5 | Cross-law invariant synthesis | §14.3 |
| LX3.6 | Property-test seed reproducibility | §14.5 |

### Deferred-lint-code roadmap (6 codes)

| Code | Description | Target milestone |
|------|-------------|------------------|
| L012 | Registry-mutating law beyond `replaceKey`/`registerIdentity` | v3 (LX3.4) |
| L015 | `intent` block edited without version bump | M3+ |
| L017 | Major version bump without action-index reservation | M3+ |
| L019 | `for x in <iter>:` iter not statically `List α` | M2-extension or v2 |
| L021 | Law has no kernel-impl or authority effects | M3+ |
| L023 | `impl` calls helper not tagged `@[lex_impl]` | M2-extension or v2 |

L019 and L023 are scoped for an "M2-extension" PR: smaller
than v2 but bigger than a bug-fix.  See §4.

## §2 v2 work-unit specifications

For each LX2.k, the format mirrors the audit-remediation plan:
finding map, scope, math/proof outline (where applicable),
implementation steps, acceptance criteria, test plan,
DoD, verification, reviewer checklist, risk, effort.

---

### LX2.1 — Refinement direction: weakening `pre` under author opt-in

**Finding map.**  `law_language_design.md` §14.1.

**Scope.**  `Lex/DSL/Law.lean`; `Lex/Tools/Diff.lean`;
`Lex/Test/DSL/Refinement.lean` (new).

**Background.**  Today, a law's `pre` may only be *strengthened*
across version bumps (more conditions → more refined refinement).
v2 permits *weakening* (loosening preconditions) but only when
the author opts in via a `@weakening_allowed` annotation, with
the diff tool flagging it as a "major" semantic change.

**Implementation steps.**

  1. Add `@weakening_allowed` macro-level annotation parsed by
    the `lexlaw` macro.
  2. Extend `lex_diff` to detect `pre`-weakening; classify as
    "major" unless `@weakening_allowed` is set on both versions.
  3. Add test fixtures: a sample law with weakening + opt-in
    annotation; a law with weakening without annotation
    (must trigger `lex_diff` rejection).

**Acceptance criteria + DoD.**  Standard pattern.

**Risk.**  Low.

**Effort.**  ~5 engineer-days.

---

### LX2.2 — Compositional property dispatch over fold-of-flow

**Finding map.**  `law_language_design.md` §14.4.

**Scope.**  `Lex/DSL/Property.lean`; tests under
`Lex/Test/DSL/Property.lean`.

**Background.**  M3's property synthesizer ships per-law-class
dispatch (conservation / monotonicity / locality / freeze /
registry).  Distributive laws like `distributeOthers` and
`proportionalDilute` fold over multiple sub-actions; the v1
synthesizer falls back to `proof` overrides for these.  v2
synthesises the fold composition automatically.

**Math / proof outline.**

For a law that folds over `List α` applying a sub-law to each
element:
  - If the sub-law is `IsConservative`, the fold is `IsConservative`.
  - Same for `IsMonotonic`, `LocalTo`, `FreezePreserving`.
  - The synthesizer emits the fold-composition proof via a
    standard induction-over-`List` template.

**LX2.2 decomposes into five sub-sub-units:**

#### LX2.2.a — Fold-pattern AST detector

  * Walk the law's `impl` Lean term.
  * Detect the shape `xs.foldl (fun acc x => g x acc) init`
    or `xs.foldr (...)`.
  * If detected, extract `g`, `init`, `xs` for the dispatcher.
  * **Failure mode:** false negative (fold not detected) →
    fall back to v1 `proof` override (safe).
  * **Failure mode:** false positive (non-fold matches the
    shape) → dispatcher's emitted proof fails to type-check
    → user sees error → manual fix.

**Effort.**  ~2 engineer-days.

#### LX2.2.b — Per-property fold-composition templates

For each property class, ship a fold-composition theorem
template:

  * **Conservation:**
    `theorem fold_conserves : (∀ x acc, IsConservative (g x acc)) →
                              IsConservative (xs.foldl g init)`
  * **Monotonicity:**
    `theorem fold_monotonic : (∀ x acc, IsMonotonic (g x acc)) →
                              IsMonotonic (xs.foldl g init)`
  * **Locality:** similar.
  * **Freeze-preservation:** similar.
  * **Registry-preservation:** similar.

Each template lives in `Lex/DSL/Property/FoldTemplates.lean`
(new).

**Effort.**  ~3 engineer-days.

#### LX2.2.c — Dispatcher integration

  * Extend `synthProperty` in `Lex/DSL/Property.lean` with a
    `fold_composition` arm.
  * When the AST detector (LX2.2.a) succeeds AND the sub-law
    `g` has the property classification, emit the fold-
    template invocation.
  * Otherwise: fall back to existing per-law dispatch or
    `proof` override.

**Effort.**  ~2 engineer-days.

#### LX2.2.d — Migrate `distributeOthers` + `proportionalDilute`

  * These currently use `proof` overrides for conservation.
  * Remove the overrides; verify the synthesizer emits the
    fold-template-based proof correctly.
  * Byte-equality check: the synthesized proof should be
    semantically equivalent to (though not byte-equal to) the
    manual proof.

**Effort.**  ~2 engineer-days.

#### LX2.2.e — Test fixtures + regression suite

  * Positive: 5 test laws with fold structure; assert
    synthesizer succeeds.
  * Negative: 3 non-fold laws that *look like* folds; assert
    synthesizer doesn't false-positive.
  * Property test: random fold-shaped laws; synthesizer never
    silently emits a wrong proof.

**Effort.**  ~1 engineer-day.

---

#### LX2.2 — Rolled-up

**Aggregate effort:** ~10 engineer-days (matches prior).

**Risk.**  Medium.  Fold detection is brittle.  Mitigation:
fall-back to v1 is always safe.

---

### LX2.3 — Deployment-ID derivation sub-language

**Finding map.**  `law_language_design.md` §14.6.

**Scope.**  `Lex/DSL/Deployment.lean`; new
`Lex/DSL/DeploymentIdDerivation.lean`.

**Background.**  Today, deployments hard-code a 32-byte
`deploymentId` literal.  v2 introduces a small derivation
sub-language: `deploymentId = derive { chainId: ..., epoch:
..., name: ... }`.  The derivation function is deterministic
and lands on-chain at deployment time.

**Implementation steps.**

  1. Define `DeploymentIdInput` structure with fields for
    `chainId`, `epoch`, `name`, plus any deployment-specific
    extension.
  2. `derive : DeploymentIdInput → ByteArray` using keccak256
    of the structure's canonical CBE encoding.
  3. Lex DSL: `deployment_id = derive_from { chainId: 1,
    name: "my-deployment", epoch: 0 }` clause.
  4. Compile to a `let deploymentId := ...` Lean binding.

**Acceptance criteria.**

  * Two equal-input derivations produce byte-equal IDs.
  * `lex_diff` flags any change to the derivation inputs as
    "major".

**Risk.**  Low.

**Effort.**  ~5 engineer-days.

---

### LX2.4 — `@[lex_pre]` decidability auditing

**Finding map.**  `law_language_design.md` §14.8.

**Scope.**  `Lex/DSL/Law.lean`; new attribute machinery.

**Background.**  The `@[lex_pre]` attribute marks a Lean
predicate as a "law precondition".  v1 trusts the author to
supply a `Decidable` instance.  v2 synthesises one
automatically for "representative inputs" and checks it
elaborates.

**Implementation steps.**

  1. Add `@[lex_pre]` attribute that triggers a synthesised
    `Decidable` derivation at elaboration time.
  2. If derivation fails (the predicate uses a non-`Decidable`
    construct), emit a `lex_lint` warning code L024.
  3. Test fixtures: a predicate using only `Decidable` Nat
    operations passes; a predicate using a classical `Set`
    membership fails with L024.

**Risk.**  Medium.  `Decidable` synthesis can interact poorly
with hand-written instances.

**Effort.**  ~7 engineer-days.

---

### LX2.5 — Signer-identity strengthening lift

**Finding map.**  `law_language_design.md` §14.9.

**Scope.**  `Lex/DSL/Property.lean`; `LegalKernel/Authority/`
(if a kernel-level lift is needed — would trigger §13.6 two-
reviewer rule).

**Background.**  v1 ships a shim-layer signer-identity check.
v2 considers a kernel-level lift so the `signedBy` machinery
becomes a first-class property the synthesizer can reason
about.

**Implementation steps.**

  1. Audit the existing shim in `Lex/DSL/Shim.lean`.
  2. Decide whether a kernel-level lift is justified;
    document the cost-benefit.  If yes, plan a separate
    PR following the §13.6 two-reviewer process.
  3. If no, ship the shim-layer enhancement only:
    `signedBy` becomes a `lex_pre`-eligible predicate.

**Risk.**  Medium-high.  Possible TCB touch.

**Effort.**  ~5 engineer-days for shim; +10–15 if kernel-level.

---

### LX2.6 — Auto-generate property tests default-on

**Finding map.**  LX.38 wiring (`lex_implementation_plan.md`
line 283).

**Scope.**  `Lex/Bin/Codegen.lean`; default flag flip.

**Background.**  LX.38 shipped the property-test-generator
skeleton.  v1 default is opt-in via `--gen-property-tests`.
v2 default is on.

**Implementation steps.**

  1. Flip the default in `Lex/Bin/Codegen.lean`.
  2. Add `--no-gen-property-tests` opt-out flag.
  3. Update CI to run `lex_codegen` without the flag (the
    new default).

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

---

### LX2.7 — Manifest-attestor signing flow

**Finding map.**  `lex_implementation_plan.md` line 284.

**Scope.**  `Lex/Bin/Codegen.lean`; new
`Lex/Bin/ManifestAttestor.lean`.

**Background.**  v1 deployment manifests live as checked-in
source files.  v2 introduces an attestor-signing flow: a
governance signer signs the manifest hash and the signature
gets bundled with the deployment.

**Implementation steps.**

  1. Define a `Manifest` type with `hash` + `attestation`
    fields.
  2. New `canon manifest sign --key <hex>` CLI subcommand
    producing a signed manifest.
  3. New `canon manifest verify` subcommand.
  4. Lex DSL clause: `manifest_attestor = <ActorId>`.

**Risk.**  Low.

**Effort.**  ~5 engineer-days.

---

## §3 v3 work-unit specifications

---

### LX3.1 — Resource-role phantom-typed wrappers

**Finding map.**  `law_language_design.md` §6.7 and §14.7.

**Scope.**  `LegalKernel/Resource/Role.lean` (new); Lex DSL
extension.

**Background.**  v1 represents resources as flat `ResourceId`s.
v3 introduces *role-typed* resources: `Roled "stablecoin" (id)
: Roled "stablecoin"`.  The phantom-type parameter prevents
accidental cross-role flows (e.g. transferring a stablecoin to
a governance role).

**Design sketch.**

```lean
structure Roled (ρ : RoleName) where
  id : ResourceId
  deriving DecidableEq, Repr

instance : Coe (Roled ρ) ResourceId := ⟨Roled.id⟩
```

Lex DSL extension:

```lex
law transferStable {
  ...
  resource: Roled "stablecoin"
  ...
}
```

The Lex synthesizer enforces that any flow `from : Roled "stable" → to : Roled "stable"` typechecks; cross-role flows fail elaboration.

**LX3.1 decomposes into seven sub-sub-units:**

#### LX3.1.a — `RoleName` + `Roled` type infrastructure

  * `RoleName : Type` — implemented as `String` with
    `DecidableEq` (alternative: `Nat` index; `String` is
    chosen for readability).
  * `structure Roled (ρ : RoleName)` with one field
    `id : ResourceId`.
  * `instance : DecidableEq (Roled ρ)`,
    `instance : Repr (Roled ρ)`.
  * `instance : Coe (Roled ρ) ResourceId` for backwards-
    compat.

**Effort.**  ~3 engineer-days (universe-inference debugging
typically eats time here).

#### LX3.1.b — Role-coherent flow operations

  * `Roled.transfer : Roled ρ → Roled ρ → Amount → …`
    (only same-role transfers compile).
  * `Roled.mint : Roled ρ → Amount → …`.
  * `Roled.burn : Roled ρ → Amount → …`.

**Effort.**  ~2 engineer-days.

#### LX3.1.c — `lex_law` macro: `resource: Roled "X"` clause

  * Parse the clause.
  * Synthesize per-clause read of `s.balances[Roled ρ a r]?`.

**Effort.**  ~3 engineer-days.

#### LX3.1.d — Cross-role flow detection lint L025

  * New lint code L025: emitted if a law's `impl` moves
    `Roled "X"` value into a `Roled "Y"` slot.
  * AST-walk: detect `mint`/`burn`/`transfer` calls whose
    role-type arguments don't match.
  * Documented in `Lex/Tools/Lint.lean`.

**Effort.**  ~3 engineer-days.

#### LX3.1.e — Backwards-compatibility shim

  * Existing un-roled laws keep working: every `ResourceId`
    is "implicitly Roled with the default role".
  * Migration path: new laws declare roles; old laws
    deprecation-warn after a transition period.

**Effort.**  ~2 engineer-days.

#### LX3.1.f — Demonstration: `transferStable` example

  * Ship `Lex/Examples/StablecoinRole.lean`.
  * Two role-typed resources (`Roled "stable"`,
    `Roled "governance"`); attempted cross-role transfer
    fails elaboration with L025.

**Effort.**  ~2 engineer-days.

#### LX3.1.g — Test suite + documentation

  * Positive tests (same-role flows compile).
  * Negative tests (cross-role flows reject with L025).
  * Documentation update in `lex_amendment_walkthrough.md`.

**Effort.**  ~3 engineer-days.

---

#### LX3.1 — Rolled-up

**Aggregate effort:** ~18 engineer-days (within 15–25 range).

**Risk.**  High.  Phantom-types in Lean can interact poorly
with universe inference; LX3.1.a budgets explicit time for
debugging.

---

### LX3.2 — LSP integration

**Finding map.**  `law_language_design.md` §9.5.

**Scope.**  New `Lex/LSP/` sub-tree; Lean LSP-server extension.

**Background.**  v3 ships an LSP server for Lex providing
error squiggles, hover docs, go-to-impl, markdown-rendered
diagnostics.

**LX3.2 decomposes into six sub-sub-units:**

#### LX3.2.a — Lean LSP API audit

  * Upstream Lean LSP server uses LSP protocol 3.x.
  * Audit: can we plug a custom command handler, or must we
    fork the LSP server?
  * Document findings.  If upstream blockers exist:
    contribute upstream first (a separate workstream).

**Effort.**  ~3 engineer-days.

#### LX3.2.b — Squiggles via `lex_lint`-as-LSP-server

  * Wrap `lex_lint` outputs in LSP diagnostic objects.
  * Stream over LSP connection.

**Effort.**  ~5 engineer-days.

#### LX3.2.c — Hover providers

  * On hover over a `lex_law` declaration, show:
    - Synthesised property classifications.
    - Linked headline theorem names.
    - Markdown-formatted docstring.

**Effort.**  ~5 engineer-days.

#### LX3.2.d — Go-to-impl

  * From a `lex_law` declaration, navigate to the
    elaborated Lean `Transition`'s file:line.

**Effort.**  ~4 engineer-days.

#### LX3.2.e — Code actions

  * Quick-fix: "weaken precondition" (insert `@weakening_allowed`).
  * Quick-fix: "extract proof override".

**Effort.**  ~5 engineer-days.

#### LX3.2.f — Editor integrations

  * VS Code extension manifest.
  * Test plan: vim, emacs, IntelliJ behaviour acceptable
    via the standard Lean LSP plumbing.

**Effort.**  ~5 engineer-days.

---

#### LX3.2 — Rolled-up

**Aggregate effort:** ~27 engineer-days (within 25–40 range).

**Risk.**  High.  LSP extension is a non-trivial standalone PR;
upstream Lean LSP changes may be required (LX3.2.a is the
audit gate).

---

### LX3.3 — `Action.revokeKey` constructor + L022 enablement

**Finding map.**  `Lex/DSL/ImplCalculus.lean:172`,
`docs/planning/lex_implementation_plan.md:5762`.

**Scope.**  `LegalKernel/Authority/Action.lean` (TCB-adjacent;
two-reviewer rule), `LegalKernel/Laws/RevokeKey.lean` (new),
`Lex/Tools/Lint.lean` (L022 promotion to implemented).

**Background.**  v1 supports `replaceKey` but not `revokeKey`;
Lex L022 rejects `revoke_key` usage with "deferred to v3".  v3
ships the kernel-side `Action.revokeKey` constructor + law,
then enables L022 as a regular lint code (not deferred).

**LX3.3 decomposes into seven sub-sub-units:**

#### LX3.3.a — `Action.revokeKey` constructor + index reservation

  * Reserve constructor index (consult `Lex.IndexRegistry.txt`
    for next free).
  * Add `Action.revokeKey (actor : ActorId)` to
    `Authority/Action.lean`.  **TCB-adjacent — two reviewers.**
  * Extend AR.5 regression with the new index.
  * Update Lex `IndexRegistry.txt` (append-only).

**Effort.**  ~1 engineer-day.

#### LX3.3.b — `revokeKey.law` definition

  * `LegalKernel/Laws/RevokeKey.lean` (new).
  * Pre: signer holds a key registered under their identity
    (the actor whose key is being revoked).
  * Apply: remove `(actor, _)` from `KeyRegistry`.

**Effort.**  ~1.5 engineer-days.

#### LX3.3.c — Lean theorems

  * `revokeKey_admissible_iff_signer_holds`.
  * `revokeKey_updates_registry`.
  * `revokeKey_preserves_balances` (and similar
    non-interference lemmas).

**Effort.**  ~2 engineer-days.

#### LX3.3.d — `Event.revokedKey` emission

  * Add to `Event` inductive (reserve index; extend AR.6
    regression).
  * Update `Events.extractEvents`.

**Effort.**  ~1 engineer-day.

#### LX3.3.e — L022 promotion

  * Move L022 from `deferredCodeRegistry` to implemented set
    in `Lex/Test/Tools/DiagnosticCoverage.lean`.
  * Update the `deferredCodeRegistry` size assertion.
  * Replace ImplCalculus.lean:172's error message with the
    new regular lint behaviour.

**Effort.**  ~1 engineer-day.

#### LX3.3.f — Lex DSL clause

  * `revokes_key { actor: <ActorId> }` clause synthesises
    the `Action.revokeKey` invocation.

**Effort.**  ~1 engineer-day.

#### LX3.3.g — Test suite

  * Positive: revoke-key happy path.
  * Negative: revoke without holding the key (rejected).
  * Cross-stack: confirm new constructor encodes / decodes.

**Effort.**  ~1.5 engineer-days.

---

#### LX3.3 — Rolled-up

**Aggregate effort:** ~9 engineer-days (within 7–10 range).

**Risk.**  Medium.  Kernel-touching change triggers §13.6
two-reviewer rule and a small Genesis-Plan amendment for the
new Action constructor.

---

### LX3.4 — Arbitrary registry-mutating laws + L012 enablement

**Finding map.**  `law_language_design.md` §6.7 / §14.1.

**Scope.**  Lex DSL extension; `Lex/Tools/Lint.lean` L012
promotion.

**Background.**  v1 admits only `replaceKey` and
`registerIdentity` as registry-mutating laws.  v3 admits
arbitrary registry mutations under the right
property-classification typeclasses (`RegistryPreserving` v.
`RegistryMutating`).

**Implementation steps.**

  1. Define `RegistryMutating` classification typeclass + law-
    set firewall.
  2. Add Lex DSL clauses `mutates_registry: true` /
    `preserves_registry: true`.
  3. Move L012 to implemented codes; emit only when the law
    declares neither classification.

**Risk.**  Medium.

**Effort.**  ~10 engineer-days.

---

### LX3.5 — Cross-law invariant synthesis

**Finding map.**  `law_language_design.md` §14.3.

**Scope.**  Lex DSL property block extension.

**Background.**  v1 properties are per-law-set; v3 admits
cross-law invariants (e.g. "no two laws grant the same minting
authority").

**Implementation steps.**

  1. Extend the property block syntax with `cross_law` clauses.
  2. Synthesize cross-law obligation: forall pairs of laws in
    the deployment set, the obligation must hold.
  3. Emit a new property-test variant.

**Risk.**  Medium-high.  N² scaling for cross-law checks.

**Effort.**  ~10 engineer-days.

---

### LX3.6 — Property-test seed reproducibility

**Finding map.**  `law_language_design.md` §14.5.

**Scope.**  `Lex/Bin/Codegen.lean` property-test runner.

**Background.**  v1 property tests use a non-reproducible
random seed (best-effort).  v3 records the seed in the test
output so failures can be replayed.

**Implementation steps.**

  1. Thread a `seed` parameter through property-test runners.
  2. Record `seed` in test output.
  3. CI capture for failure reproduction.

**Risk.**  Low.

**Effort.**  ~3 engineer-days.

---

## §4 Deferred lint-code roadmap

Deferred lint codes are listed in
`Lex/Test/Tools/DiagnosticCoverage.lean:206` (the
`deferredCodeRegistry`).  The roadmap:

### v2 M2-extension

  * **L019** (`for x in <iter>:` iter not statically `List α`):
    requires AST-parsing the `for` loop's iterator expression.
    Schedule alongside LX2.4 (decidability auditing).
  * **L023** (`impl` calls helper not tagged `@[lex_impl]`):
    requires AST-parsing function calls in `impl` bodies.
    Schedule alongside LX2.4.

### M3+ extensions

  * **L015** (`intent` block edited without version bump):
    requires `lex_diff` intent-edit detector.  Schedule as a
    `lex_diff` capability extension PR.
  * **L017** (major version bump without action-index
    reservation): requires `lex_diff` major-bump tombstone
    pattern.  Schedule as a `lex_diff` capability extension PR.
  * **L021** (law has no kernel-impl or authority effects):
    requires manifest-aware analysis.  Schedule alongside
    LX2.7 (manifest-attestor flow).

### v3

  * **L012** and **L022** are promoted to regular codes under
    LX3.4 and LX3.3 respectively.

When promoting a deferred code to implemented, the
`deferredCodeRegistry` shrinks by one and the implemented set
grows by one.  The disjointness gate test
(`Lex/Test/Tools/DiagnosticCoverage.lean:262`) catches any
accidental double-counting.

## §5 Sequencing and PR structure

### v2 sequence

```
LX2.6 (default-on flip; ~1 day)        — quick win, first
LX2.7 (manifest-attestor; ~5 days)
LX2.1 (refinement direction; ~5 days)
LX2.3 (deploymentId derivation; ~5 days)
LX2.4 (decidability auditing; ~7 days) — with L019 + L023 enable
LX2.2 (compositional property dispatch; ~10 days)
LX2.5 (signer-identity strengthening; ~5 days shim only)
```

Total: ~38 engineer-days ≈ 8 calendar weeks.

### v3 sequence

```
LX3.6 (property-test seed; ~3 days)              — quick win, first
LX3.3 (revokeKey + L022; ~10 days)               — kernel touch first
LX3.4 (registry-mutating laws + L012; ~10 days)
LX3.5 (cross-law invariant synthesis; ~10 days)
LX3.1 (resource-role wrappers; ~20 days)         — high research
LX3.2 (LSP integration; ~35 days)                — long horizon
```

Total: ~88 engineer-days ≈ 18 calendar weeks.

### Lint-code activation

L019, L023, L015, L017, L021 each land as part of their parent
v2 / M3-extension milestone.  Each landing PR must:
  - Move the code from `deferredCodeRegistry` to the
    implemented set.
  - Land a positive-coverage test (a fixture that triggers
    the code).
  - Land a negative-coverage test (a fixture that should not
    trigger the code).
  - Update `Lex/Test/Tools/DiagnosticCoverage.lean`'s "deferred
    set size" assertion to the new count.

## §6 Quality gates

  * `lake build`
  * `lake test`
  * `lake exe lex_lint`
  * `lake exe lex_codegen --check`
  * `lake exe lex_codegen --gen-property-tests` (LX2.6 onwards)
  * `lake exe count_sorries`
  * `lake exe deferral_audit`
  * Per-WU: the deferred-code-registry size assertion updates
    with each lint-code activation.

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| LX3.1 phantom-type elaboration regressions | High | Medium | Land behind a feature flag; revert path is to keep `Roled` as a wrapper without type-level enforcement |
| LX3.2 LSP server requires upstream Lean LSP changes | Medium | High | Audit upstream Lean LSP API at v3 design time; if upstream blockers, document and pursue upstream contribution |
| LX3.3 kernel touch for `Action.revokeKey` triggers two-reviewer + Genesis-Plan amendment | High | Low | Standard amendment process; budget reviewer time |
| LX2.2 fold detection misclassifies non-fold law as fold | Medium | Medium | Conservative classifier: false negatives are safe (fall back to `proof` override) |
| L019/L023 AST parsing has parser/lexer drift across Lean toolchain bumps | Medium | Medium | Pin the AST extraction path; re-verify on toolchain bumps |

## §8 Acceptance criteria

### v2 acceptance

LX2 is **complete** when:
  1. LX2.1 – LX2.7 ship.
  2. Default `lex_codegen --gen-property-tests` works.
  3. Manifest signing flow functional.
  4. L019 + L023 promoted from deferred to implemented.
  5. CLAUDE.md "Lex roadmap" note updated.

### v3 acceptance

LX3 is **complete** when:
  1. LX3.1 – LX3.6 ship.
  2. `Action.revokeKey` shipped (with kernel two-reviewer
    sign-off).
  3. L012 + L022 promoted to implemented.
  4. LSP integration usable in a Lean editor.
  5. CLAUDE.md "Lex roadmap" note updated.
  6. `deferredCodeRegistry` is empty.

## §9 References

  * `docs/planning/lex_implementation_plan.md` — M1 / M2 / M3 plan.
  * `docs/law_language_design.md` — v1 / v2 / v3 design notes.
  * `Lex/Test/Tools/DiagnosticCoverage.lean` —
    `deferredCodeRegistry` source of truth.
  * `Lex/DSL/Law.lean` — `lex_law` macro.
  * `Lex/Tools/Lint.lean` — lint code implementations.

---

**End of plan.**  Landing v2 closes the v2-tier roadmap; v3 is
substantive and may legitimately remain unfinished for several
release cycles.  Treat v3 as a research backlog informed by
deployment demand.

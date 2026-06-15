<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Lex Language Implementation (Workstream LX) — Engineering Plan

This document plans the engineering effort needed to implement
the **Lex** law-declaration language specified in
`docs/law_language_design.md`.  It is a roadmap, not a
specification; the formal surface remains
`docs/law_language_design.md`, and any divergence between the
two is to be resolved in favour of that document until Lex v1
lands, at which point this plan is closed and the design
document gains a §17 audit-1 changelog reflecting any
implementation-discovered corrections.

The motivating observation is that adding a new law to Knomosis
today requires **seven mechanical edits** across hand-written
modules (`Authority/Action.lean` constructor +
`compileTransition` branch + `Encoding/Action.lean`
encode / decode / fieldsBounded branches +
`Events/Extract.lean` event branch +
`Authority/SignedAction.lean`'s
`non_registry_mutating_preserves_registry` branch + at least
one classification instance under `Conservation.lean`
typeclasses).  Each edit is a *consequence* of a single
behavioural choice, but reviewers must currently keep the
seven artefacts in lock-step by hand.  Lex collapses this to
one declaration; the seven artefacts are emitted mechanically.

LX composes with the existing Phase-4 `Law.mk` macro
(`LegalKernel/DSL/Law.lean`, WU 4.9) — Lex is a strict
extension that deprecates and ultimately replaces that
primitive.  Phase-4's macro produces a `Transition` only;
Lex's `law` command produces a `Transition` *plus* an
`Action` constructor *plus* the five supporting branches
*plus* the classification instances.

LX is **non-TCB**.  Its elaborator is a Lean 4 macro family
plus two audit-style binaries (`lex_lint`, `lex_codegen`); the
trusted core (`Kernel.lean`, `RBMapLemmas.lean`) does not
grow.  Every Lex declaration produces output within the
existing surface; the language adds expressiveness, not
trust.

---

## Table of Contents

  * [Status](#status)
  * [§1 Goals and non-goals](#1-goals-and-non-goals)
  * [§2 Architectural overview](#2-architectural-overview)
  * [§3 Terminology and conventions](#3-terminology-and-conventions)
  * [§4 The action-index registry](#4-the-action-index-registry)
  * [§5 The codegen-input format](#5-the-codegen-input-format)
  * [§6 The `law` macro: parser and per-file elaboration](#6-the-law-macro-parser-and-per-file-elaboration)
  * [§7 The `pre` grammar enforcer](#7-the-pre-grammar-enforcer)
  * [§8 The `impl` calculus enforcer](#8-the-impl-calculus-enforcer)
  * [§9 Authority binding semantics (`signed_by`, `authorized_by`)](#9-authority-binding-semantics-signed_by-authorized_by)
  * [§10 The property synthesizer library](#10-the-property-synthesizer-library)
  * [§11 The `events` block elaborator](#11-the-events-block-elaborator)
  * [§12 The codegen pass (`lex_codegen`)](#12-the-codegen-pass-lex_codegen)
  * [§13 The `lex_lint` binary](#13-the-lex_lint-binary)
  * [§14 The `lex_diff` binary](#14-the-lex_diff-binary)
  * [§15 The `lex_format` binary](#15-the-lex_format-binary)
  * [§16 The `deployment` manifest macro](#16-the-deployment-manifest-macro)
  * [§17 Theorem inventory](#17-theorem-inventory)
  * [§18 Diagnostics catalogue](#18-diagnostics-catalogue)
  * [§19 Work-unit breakdown](#19-work-unit-breakdown) — LX.1 – LX.38 (M1: LX.1–LX.21; M2: LX.22–LX.30; M3: LX.31–LX.38)
  * [§20 Test plan](#20-test-plan)
  * [§21 Backwards compatibility](#21-backwards-compatibility)
  * [§22 Risks and open questions](#22-risks-and-open-questions)
  * [§23 Mathematical soundness statement](#23-mathematical-soundness-statement)
  * [§24 Acceptance criteria](#24-acceptance-criteria)
  * [Cross-references](#cross-references)
  * [Appendix A — Surface ↔ generated mapping cheat sheet](#appendix-a--surface--generated-mapping-cheat-sheet)
  * [Appendix B — Decidability discipline reminders](#appendix-b--decidability-discipline-reminders)
  * [Appendix C — Glossary](#appendix-c--glossary)
  * [Appendix D — Worked Lex law (full template)](#appendix-d--worked-lex-law-full-template)
  * [Appendix E — Audit-1 changelog](#appendix-e--audit-1-changelog)

## Status

> **Reconciliation status (2026-06-14): COMPLETE (M1–M3).**  Workstream
> LX shipped — the Lex DSL macro / synthesiser, the 17 re-expressed
> kernel laws, and the deployment-manifest + governance surface are all
> in `main` (CLAUDE.md roadmap: `LX-M1–M3 | Complete`).  Forward Lex
> evolution (v2 / v3) is tracked separately in
> `lex_v2_v3_roadmap_plan.md`.  This document is retained as the
> historical engineering record; the provenance notes below predate the
> landing and the later Workstream-GP work (which added action indices
> 19–24 to `Lex.IndexRegistry.txt`).

  * **Drafted on branch:** `claude/lex-implementation-planning-ZzOSx`.
  * **Phase prefix:** `LX` (Lex) — work units labelled `LX.1`
    … `LX.38` to disambiguate from the Genesis-Plan
    `Phase 1`/`Phase 2`/… numbering, from the Ethereum-
    integration `A`/`B`/`C`/`D` workstream prefixes, from the
    LP (actor-scoped policies) and PA (parameterized laws)
    workstream prefixes.  LX is parallel to, not a successor
    of, the Genesis-Plan Phase 7.
  * **Dependency on prior workstreams.**  LX assumes the
    post-Workstream-LP state of the codebase: the `Action`
    inductive ends at frozen index 16
    (`revokeLocalPolicy`); the `Event` inductive ends at
    frozen index 12 (`localPolicyRevoked`); the
    `AdmissibleWith` predicate carries six conjuncts
    (post-LP.7).  LX touches neither of these inductives in
    M1 (additive only); M2 may add new constructors via
    Lex declarations whose `action_index` allocates the
    next free slot (≥ 17 if PA has not landed; ≥ 18 if it
    has).  LX is **independent of PA**; the two workstreams
    can land in either order with cosmetic merge resolution
    on the next-free-index tracker.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit`, and the new `lake exe lex_lint`
    and `lake exe lex_codegen --check` all green throughout;
    **no new sorries**; **no new axioms**; **no expansion
    of the kernel TCB**; **no new `opaque` declarations**.
  * **TCB delta:** zero.  Every new module ships under
    `LegalKernel/DSL/`, `LegalKernel/Conservation.lean`
    (additive instances only), `LegalKernel/Laws/`
    (additive instances only on existing laws), `Tools/`,
    or `Deployments/` (new directory for manifests and
    Lex-defined deployment-private laws).  None touches
    `Kernel.lean` or `RBMapLemmas.lean`.
  * **Trust-assumption delta:** zero.  The `Verify` opaque
    is unchanged; `hashBytes` is unchanged; no new
    cryptographic primitives are introduced.
  * **Backwards-compat delta:** zero on the executable
    surface (the kernel-built-in laws produce the same
    `Transition` values, the same `Action` constructors at
    the same frozen indices, the same encoded bytes, the
    same emitted events, and the same classification
    instance witnesses) once M2 lands; the change is
    purely a relocation of authoring effort from
    hand-written modules to Lex declarations.  Until M2
    lands, the Lex language runs *in parallel* with the
    hand-written form: a deployment may opt in to Lex by
    writing `law` declarations alongside the existing
    artefacts (additive `lex_codegen` mode).
  * **Milestone status.**  M1, M2, and M3 are all
    **complete**.  M1 shipped the macro skeleton + property
    synthesizer.  M2 re-expressed all 17 kernel-built-in
    laws in `LegalKernel/Laws/Lex/<Law>.lean` with
    byte-equivalence verified by elaboration-time `rfl`-close
    `example`s + the run-time `laws-lex-m2` regression suite.
    M3 added deployment manifests, the `lex_diff` /
    `lex_format` governance tooling, and the
    `Deployments/Examples/UsdClearing.lean` worked example.
    The `kernelBuildTag` has since been bumped beyond
    `"knomosis-lex-m3-manifests"` to `"knomosis-fault-proof-migration"`
    (Workstream H landed downstream).  Per-WU completion
    narratives live in git history (`git log --grep="LX"`),
    not in this plan.
  * **Frozen indices reserved by this workstream:** none
    in M1 (no new `Action` or `Event` constructors).  M2
    leaves the existing 17 `Action` constructor indices
    (0..16) unchanged; the Lex re-expressions inhabit the
    same indices.  M3's example deployment-private law
    (`my_deployment.staking_lock`, §15.5 of the design
    document) is illustrative-only and is not registered
    in `Lex/IndexRegistry.txt`.

## §1 Goals and non-goals

### 1.1 What this plan delivers

After LX lands on top of Workstream LP, the following is
true:

  1. **A new `law <name>` Lean command** elaborates a
     human-readable law declaration into a complete bundle
     of (a) one `Transition` `def`, (b) one entry in the
     codegen-input directory, and (c) one
     classification-instance `def`/`instance` per item of
     the `satisfies` block.  See §6.
  2. **A new `deployment <name>` Lean command** elaborates
     a deployment manifest into a `Deployment` record + one
     `def` per `invariant_claims` item + a manifest-hash
     constant.  See §16.
  3. **An action-index registry** (`Lex/IndexRegistry.txt`)
     pins frozen wire indices to law identifiers and first-
     release tags.  Two laws sharing an index, or a law
     renumbering, fails the new `lex_lint` audit binary.
     See §4.
  4. **A codegen-input directory**
     (`Lex/Inputs/`) accumulates per-law JSON
     metadata that the `lex_codegen` build pass consumes to
     emit the cross-module artefacts (`Action`
     constructors, `compileTransition` branches, encoding
     branches, event branches, registry-preservation
     branches).  See §5.
  5. **Three new non-TCB typeclasses** (`LocalTo`,
     `FreezePreserving`, `RegistryPreserving`) added to
     `LegalKernel/Conservation.lean`, with instances for
     every existing kernel-built-in law.  These typeclasses
     mirror the §6.4.2 design-document signatures verbatim.
     See §7.1.
  6. **A property synthesizer library**
     (`Lex/DSL/Property.lean`) discharges seven
     property names (`conservative`, `monotonic`, `local`,
     `freeze_preserving`, `nonce_advances`,
     `registry_preserving`, plus user-defined via
     `proof <name> := …` overrides) by structural
     induction on the `impl` calculus.  See §10.
  7. **Two new audit binaries** (`lex_lint` and
     `lex_codegen`) ship under `Tools/`, follow the existing
     `Tools/CountSorries.lean` / `Tools/TcbAudit.lean`
     template, and are wired into CI as gating checks.  See
     §13 and §12.
  8. **Two further audit binaries** (`lex_diff` and
     `lex_format`) ship in M3, providing semantic diff and
     canonical-form rewriting respectively.  See §14, §15.
  9. **The 17 kernel-built-in laws are re-expressed in
     Lex** (M2).  The diff is removal of hand-written cases
     plus addition of the Lex declarations plus regenerated
     artefact files.  Every existing test passes
     byte-for-byte; the test count is unchanged; `#print
     axioms` on every kernel theorem still returns
     `[propext, Classical.choice, Quot.sound]`.  See §19.4.
  10. **Diagnostics L001–L027 are emitted with stable
      codes** at the surface-syntax source location, not at
      the macro-expanded Lean term.  The diagnostic-
      translation layer maps macro positions back to the
      user's `law` declaration.  See §18.
  11. **A worked example deployment**
      (`Deployments/Examples/UsdClearing.lean`,
      illustrative only) demonstrates a full manifest
      including `invariant_claims`, `deployment_id`, and a
      law set drawn from the kernel-built-in vocabulary.
      See §19.7.

### 1.2 What this plan explicitly does not deliver

This workstream **does not**:

  * **Modify any kernel-TCB module.**  All work happens in
    non-TCB modules (`DSL/`, `Conservation.lean` additive
    instances, per-law modules' classification additions,
    `Tools/`, `Deployments/`).
  * **Introduce new axioms or `opaque` declarations.**
    Every Lex-emitted theorem depends only on the standard
    Lean built-in axiom set (`propext`, `Classical.choice`,
    `Quot.sound`) — many depend on a strict subset.
  * **Change the on-disk log frame format.**  M2's
    re-expression of the kernel-built-in laws produces the
    identical CBE-encoded constructor tags at the identical
    frozen indices.  Pre-M2 logs decode under the post-M2
    build verbatim; post-M2 logs decode under any pre-M2
    build that has already been merged with M2.
  * **Change the `ExtendedState` shape.**  No new fields;
    no new admissibility conjuncts; no new mutation
    helpers.
  * **Change the `Admissible` / `AdmissibleWith` predicate.**
    Lex's `signed_by sender` strengthening is delivered as
    an additional propositional conjunct on the
    *generated `myLaw_apply` shim* (§9.1), not on
    `AdmissibleWith` itself.  V2 may lift this strengthening
    into the kernel (open question §22.9 of the design
    document); the v1 surface is unchanged.
  * **Add resource roles.**  `(r : ResourceId)` parameter
    bindings remain `Nat`-typed.  Phantom-typed `Roled ρ`
    wrappers are deferred to v3 (§6.7 of the design
    document).
  * **Permit deployment-private laws that do not appear
    in the global `Action` inductive.**  V1 only admits
    kernel-extension laws (`action_index ≥ 17`, all sharing
    the global `Action` type).  Per-deployment `Action`
    extension is a Phase-7 runtime-adaptor change.
  * **Admit registry-mutating laws beyond `replaceKey` and
    `registerIdentity`.**  The existing
    `applyActionToRegistry` covers exactly these two; Lex's
    `register_key` primitive emits an
    `Action.replaceKey`/`Action.registerIdentity`-shaped
    branch.  Arbitrary registry-mutating laws are deferred
    to v3 (`L012` rejects them).
  * **Admit a `revoke_key` primitive.**  The kernel ships
    `KeyRegistry.revoke` as a function but no
    corresponding `Action` constructor; adding one is a
    kernel amendment, not a Lex feature (`L022` rejects
    use).  V3 may admit it once the corresponding
    `Action.revokeKey` constructor lands.
  * **Provide an LSP integration.**  Deferred to v3.
    Diagnostics in v1 / v2 surface via `lake exe lex_lint`
    output and through Lean's standard error stream.
  * **Auto-generate property tests by default.**  Skeleton
    landed in LX.38; default-on wiring deferred to v2.
  * **Provide a manifest-attestor signing flow.**  Deferred
    to v2.  V1 manifests are checked-in Lean source files
    whose identity is the source bytes plus the manifest
    hash `def`.
  * **Re-implement the kernel's threat model, TCB, or
    on-wire format.**  Lex strictly inherits all three.

### 1.3 The two-audience principle

A Lex law is *both* executable code (it runs in the runtime,
deterministically, against `ExtendedState`) and a governance
artefact (it is reviewed by people who decide whether it
encodes the policy they want).  Per design-document §2,
these audiences want incompatible things; Lex resolves the
tension by being a literate-program surface where the law
text is its own documentation.  Each law carries:

  * an `intent` block — versioned natural-language
    statement of intent, covered by the manifest's signed
    bytes (in v2);
  * the formal `pre` and `impl` clauses — the executable
    surface;
  * a `satisfies` block — the declarative bridge naming
    the formal properties the natural-language intent
    informally guarantees.

The reviewer reads `intent`, decides whether the bundle
correctly encodes it; the elaborator mechanically checks
`satisfies`.  Neither audience reads the other's material.
This is the central discipline LX implements; every other
choice in this plan ultimately serves it.


## §2 Architectural overview

### 2.1 Where this lives

LX's modules sit alongside the existing `LegalKernel/DSL/`
and `Tools/` directories, with strict dependency only on
modules that already exist (and on Workstream LP being
merged):

```
LegalKernel.Conservation                   (extended in LX.2: 3 new typeclasses + per-law instances)
LegalKernel.Laws.Transfer / Mint / Burn /  (extended in LX.2: typeclass instances)
                Freeze / Reward /
                DistributeOthers /
                ProportionalDilute /
                Deposit / Withdraw          ↓
                                            ↓
LegalKernel.DSL.Law                        (Phase-4 macro; preserved unchanged in M1, deprecated in M2)
                                            ↓
Lex.DSL.Law                     (LX.4; new — the `law` macro elaborator)
  ├── imports Conservation
  ├── imports DSL.Law (re-exports `Law.mk` for v1 callers)
  └── exports `law` syntax + per-file emission

Lex.DSL.Property                (LX.12; new — synthesizer library skeleton)
                                            (LX.13–16; filled in incrementally)
  ├── imports Conservation + Laws.* + LexLaw
  └── exports synthesizer-internal helpers

Lex.DSL.Deployment              (LX.31–33; new — `deployment` manifest macro)
  ├── imports Encoding.SignInput + LexLaw + LexProperty
  └── exports `deployment` syntax + `Deployment` record

Lex.Tools.Common                            (LX.4; new — shared parsing utilities)
  └── imports Tools.Common

Lex.Tools.Lint                              (LX.5; new — audit binary skeleton)
  └── imports Lex.Tools.Common

Lex.Tools.Codegen                           (LX.17–20; new — codegen binary built up incrementally)
  └── imports Lex.Tools.Common

Lex.Tools.Diff                              (LX.34–35; new — semantic-diff binary)
  └── imports Lex.Tools.Common

Lex.Tools.Format                            (LX.36; new — pretty-printer binary)
  └── imports Lex.Tools.Common

LegalKernel._lex_inputs/                   (LX.1; new directory — codegen-input metadata)
  ├── <one .json per Lex law, named by identifier>
  └── (consumed by Lex.Tools.Codegen)

Lex/IndexRegistry.txt                     (LX.1; new file — frozen action-index registry)

LegalKernel.lean                           (extended in LX.6 / LX.12 / LX.31:
                                                       re-export new modules)

Deployments/                               (LX.37; new directory — example deployments)
  └── Examples/UsdClearing.lean            (LX.37; illustrative manifest)

LegalKernel.Authority.Action               (regenerated in M2: Lex-derived constructor list)
LegalKernel.Encoding.Action                (regenerated in M2: Lex-derived encoding branches)
LegalKernel.Events.Extract                 (regenerated in M2: Lex-derived event branches)
LegalKernel.Authority.SignedAction         (regenerated in M2: Lex-derived non_registry_mutating branches)
```

Every dependency edge points downward toward existing
modules; no existing module gains an edge into a new module
beyond what `LegalKernel.lean` already does for umbrella
re-exports.  M2's regeneration of the four cross-module
artefacts is done by `lake exe lex_codegen`, not by Lean's
elaborator; the regenerated files are committed to the
repository so reviewers can diff them directly.

### 2.2 The user-visible model

The user-visible model is a single sentence:

> **A `law` declaration produces a complete, type-checked,
> property-bearing law artefact whose seven supporting
> branches are mechanically generated and CI-pinned to a
> frozen wire index.**

Every formal piece of this plan is an implementation
restatement of that sentence:

  * *"A `law` declaration produces a complete … law
    artefact"* — §6, the per-file macro.
  * *"... type-checked, property-bearing"* — §10, the
    property synthesizer library.
  * *"... whose seven supporting branches are
    mechanically generated"* — §12, the codegen pass.
  * *"... and CI-pinned to a frozen wire index"* — §4,
    the action-index registry plus §13, the lint binary.

### 2.3 The two-stage elaboration pipeline

A Lex `law` declaration elaborates via **two distinct
passes** that run at different times:

**Pass 1 (per-file macro):**  Runs at file-elaboration time
(`lake build` invokes Lean's elaborator on the file
containing the declaration).  Emits:

  1. one `def myLaw_transition : Transition` (or `(p₁ : T₁)
     → … → (pₙ : Tₙ) → Transition` for parameterised laws);
  2. one `def myLaw_intent : String := "<intent text>"`
     (preserved as Lean docstring on the transition);
  3. one `instance myLaw_<P>` per item in `satisfies`,
     each elaborated through the synthesizer library;
  4. one *codegen-input file* at
     `Lex/Inputs/<identifier>.json` capturing
     the declaration's metadata for Pass 2.

**Pass 2 (build-time codegen):**  Runs as `lake exe
lex_codegen` (invoked manually by the author and as a
`--check` gate by CI).  Reads every codegen-input file
under `Lex/Inputs/`, sorts by `action_index`,
and emits / regenerates:

  1. `LegalKernel/Authority/Action.lean`'s `Action`
     inductive constructor list;
  2. `LegalKernel/Authority/Action.lean`'s
     `compileTransition` function branches;
  3. `LegalKernel/Encoding/Action.lean`'s
     `Action.fieldsBounded`, `Action.encode`, `Action.decode`
     branches;
  4. `LegalKernel/Events/Extract.lean`'s `actionEvents`
     branches;
  5. `LegalKernel/Authority/SignedAction.lean`'s
     `non_registry_mutating_preserves_registry` and
     `applyActionToRegistry` branches.

In M1, Pass 2 operates in **append-only** mode: it writes
new branches at the end of each function, leaves the
existing hand-written branches verbatim, and emits a single
`-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED` fence per
file to demarcate generated content.  Manual edits *outside*
the fence are preserved across runs; manual edits *inside*
the fence are clobbered.

In M2, Pass 2 flips to **canonical regeneration**: every
branch (including the existing kernel-built-ins, now expressed
as Lex declarations) is regenerated.  The fence disappears;
the entire function body is generated.

This two-pass design is forced by Lean 4's macro architecture:
macros run per-file and cannot extend an inductive declared
in a sibling module.  The codegen pass is the project-internal
equivalent of `protoc` for protobufs or `bindgen` for Rust
FFI: it consumes a declarative source-of-truth and emits
boilerplate to language-specific files.

### 2.4 The strict-additive invariant (M1)

During M1 (LX.1 – LX.21), no existing kernel module is
modified beyond the *additive* additions explicitly called
out in each work unit's "files modified" section.  In
particular:

  * `LegalKernel/Authority/Action.lean`'s `Action`
    inductive is **not extended** in M1 (no new
    constructors).
  * `LegalKernel/Authority/Action.lean`'s
    `compileTransition` function is **not extended** in M1
    (no new branches).
  * `LegalKernel/Encoding/Action.lean`,
    `LegalKernel/Events/Extract.lean`, and
    `LegalKernel/Authority/SignedAction.lean` are **not
    extended** in M1 (no new branches).

The example Lex-only law landed at the M1 acceptance gate
(LX.21) inhabits a **fresh action index** (initially `17`,
or whichever is next-free after PA's potential merge), and
its supporting branches are appended via Pass 2's
append-only mode.  This is the first wire-extending change
LX makes.  Until LX.21, the on-wire format is byte-identical
to pre-LX.

### 2.5 The strict-equivalence invariant (M2)

During M2 (LX.22 – LX.30), every Lex declaration of a
kernel-built-in law produces a `Transition` `def`,
`Action` constructor, encoding branches, and classification
instances that are **definitionally equal**, **byte-
equivalent**, or **logically equivalent** (as appropriate
per artefact) to the pre-M2 hand-written form.  Concretely:

  * The `Transition.apply_impl` function is *definitionally
    equal* to the hand-written version, verified by `rfl`
    in a regression `example` in each Lex law file.
  * The `Action` constructor at index N has a wire encoding
    *byte-identical* to the pre-M2 form, verified by
    test-vector replay.
  * The classification instances (`IsConservative`,
    `IsMonotonic`, etc.) have *the same term-level type
    signature* as the pre-M2 hand-written versions; the
    instance bodies may differ (the synthesizer is
    permitted to choose its own proof script), but the
    Prop-level conclusions are unchanged.
  * Existing tests (`Test/Laws/Transfer.lean` etc.)
    continue to pass byte-for-byte without modification.

This invariant gates the M2 milestone: the migration is
considered failed if a single byte of the hand-written
artefacts changes (modulo formatting), and the rollback path
is `git revert`.  See §19.6 for the per-law acceptance
criteria.


## §3 Terminology and conventions

This section pins the names and concepts the rest of the
plan uses so reviewers don't have to chase terms.

### 3.1 Roles in the Lex pipeline

  * **Law author.**  The deployment engineer who writes a
    `law <name>` declaration in a `.lean` file under
    `LegalKernel/Laws/` (for kernel-built-ins) or
    `Deployments/<name>/Laws/` (for deployment-private
    laws, v3 only).  Reviews the elaborator's diagnostics
    and provides `proof <P>` overrides where the
    synthesizer cannot mechanically discharge a property.
  * **Manifest author.**  Writes a `deployment <name>`
    declaration referencing law identifiers from
    `Lex/IndexRegistry.txt`.  Selects the `invariant_claims`
    block that pins the deployment's safety properties.
  * **Reviewer.**  Reads the `intent` block, the
    `satisfies` list, and the manifest's
    `invariant_claims` block.  Trusts the elaborator's
    machine-checked discharge of synthesizer-level
    properties; reads `proof <P>` override bodies
    individually.
  * **Auditor.**  Runs `lake exe lex_lint`, `lake exe
    lex_codegen --check`, `lake exe lex_diff <a> <b>`
    against the repository to verify mechanical invariants
    (registry consistency, generated-artefact freshness,
    semantic-diff understandability).
  * **Counterparty.**  Verifies that an operator's
    deployed manifest matches what they signed against.
    In v1 this is by source-byte comparison of the manifest
    file plus its `<name>_manifest_hash` constant; in v2
    by attestor-signed manifest bytes.
  * **Operator.**  Runs the `knomosis` runtime CLI with a
    deployment manifest baked in.  Sees Lex only at deploy
    time (the runtime consumes the elaborated Lean
    declarations, not the surface text).

### 3.2 Concepts

  * **Law.**  A surface-level declaration introducing one
    new admissibility-checked state-transition rule.  Has a
    canonical identifier (e.g. `legalkernel.transfer`), a
    semver version, an `action_index`, an intent block,
    and a body of clauses.
  * **Action constructor.**  One arm of the
    `LegalKernel.Authority.Action.Action` inductive,
    indexed by a frozen wire tag.  Each Lex law produces
    exactly one constructor.  The current 17 kernel-built-in
    laws inhabit indices 0..16.
  * **Action index** (`action_index : Nat`).  The frozen
    wire tag.  Pinned in `Lex/IndexRegistry.txt`.  Cannot
    change without a Genesis-Plan amendment.
  * **Identifier** (`identifier : String`).  The canonical
    fully-qualified name of a law, e.g.
    `legalkernel.transfer` or `my_deployment.staking_lock`.
    Used as the key in `Lex/IndexRegistry.txt` and as the
    file name in `Lex/Inputs/`.
  * **Synthesizer.**  A function in `LexProperty.lean`
    that takes a parsed `impl` calculus and a property
    name, and emits a Lean `instance` declaration whose
    body discharges the property.  Synthesizers are
    *deliberately conservative* — they fail loudly rather
    than guess.
  * **`proof <P>` override.**  An author-supplied tactic
    block that replaces the synthesizer's body for a
    specific property.  Used when the synthesizer is too
    conservative (e.g. on fold-of-flow shapes like
    `distributeOthers`).
  * **Codegen-input file.**  A `Lex/Inputs/
    <identifier>.json` JSON document capturing the law's
    metadata.  Pass 1 emits one per law; Pass 2 reads them
    all to regenerate cross-module artefacts.
  * **`Lex/IndexRegistry.txt`.**  The checked-in
    append-only registry of `(identifier, action_index,
    first_release)` triples.  CI fails the build if a Lex
    law's declared `action_index` does not match the
    registry, or if two laws share an index.
  * **Manifest.**  A `deployment <name>` declaration
    binding a law set, an authority configuration, a
    deployment ID, and an `invariant_claims` block.
  * **`invariant_claims`.**  A list of declarative claims
    over the deployment's law set, e.g. `monotonic_law_set
    [Transfer, Mint, Freeze]`.  Each claim elaborates to
    a `MonotonicLawSet`-shaped value (or analogous);
    failure to discharge fails elaboration with diagnostic
    L008.
  * **Deployment ID** (`deployment_id : ByteArray`).
    32-byte unique identifier flowing into `signingInput`'s
    domain prefix (Audit-3.3/3.4) for cross-deployment-
    replay protection.

### 3.3 Naming conventions

In addition to CLAUDE.md's project-wide naming rules:

  * **Lex law identifiers** are dot-separated lowercase
    paths (`<organization>.<lawName>`).  The `legalkernel`
    organization prefix is reserved for the kernel-built-in
    laws.
  * **Lex constructor names** in the generated `Action`
    inductive are camelCase, derived from the Lex law name
    by lowercasing the first letter and stripping the
    organization prefix: `legalkernel.transfer` →
    `Action.transfer`, `my_deployment.staking_lock` →
    `Action.stakingLock`.
  * **Generated `def` and `instance` names** are
    `<lawIdentifier-with-dots-as-underscores>_<artefact>`,
    e.g. `legalkernel_transfer_isConservative` for the
    generated `IsConservative (Action.transfer …)` instance.
  * **Synthesizer functions** in `LexProperty.lean` are
    `synth_<propertyName>`, e.g. `synth_conservative`,
    `synth_monotonic`.

### 3.4 Build-time vs. elaboration-time

Many parts of LX run at distinct points in the build:

  * **Lean elaboration** runs whenever `lake build` types
    a `.lean` file containing a `law` declaration.  The
    per-file macro (Pass 1) runs here.
  * **`lake exe lex_codegen`** runs separately from
    `lake build`, typically invoked by the author after
    editing a `law` declaration and by CI's
    `--check` gate to verify the generated artefacts are
    up-to-date.  Pass 2 runs here.
  * **`lake exe lex_lint`** runs as a CI gate independent
    of `lake build`.  It walks `LegalKernel/Laws/` and
    `Deployments/`, parses the Lex declarations
    syntactically (string-level, no Lean elaboration),
    and emits diagnostics.
  * **`lake exe lex_diff <a> <b>`** runs on demand.  It
    takes two git refs, parses the Lex declarations at
    each, and emits a per-law / per-deployment semantic
    diff.

This separation is deliberate.  `lake build` must succeed
without `lex_codegen` having ever run *in M1* — the codegen
pass is *additive*, and a fresh checkout's `Action.lean`
already contains the kernel-built-ins.  `lake build` *will
require* `lex_codegen` to have run on the generated branches
*in M2* — because by that point the kernel-built-ins have
been removed from the hand-written file in favor of the
Lex declarations, and `lex_codegen` is the only path to a
buildable `Action.lean`.

CI runs both `lake build` and `lake exe lex_codegen --check`
on every PR; the latter ensures the committed generated
files match what `lex_codegen` produces from the current
Lex declarations.  Divergence fails diagnostic L026 and
the CI gate.

## §4 The action-index registry

`Lex/IndexRegistry.txt` is the project-wide source of
truth for the assignment of frozen wire tags to law
identifiers.  Its purpose is to prevent the
*action-index renumbering attack* — an accidental or
malicious renumbering that would silently re-route every
historical log entry's constructor lookup to a different
law, breaking replay determinism.

### 4.1 File format

```text
# Knomosis — Lex action-index registry
# Format: <identifier>  <action_index>  <first_release>
# Comments start with '#'.  Blank lines are ignored.
# Lines must be appended in increasing order of <action_index>.
# Renumbering or removing a non-trailing line is a build-failing
# violation (diagnostic L007).

legalkernel.transfer            0   v0.1.0
legalkernel.mint                1   v0.1.0
legalkernel.burn                2   v0.1.0
legalkernel.freezeResource      3   v0.1.0
legalkernel.replaceKey          4   v0.3.0
legalkernel.reward              5   v0.4.0-prelude
legalkernel.distributeOthers    6   v0.4.0-prelude
legalkernel.proportionalDilute  7   v0.4.0-prelude
legalkernel.dispute             8   v0.6.0
legalkernel.disputeWithdraw     9   v0.6.0
legalkernel.verdict            10   v0.6.0
legalkernel.rollback           11   v0.6.0
legalkernel.registerIdentity   12   v0.6.0+e-b
legalkernel.deposit            13   v0.6.0+e-c
legalkernel.withdraw           14   v0.6.0+e-c
legalkernel.declareLocalPolicy 15   v0.6.0+lp
legalkernel.revokeLocalPolicy  16   v0.6.0+lp
# (PA may insert applyParameterChange at 17 if it lands first.)
```

The file is **append-only**: existing lines are committed
forever; new laws append at the next free index.  A removed
law's line stays in place as a tombstone (the index is
permanently consumed).

### 4.2 Lint rules enforced over the registry

`lake exe lex_lint` checks (in roughly this order):

  1. **Increasing-index discipline.**  Indices must
     increment monotonically by 1.  A gap (e.g. 0, 1, 3
     missing 2) is rejected.  An out-of-order line is
     rejected.
  2. **No duplicate identifier.**  Each `identifier`
     appears exactly once (counting tombstones).
  3. **No duplicate index.**  Each `action_index`
     appears exactly once (so a tombstone consumes the
     slot forever).
  4. **Identifier format.**  Each `identifier` is a
     dot-separated lowercase path of two-or-more segments
     (`<org>.<name>`); each segment is `[a-z][a-zA-Z0-9_]*`.
  5. **Release-tag format.**  Each `first_release` matches
     `v[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9._-]+)?(\+[a-zA-Z0-9._-]+)?`
     (semver-like, with optional prerelease and metadata
     suffixes).
  6. **Cross-check against codegen-input.**  Every
     `Lex/Inputs/<identifier>.json` file's
     declared `action_index` matches the registry's
     entry for that identifier.  Divergence is L007.
  7. **Reservation of legalkernel range.**  The first
     17 indices (0..16) are reserved for
     `legalkernel.*` identifiers; a `non-legalkernel.*`
     identifier with `action_index < 17` is rejected
     with L006.

### 4.3 Lifecycle: adding a new law

To add a new law `my_deployment.foo`:

  1. Author writes a `law foo` declaration in a `.lean`
     file under `LegalKernel/Laws/Foo.lean` (or under
     `Deployments/<my_deployment>/Laws/Foo.lean` for
     deployment-private laws, v3).  Sets
     `action_index <next-free>`.
  2. Author appends a line to
     `Lex/IndexRegistry.txt`:
     `my_deployment.foo  <next-free>  v<current-release>`.
  3. `lake exe lex_codegen` reads the new codegen-input
     file and the registry; emits the new constructor at
     the registered index; regenerates the cross-module
     artefacts.
  4. `lake build` succeeds.
  5. `lake test` succeeds (the new law's
     `LegalKernel/Test/Laws/Foo.lean` exercises the
     property claims).
  6. `lake exe lex_lint` passes.
  7. `lake exe lex_codegen --check` passes (committed
     artefacts match generated).

### 4.4 Lifecycle: removing a law

To retire `legalkernel.reward`:

  1. The deployment manifest is amended to omit `Reward`
     from its `laws` block.  This is the deployment-side
     change and is the *primary* effect.
  2. The `legalkernel.reward` line in the registry stays
     in place forever as a tombstone.  Its
     `action_index = 5` is permanently reserved.
  3. The `Action.reward` constructor stays in the kernel
     forever (no removal from `Action`'s inductive,
     because that would break log-replay determinism for
     deployments that historically applied reward
     actions).
  4. New `SignedAction`s carrying `Action.reward` are
     rejected at admissibility time (the deployment no
     longer authorises them via its `AuthorityPolicy`).

This matches the design document's §8.3 sunset workflow.


## §5 The codegen-input format

### 5.1 Why a sidecar file format

Lean 4 macros run **per-file** and have no direct access to
declarations in sibling modules.  A `law` declaration in
`LegalKernel/Laws/Foo.lean` cannot reach into
`LegalKernel/Authority/Action.lean`'s `Action` inductive to
add a constructor.  The codegen-input format is the
sidecar: each Lex law's macro emits a JSON file capturing
the metadata `lex_codegen` needs to produce the cross-
module artefacts.

JSON is chosen for three reasons:

  1. **Tool independence.**  `lex_codegen` is a Lean
     binary today, but a future contributor could
     reimplement it in Rust / Python / awk without
     re-implementing a Lean macro parser.
  2. **Diff-friendliness.**  Generated artefacts go
     through `git diff`; JSON's line-oriented format
     produces clean diffs when a single law's metadata
     changes.
  3. **No new dependency.**  Lean core ships
     `Lean.Json`; a Lex macro can serialise to JSON
     without adding an external library.

### 5.2 Per-law schema

Each `Lex/Inputs/<identifier>.json` file has
the following shape:

```json
{
  "schema_version": 1,
  "identifier":     "legalkernel.transfer",
  "version":        "1.0.0",
  "action_index":   0,
  "intent":         "Move `amount` units of resource `r` ...",

  "params": [
    { "name": "r",        "type": "ResourceId",  "kind": "explicit" },
    { "name": "sender",   "type": "ActorId",     "kind": "explicit" },
    { "name": "receiver", "type": "ActorId",     "kind": "explicit" },
    { "name": "amount",   "type": "Nat",         "kind": "explicit" }
  ],

  "signed_by":     { "kind": "actorRef",   "name": "sender" },
  "authorized_by": { "kind": "policyRef",  "expr": "deployment.transfer_policy sender r" },

  "pre_ast": {
    "kind": "and",
    "left":  { "kind": "geNat", "left":  { "kind": "getBalance", "args": ["s","r","sender"] },
                                "right": { "kind": "var", "name": "amount" } },
    "right": { "kind": "gtNat", "left":  { "kind": "var", "name": "amount" },
                                "right": { "kind": "litNat", "value": 0 } }
  },

  "impl_calculus": [
    {
      "kind": "flow",
      "resource": "r",
      "amount":   "amount",
      "from":     "sender",
      "to":       "receiver"
    }
  ],

  "satisfies": [
    { "name": "conservative" },
    { "name": "monotonic" },
    { "name": "local",             "args": [["r"]] },
    { "name": "freeze_preserving", "args": [{"kind": "wildcard"}] },
    { "name": "nonce_advances",    "args": ["sender"] },
    { "name": "registry_preserving" }
  ],

  "events": [
    {
      "kind":     "let",
      "name":     "pre_sender",
      "body_ast": { "kind": "getBalance", "args": ["preState","r","sender"] }
    },
    {
      "kind":     "let",
      "name":     "pre_receiver",
      "body_ast": { "kind": "getBalance", "args": ["preState","r","receiver"] }
    },
    {
      "kind":      "ifEmit",
      "cond_ast":  { "kind": "gtNat", "left": { "kind": "var", "name": "amount" },
                                       "right": { "kind": "litNat", "value": 0 } },
      "ctor":      "balanceChanged",
      "args":      [
        { "kind": "var", "name": "r" },
        { "kind": "var", "name": "sender" },
        { "kind": "var", "name": "pre_sender" },
        { "kind": "subNat",
          "left":  { "kind": "var", "name": "pre_sender" },
          "right": { "kind": "var", "name": "amount" } }
      ]
    },
    {
      "kind":      "ifEmit",
      "cond_ast":  { "kind": "gtNat", "left": { "kind": "var", "name": "amount" },
                                       "right": { "kind": "litNat", "value": 0 } },
      "ctor":      "balanceChanged",
      "args":      [
        { "kind": "var", "name": "r" },
        { "kind": "var", "name": "receiver" },
        { "kind": "var", "name": "pre_receiver" },
        { "kind": "addNat",
          "left":  { "kind": "var", "name": "pre_receiver" },
          "right": { "kind": "var", "name": "amount" } }
      ]
    }
  ],

  "registry_effect": {
    "kind": "none"
  },

  "proof_overrides": [],

  "source_location": {
    "file":  "LegalKernel/Laws/Transfer.lean",
    "line":  142,
    "col":   3
  }
}
```

### 5.3 Schema fields, with semantics

  * `schema_version` — integer.  Bumped if the JSON shape
    changes incompatibly.  V1 is `1`.  `lex_codegen`
    refuses to consume files at an unknown version.
  * `identifier` / `version` / `action_index` / `intent` —
    direct projections of the user's `law` clauses.
  * `params` — ordered list of macro parameters (binders).
    `kind` is `"explicit"` (`(x : T)`), `"implicit"`
    (`{x : T}`), or `"strict_implicit"` (`⦃x : T⦄`).  This
    is what enables phantom-typed roles (§6.7 of design)
    in v3 without grammar changes.
  * `signed_by` — the bound actor name (a `params` entry's
    name) or a literal expression.  Drives the
    `st.signer = sender` strengthening of §9.1 and the
    `nonce_advances [sender]` synthesizer.
  * `authorized_by` — the policy expression.  Lex stores
    it as a *string*: the elaborator does not interpret
    the expression; it just substitutes it into the
    generated `myLaw_apply` shim.  This means an authority
    policy's term-level shape can change without
    regenerating Lex artefacts (so long as the shape
    remains a `Prop`-valued predicate of `(ActorId ×
    Action)`).
  * `pre_ast` — abstract syntax tree representing the
    `pre` clause.  Constructors mirror §6.1 of the
    design document: `and`, `or`, `not`, `ifte`, `geNat`,
    `gtNat`, `eqNat`, `neNat`, `eqActor`, `neActor`,
    `addNat`, `subNat`, `mulNat`, `divNat`, `modNat`,
    `getBalance`, `expectsNonce`, `forallIn`, `existsIn`,
    `userPred` (with a `name` field referring to a
    `@[lex_pre]`-tagged Lean identifier), `var`, `litNat`,
    `litBool`.  Used by:
    – the Pass-1 grammar enforcer (§7) to reject shapes
      outside the §6.1 grammar at the surface-syntax
      source location;
    – the synthesizer library (§10) to recognise `pre`
      patterns that imply specific properties (e.g.
      `mint`-on-frozen-resource is rejected by the
      `freeze_preserving` synthesizer because the `pre`
      contains no clause distinguishing frozen from
      unfrozen states; the law author must override).
  * `impl_calculus` — ordered list of statements per
    §6.2 of the design document.  Constructors:
    `flow`, `mint`, `burn`, `reward`, `freeze_resource`,
    `register_key`, `register_identity`, `for`, `if`,
    `let`, `bareTerm`.  The synthesizer dispatch table
    (§10.4) keys on `kind`.
  * `satisfies` — ordered list of property claims.  The
    `args` field holds property-specific arguments
    (e.g. `local [{r}]` has `args = [["r"]]`;
    `freeze_preserving [*]` has `args = [{"kind":
    "wildcard"}]`).
  * `events` — ordered list of event-block statements per
    §6.6 of the design document.  Constructors:
    `let`, `emit`, `ifEmit`, `for`.  `emit` has a `ctor`
    field (the `Event` constructor name) and `args`.
  * `registry_effect` — describes the law's authority-
    layer effect on `KeyRegistry`.  Constructors:
    `"none"` (no mutation; the law is `replaceKey`-
    preserving), `"replaceKey"` (with a target-actor
    name), `"registerIdentity"` (with target-actor and
    new-key names).  V1 supports only these three; v3
    will admit user-defined effects under L012.
  * `proof_overrides` — ordered list of `proof <P> := …`
    clauses.  Each entry has fields `property` (the
    property name being overridden) and `tactic_block`
    (the raw Lean tactic source, captured verbatim).
  * `source_location` — file/line/col of the originating
    `law` declaration.  Used by `lex_lint` and
    `lex_codegen` to emit diagnostics anchored at the
    user's surface syntax (not at the macro-expansion
    point).

### 5.4 Stability invariants

  * **Forward-compatibility.**  A new field added in a
    future schema version must default to a no-op
    semantics (so old codegen-input files keep working).
  * **Backward-compatibility.**  Removing a field is a
    `schema_version` bump.  The codegen binary ships with
    a per-version reader.
  * **Determinism.**  The macro emits codegen-input fields
    in canonical order (per the schema above).  `lex_codegen
    --check` compares JSON by parsed structure, not by
    surface bytes, so reformatting alone never causes a
    spurious divergence.
  * **No secrets.**  Codegen-input files are checked into
    the repository alongside the generated artefacts.
    They must never embed credentials, deployment keys, or
    other sensitive material; the `intent` block's prose
    is the only free-form field, and operators are
    expected to keep it human-language only.

### 5.5 Why not store the AST in Lean directly?

A natural alternative would be to store the AST as a Lean
inductive (`structure LawDecl`) checked into the kernel.
This was considered and rejected because:

  1. **Cross-module accumulation problem.**  The codegen
     pass needs *every* law's AST simultaneously to emit a
     single regenerated `Action.lean`.  Lean has no
     "accumulate all `LawDecl` values across modules"
     hook; manually building an `allLaws : List LawDecl`
     constant would itself require a build-time codegen
     step.  JSON sidekick files sidestep this.
  2. **`lex_codegen` independence.**  The codegen pass is
     a build *prerequisite* (in M2: without it, `lake
     build` cannot succeed).  If it depended on the
     output of `lake build` (to load `LawDecl` constants),
     we'd have a circular build dependency.
  3. **External-implementer tractability.**  A future
     deployment that wants to consume the manifest in a
     non-Lean host (Rust runtime adaptor, Python audit
     tool) needs a parser-friendly format.  JSON is the
     industry standard.

## §6 The `law` macro: parser and per-file elaboration

### 6.1 Surface syntax (recap from design doc §5)

```ebnf
law             ::= "law" ident "(" params ")" "where" clause+
params          ::= (binder ("," binder)*)?
binder          ::= ident+ ":" type

clause          ::= "identifier"   ident_path
                  | "version"      string_lit
                  | "action_index" nat_lit
                  | "intent"       md_block
                  | "signed_by"     actor_expr
                  | "authorized_by" policy_expr
                  | "pre"          ":=" pre_expr
                  | "impl"         ":=" impl_block
                  | "satisfies"    ":=" property_list
                  | "events"       ":=" event_block
                  | "proof"         ident ":=" tactic_block

ident_path      ::= ident ("." ident)*
md_block        ::= "{" raw_text_until_balanced_close "}"
```

The grammar is enforced by Lean 4 `syntax` declarations
inside `Lex/DSL/Law.lean`.  Per §16 of the
design document's audit-1 changelog, clause grammar is
fixed (no colon between `flow`'s resource and amount
arguments; bare-term escape hatch for `impl` is preserved
for v1, removed in v2).

### 6.2 Per-file elaboration steps

The `law` command's `elab_rules` block (using `command`
elaboration, which has full IO access via Lean's
`CommandElabM` monad — *not* `macro_rules` / `MacroM`,
which is restricted to pure syntax transformation) does
the following, in order, at file-elaboration time:

  1. **Parse all clauses** and bind them to a Lean-level
     `LawDecl` value.  This is an internal data type used
     only by the macro pipeline; it is not exported.
  2. **Validate clause presence.**  Every law must have
     `identifier`, `version`, `action_index`, `intent`,
     `signed_by`, `authorized_by`, `pre`, `impl`,
     `satisfies`.  `events` defaults to `[]` if omitted.
     `proof <P>` clauses are optional.  Missing required
     clauses are L001 / L002 / L009 errors.
  3. **Validate `pre` against the §6.1 grammar.**  Walks
     the elaborated `Term` and rejects nodes outside the
     restricted grammar (§7 of this plan).
  4. **Validate `impl` against the §6.2 calculus.**  Walks
     each statement's elaborated `Term` and rejects bare
     `setBalance` calls (L010), helpers not tagged
     `@[lex_impl]` (L023), and `revoke_key` invocations
     (L022).
  5. **Compute the `transition_def`.**  Builds a
     `Transition.mk pre decPre impl` term where:
     – `pre` is the user's `pre` expression elaborated as
       `State → Prop`;
     – `decPre := fun _ => inferInstance` (Genesis Plan
       §13.6 step 2);
     – `impl` is the user's `impl_block` elaborated to a
       `State → State` function via the §8 calculus
       desugaring.
  6. **Emit `def myLaw_transition`.**  Or, for
     parameterised laws, `def myLaw_transition (params...)
     : Transition := ...`.  The Lex law name's organization
     prefix becomes a Lean namespace path.
  7. **Emit `instance` declarations.**  One per
     `satisfies` item, dispatched through the property
     synthesizer library (§10).  If a `proof <P>` override
     exists, it is used as the instance body; otherwise
     the synthesizer's default body is emitted.
  8. **Emit the codegen-input file.**  The elaborator
     serialises the `LawDecl` value to JSON and writes it
     to `Lex/Inputs/<identifier>.json`.  The
     write is *deterministic*: equal `LawDecl` values
     produce byte-equal JSON.  The write happens via
     `IO.FS.writeFile` lifted into `CommandElabM` (the
     command-elaboration monad has full `IO` access,
     unlike `MacroM` which is restricted to pure syntax
     manipulation); because Lean elaborators may run more
     than once during incremental builds, the write is
     idempotent (compares structurally before writing —
     see §6.10).
  9. **Emit a `#check` for the registry consistency.**  A
     `#check_failure` line that fails if the registry's
     `(identifier, action_index)` does not match the
     declared values.  This is a compile-time assertion;
     `lake exe lex_lint` catches the same divergence with
     a more user-friendly diagnostic.

### 6.3 What the macro does *not* do

The per-file macro **does not**:

  * Emit any `Action` constructor (that's Pass 2 /
    `lex_codegen`).
  * Emit any `compileTransition` branch.
  * Emit any encoding / events / non-registry-mutating
    branch.
  * Modify any sibling module.
  * Read any file other than the one being elaborated
    plus (optionally) `Lex/IndexRegistry.txt` for the
    consistency `#check_failure`.
  * Run any tactic over `apply_admissible` shape.

The constraint is structural: Lean 4's `command`
elaboration (`CommandElabM`) admits full IO at file-
elaboration time, but it cannot extend an inductive
declared in a sibling module (Lean's elaborator is per-
file).  Lex's `law` keyword uses `elab_rules : command`
(or equivalently `elab "law" ... : command`) to obtain
both `CommandElabM`'s IO surface and per-file declaration
emission; the cross-module artefacts (Action constructor
list, encoding branches, etc.) are emitted by a separate
build-time binary (`lex_codegen`, §12) consuming the
codegen-input JSON files.

### 6.4 Per-file elaboration error conditions

  * **Lean 4 elaboration error inside `pre` / `impl` /
    `events`.**  Surfaced verbatim with the macro-
    expansion source location; the user sees both the
    Lean error and the Lex source location via the
    diagnostic-translation layer (§18.2).
  * **Missing required clause.**  L001 / L002 / L009
    error at the `law` keyword's source location.
  * **`pre` outside grammar.**  L003 error at the
    offending sub-expression's source location.
  * **Bare `setBalance` in `impl`.**  L010 error at the
    statement.
  * **`revoke_key` in `impl`.**  L022 error.
  * **`@[lex_impl]`-untagged helper called in `impl`.**
    L023 error.
  * **Property synthesizer failure with no `proof`
    override.**  L004 error naming the property and the
    law.
  * **`action_index < 17` for a non-`legalkernel.*`
    identifier.**  L006 error.
  * **`action_index` mismatch with registry.**  L007
    error.
  * **Codegen-input write failure.**  Surfaced as a Lean
    macro error; the build fails.
  * **Self-referential parameter bindings.**  Caught by
    Lean's standard binder hygiene; not a Lex-specific
    diagnostic.

### 6.5 Idempotency and incremental builds

Lean's incremental build re-elaborates a `.lean` file when
its bytes (or a transitive dependency's bytes) change.
Each re-elaboration runs the macro again, which in turn
re-writes the codegen-input file.  Two properties make
this safe:

  1. **Determinism.**  The macro's JSON output depends only
     on the `LawDecl` value, which depends only on the
     surface syntax.  Equal source produces equal JSON.
  2. **No clobbering of unchanged files.**  Before
     writing, the macro reads the existing file and
     compares its parsed JSON structure to the new one;
     if equal, the write is skipped (no `mtime` bump,
     so downstream targets don't re-fire).

This is consistent with the protobuf-codegen / bindgen-
style discipline familiar to readers of the Rust / Go
ecosystems.

### 6.6 Concrete Lean elaboration shape

The `law` keyword is a Lean 4 *command* declared in
`Lex/DSL/Law.lean` using `syntax` (for the
parse tree) plus `elab_rules : command` (for the
elaboration logic).  The choice of `elab_rules`
rather than `macro_rules` is deliberate: the elaboration
needs to write a JSON sidecar file at file-elaboration
time, which requires `CommandElabM`'s IO access; pure
`macro_rules` operates inside `MacroM`, which has no
unconstrained IO surface.  Skeleton:

```lean
namespace LegalKernel.DSL

set_option linter.missingDocs false in
syntax (name := lawCmd) "law" ident "(" Lean.Parser.Term.bracketedBinder,* ")"
  "where" lawClause+ : command

-- One `syntax` declaration per clause keyword:

set_option linter.missingDocs false in
syntax (name := identClause) "identifier" ident("." ident)* : lawClause

set_option linter.missingDocs false in
syntax (name := versionClause) "version" str : lawClause

set_option linter.missingDocs false in
syntax (name := actionIndexClause) "action_index" num : lawClause

set_option linter.missingDocs false in
syntax (name := intentClause) "intent" "{" intentBody "}" : lawClause

set_option linter.missingDocs false in
syntax (name := signedByClause) "signed_by" term : lawClause

-- ... (similar for the other 6 clause kinds)

elab_rules : command
  | `(law $name:ident ( $params:bracketedBinder,* )
      where $clauses:lawClause*) => do
        -- Inside `CommandElabM`: full IO is available via
        -- the `MonadLiftT IO CommandElabM` instance.
        -- Pass 1 elaboration (all 9 phases inlined for clarity;
        -- in the implementation this dispatches through helper
        -- functions per the §6.2 step list):
        let lawDecl ← parseLawDecl name params clauses
        validateRequiredClauses lawDecl
        validatePreGrammar lawDecl.preExpr
        validateImplCalculus lawDecl.implCalculus
        Lean.Elab.Command.elabCommand (← buildTransitionDef lawDecl)
        for inst in (← buildSatisfiesInstances lawDecl) do
          Lean.Elab.Command.elabCommand inst
        attachIntentDocstring lawDecl
        liftIO (writeCodegenInputIdempotent lawDecl)
        liftIO (verifyRegistryConsistency lawDecl)
        pure ()
```

`CommandElabM` is the canonical home for Lean 4 commands
that need to (a) emit multiple top-level declarations
into the surrounding namespace, (b) perform side-effecting
IO at elaboration time, and (c) emit diagnostics anchored
at user source positions via `Lean.Elab.Command.elabCommand`
plus `Lean.throwErrorAt`.  All three needs apply here.

The exact grammar for `intentBody` admits a balanced-
brace markdown block (Lean's `Parser.Term.bracketedBinder`
is the binder form for `params`).  Errors during any
phase emit a `Lean.MessageData` value anchored at the
relevant `Syntax` node's source position; the diagnostic-
translation layer (§18.2) handles the macro-expansion
cases.

### 6.7 Pass-1 state machine

The macro pipeline is conceptually a state machine
operating on a `LawDeclBuilder` value that accumulates
parsed clauses:

```
START → CLAUSE_PARSE → REQUIRED_CHECK → PRE_GRAMMAR → IMPL_CALCULUS
                                                              ↓
INTENT_DOCSTRING ← REGISTRY_WRITE ← INSTANCE_BUILD ← TRANSITION_BUILD
        ↓
       END
```

Each transition consumes some `Syntax` from the input
and produces `Lean.MessageData` (diagnostics) or extends
the `LawDeclBuilder`.  A failure in any phase short-
circuits the pipeline: the macro emits the diagnostic and
returns a `mkNullNode` so the surrounding file continues
to elaborate (with the `law` declaration acting as a no-op
on error).

This short-circuit-on-error semantics is important: a
single buggy `law` declaration in a file should not
prevent the rest of the file from elaborating.  The
diagnostic surface is uniform whether the failure is a
missing clause, a forbidden `pre` shape, or a synthesizer
failure.

### 6.8 Source-position propagation

Every `Syntax` node in Lean carries source-position
metadata via `Lean.SourceInfo`.  The `LawDeclBuilder`
preserves this metadata field-by-field:

```lean
structure ClauseSource where
  startPos : Lean.Position
  endPos   : Lean.Position
  fileName : System.FilePath

structure LawDeclBuilder where
  identifierClause   : Option (String × ClauseSource)
  versionClause      : Option (String × ClauseSource)
  actionIndexClause  : Option (Nat × ClauseSource)
  intentClause       : Option (String × ClauseSource)
  signedByClause     : Option (Lean.Term × ClauseSource)
  authorizedByClause : Option (Lean.Term × ClauseSource)
  preClause          : Option (PreNode × ClauseSource)
  implClause         : Option (List ImplStmt × ClauseSource)
  satisfiesClause    : Option (List PropertyClaim × ClauseSource)
  eventsClause       : Option (List EventStmt × ClauseSource)
  proofClauses       : List (Name × Lean.Syntax × ClauseSource)
```

When emitting a diagnostic, the macro consults the
relevant clause's `ClauseSource` and produces a
`Lean.MessageData` anchored at that location.  Lean's
elaborator surfaces the diagnostic at the user's `.lean`
file's exact line and column.

### 6.9 Pass-1 → Pass-2 data flow

The Pass-1 macro emits the codegen-input JSON file as
its primary cross-pass artefact.  Pass 2 (`lex_codegen`)
reads every JSON file under `Lex/Inputs/`
and produces the cross-module artefacts.

```
┌───────────────────────────────────────────────────────────────────┐
│                          Pass 1 (per-file)                        │
│                                                                   │
│  Lex .lean source ──► Lean macro ──► LawDecl ──► JSON sidecar     │
│                                ↓                                  │
│                       Transition def + instance decls             │
│                                ↓                                  │
│                       (visible to surrounding Lean code)          │
└───────────────────────────────────────────────────────────────────┘
                                ↓
                      Lex/Inputs/
                          *.json files
                                ↓
┌───────────────────────────────────────────────────────────────────┐
│                          Pass 2 (build-time)                      │
│                                                                   │
│  lex_codegen ──► loadCodegenInputs ──► [LawDecl] (sorted by idx)  │
│                                                ↓                  │
│                          generateAction / Encoding / Events /     │
│                          SignedAction renderers                   │
│                                                ↓                  │
│                     replaceFence / writeFiles                     │
│                                                ↓                  │
│             Authority/Action.lean, Encoding/Action.lean,          │
│             Events/Extract.lean, Authority/SignedAction.lean      │
└───────────────────────────────────────────────────────────────────┘
```

The two passes communicate **only via files**, never via
in-memory state.  This is what makes the pipeline robust
to incremental builds, caching, and concurrent
invocations: each pass is deterministic in its inputs,
and its inputs are addressable file-system paths.

### 6.10 Macro re-elaboration semantics

When a `.lean` file is incrementally re-elaborated
(because its bytes or a transitive dependency's bytes
changed), the macro re-runs and:

  1. Re-emits the `def myLaw_transition` (Lean uses its
     own definitional-equality check to verify this
     matches the previous declaration; if not, the file
     is genuinely changed).
  2. Re-runs `writeCodegenInputIdempotent`.  If the new
     `LawDecl` matches the existing JSON file, no write
     occurs.  If the new differs, the file is replaced
     atomically.

The atomic-replace strategy: write to
`<identifier>.json.tmp`, then rename to
`<identifier>.json`.  This guarantees that no partial-
file state is observable to a concurrent reader (e.g. a
parallel `lex_codegen` invocation).

### 6.11 Error recovery within a single file

If multiple `law` declarations exist in the same file,
each is elaborated independently.  An error in one does
not prevent the others from elaborating; the file's
overall build status is "success with diagnostics" iff
every law's macro completed successfully (even with
warnings).

The codegen-input sidecar files are written
*per-successful-law*: a failing law produces no JSON
file (the existing one, if any, is left alone — but a
subsequent `lex_lint` run will detect the
codegen-input-vs-source mismatch and fail).


## §7 The `pre` grammar enforcer

### 7.1 Why grammar enforcement matters

The Phase-4 `Law.mk` macro relies on Lean's instance
synthesizer to discharge `[DecidablePred pre]` for every
law.  When `inferInstance` fails, the user sees a sixty-line
elaboration trace ending in "failed to synthesize
Decidable", with no clear pointer to the offending sub-
expression.  This is the headline ergonomic complaint about
the Phase-4 surface; Lex's grammar enforcer exists to fix
it.

The enforcer runs *after* Lean elaborates the user's `pre`
clause to a `Term` value, but *before* the macro emits the
generated `def myLaw_transition`.  It walks the term tree,
classifying each node, and rejects unsupported shapes with
diagnostic L003 anchored at the offending sub-expression's
source location.

### 7.2 The grammar (formal)

The grammar is an inductive type
`PreNode` defined inside `Lex/DSL/Law.lean`:

```lean
inductive PreNode where
  | true_  : PreNode
  | false_ : PreNode
  | and    : PreNode → PreNode → PreNode
  | or     : PreNode → PreNode → PreNode
  | not_   : PreNode → PreNode
  | ifte   : PreNode → PreNode → PreNode → PreNode
  | leNat  : NatNode → NatNode → PreNode
  | ltNat  : NatNode → NatNode → PreNode
  | eqNat  : NatNode → NatNode → PreNode
  | neNat  : NatNode → NatNode → PreNode
  | geNat  : NatNode → NatNode → PreNode
  | gtNat  : NatNode → NatNode → PreNode
  | eqActor    : ActorNode    → ActorNode    → PreNode
  | neActor    : ActorNode    → ActorNode    → PreNode
  | eqResource : ResourceNode → ResourceNode → PreNode
  | neResource : ResourceNode → ResourceNode → PreNode
  | forallIn   : Name → BoundedIter → PreNode → PreNode
  | existsIn   : Name → BoundedIter → PreNode → PreNode
  | userPred   : Name → List Term  → PreNode    -- must be tagged @[lex_pre]
  deriving Repr

inductive NatNode where
  | lit    : Nat → NatNode
  | var    : Name → NatNode
  | add    : NatNode → NatNode → NatNode
  | sub    : NatNode → NatNode → NatNode
  | mul    : NatNode → NatNode → NatNode
  | div    : NatNode → NatNode → NatNode
  | mod    : NatNode → NatNode → NatNode
  | getBal : Term → Term → Term → NatNode    -- s, r, a; opaque to the enforcer
  | expectsNonce : Term → Term → NatNode     -- es, a; opaque
  | userFn : Name → List Term → NatNode      -- must be tagged @[lex_pre]
  deriving Repr

-- (ActorNode, ResourceNode similar; just lit / var.)

inductive BoundedIter where
  | toListExpr : Term → BoundedIter           -- caller's responsibility that it's finite
  deriving Repr
```

### 7.3 The walk

The enforcer is a function

```lean
partial def parsePreExpr (preTerm : Term) : Except (Position × String) PreNode
```

that pattern-matches on Lean's `Term` shape:

  * `Term.const ``True _` → `PreNode.true_`
  * `Term.const ``False _` → `PreNode.false_`
  * `Term.app (Term.app (Term.const ``And _) lhs) rhs`
    → `PreNode.and (parsePreExpr lhs) (parsePreExpr rhs)`
  * `Term.app (Term.app (Term.const ``Nat.le _) lhs) rhs`
    → `PreNode.leNat (parseNatExpr lhs) (parseNatExpr rhs)`
  * (similar for the ten Nat / Actor / Resource comparators)
  * `Term.app (Term.app (Term.const ``getBalance _) s) r) a`
    → `NatNode.getBal s r a`
  * `Term.lambda ...` outside an `∀ x ∈ list, ...` shape →
    L003 error
  * `Term.app (Term.const userFn _) args` where `userFn` is
    not tagged `@[lex_pre]` → L003 error
  * `Term.app (Term.const userFn _) args` where `userFn` is
    tagged `@[lex_pre]` → `PreNode.userPred userFn args`
  * any other shape → L003 error

The walk is `partial` because Lean's `Term` is not
structurally recursive in a way the kernel's termination
checker accepts; the recursion is bounded by the (finite)
size of the elaborated term, but Lean cannot prove that
without help.  This is acceptable: the enforcer is non-TCB,
its termination matters only for the build, and a malformed
term produces a clear error rather than infinite recursion
(the enforcer's pattern set is exhaustive over the shapes
it accepts; falls through to a fast L003 error otherwise).

### 7.4 The `@[lex_pre]` attribute

User-defined predicates / Nat-valued functions are admitted
to the grammar by tagging:

```lean
@[lex_pre]
def actor_is_compliant (registry : ComplianceRegistry) (a : ActorId) : Prop :=
  registry.contains a
```

The attribute records the function's name in a *Lean
attribute table* — a Lean-level metadata store accessed at
elaboration time.  The `parsePreExpr` walk consults this
table when it encounters a non-built-in identifier:

```lean
/-- Returns `true` if the function `n` is tagged `@[lex_pre]`.
    Looked up from the per-file attribute extension table. -/
def isLexPreTagged (env : Lean.Environment) (n : Name) : Bool :=
  (lexPreExtension.getState env).contains n
```

A predicate annotated `@[lex_pre]` must additionally have a
`Decidable` instance satisfiable via `inferInstance`.  The
attribute *handler* runs at attribute-attach time and
ensures this:

```lean
initialize lexPreAttr : ParametricAttribute Unit ←
  registerParametricAttribute {
    name  := `lex_pre
    descr := "Marks a predicate or Nat-valued function as
              admissible inside a Lex `pre` clause.  The
              decorated definition must produce a Decidable
              result via `inferInstance`."
    add   := fun decl _ _ => do
      -- Verify a Decidable instance exists for `decl`'s
      -- result type when applied to representative
      -- arguments; emit a compile error if not.
      let env := (← getEnv)
      checkLexPreDecidability env decl
  }
```

`checkLexPreDecidability` does *not* prove decidability —
that's the user's burden.  It performs a best-effort
synthesis attempt; if synthesis fails for *every* test input
shape, the attribute is rejected at attach time.  This is
the v1 answer to design-doc open question §14.8.

### 7.5 Forbidden shapes and their diagnostics

| Shape                                          | Diagnostic | Notes                                                                      |
|------------------------------------------------|------------|----------------------------------------------------------------------------|
| `∀ x : T, P x` (no `∈ <list>`)                 | L003       | Reformulate as `∀ x ∈ <list>, P x` with a finite-list iterator.            |
| `∃ x : T, P x` (no `∈ <list>`)                 | L003       | Same.                                                                      |
| `Classical.choose …`, `Classical.byContradiction …` | L003   | Classical-logic primitives are not instance-decidable.                     |
| Opaque `Prop`-valued user predicate            | L003       | Tag with `@[lex_pre]` and supply a `Decidable` instance.                   |
| `IO.print …`, `IO.read …`, `Task.spawn …`      | L003       | I/O is forbidden in `pre` (also breaks determinism).                       |
| Recursive function call with no obvious termination | L003  | Use bounded iteration via `for x in <list>:` instead.                      |
| `Float`-typed sub-expression                   | L003       | All amounts are `Nat`; `Float` is forbidden in `pre`.                      |
| `String.length s ≥ k` on a `String`            | L003       | `String` is not instance-decidable for arbitrary properties; convert to `ByteArray.size`. |
| Bare `Term.proj` projection on an `Inductive`  | L003       | Use the named field accessor (`s.balances`, not `s.1`).                   |

### 7.6 Examples

Allowed:

```lean
pre := fun s =>
  getBalance s r sender ≥ amount
  ∧ amount > 0
  ∧ ∀ a ∈ approvedActors, getBalance s r a > 0
```

Rejected (with diagnostic L003):

```lean
pre := fun s =>
  ∀ a, getBalance s r a > 0       -- L003: unbounded ∀
  ∧ Classical.choose ...           -- L003: classical primitive
  ∧ s.balances.size > 0            -- L003: bare projection on TreeMap (use the named accessor)
```

### 7.7 Why grammar enforcement is structural, not proof-based

A naïve alternative would be to elaborate `pre` to a
`State → Prop`, attempt instance synthesis, and surface the
"failed to synthesize Decidable" error verbatim.  This is
what the Phase-4 macro does, and the result is the
sixty-line trace.

The grammar enforcer trades *expressive completeness* for
*ergonomic precision*: it rejects some predicates that
Lean's instance synthesizer could in principle discharge
(via, e.g., a hand-written `instance Decidable (myFn x) :=
…`), but in exchange it produces an error message at the
exact source token where the user wrote the un-supported
shape.  Authors who need expressive completeness can:

  1. Tag the offending helper with `@[lex_pre]` and
     provide the `Decidable` instance manually.
  2. Drop the surface law and write a hand-built
     `Transition` (the Phase-4 escape hatch is preserved
     for v1 / v2; removed in v3 once Lex covers every
     real-world case).

This is consistent with the design document's Principle 1:
"Decidability is enforced by grammar."

## §8 The `impl` calculus enforcer

### 8.1 The calculus (recap)

Per design-doc §6.2, the `impl` block is a `do`-style
sequence of statements drawn from a fixed calculus:

| Primitive                                       | Effect kind   | Desugars to                                                                                    |
|-------------------------------------------------|---------------|------------------------------------------------------------------------------------------------|
| `flow r amt from a to b`                        | kernel-impl   | post-debit re-read pattern (§4.11 self-transfer fix verbatim)                                  |
| `mint r amt to b`                               | kernel-impl   | `setBalance s r b (getBalance s r b + amt)`                                                    |
| `burn r amt from a`                             | kernel-impl   | `setBalance s r a (getBalance s r a - amt)` (truncated `Nat` subtraction)                      |
| `reward r amt to b`                             | kernel-impl   | identical to `mint` at the kernel level (definitionally equal); separate Action constructor   |
| `freeze_resource r`                             | kernel-impl   | `fun s => s` (identity)                                                                        |
| `register_key a as k`                           | authority     | `KeyRegistry.register reg a k` (kernel-impl is identity for this branch)                       |
| `register_identity a as k`                      | authority     | `KeyRegistry.register reg a k` (only on first-time registration; the bridge actor's surface)   |
| `for x in <list>: <stmt>`                       | host          | `(<list>).foldl (fun s' x => <stmt-as-fn> s') s`                                               |
| `if <pre> then <stmt₁> else <stmt₂>`            | host          | `if <decidable-pre> then <stmt₁-as-fn> s else <stmt₂-as-fn> s`                                 |
| `let x := e`                                    | host          | local binding                                                                                  |
| `<bare term : State → State>`                   | kernel-impl   | escape hatch (v1 only; removed in v2)                                                          |

The enforcer walks each statement's elaborated `Term`,
classifies it as `kernel-impl` / `authority` / `host`, and
emits the desugared body via the table above.

### 8.2 Static effect classification

Each statement is classified once:

  * `flow`, `mint`, `burn`, `reward`, `freeze_resource`,
    `<bare term>` → kernel-impl.
  * `register_key`, `register_identity` → authority.
  * `for`, `if`, `let` → host (the body's effect kind
    propagates through; mixed-effect bodies threading both
    a `State` and a `KeyRegistry` are explicitly handled).

A law is allowed to mix kernel-impl and authority effects:
`replaceKey`'s Lex declaration has only an authority-layer
effect (its kernel-impl is the identity); a future
hypothetical "mint-and-register" law would have both.

### 8.3 Desugaring kernel-impl statements

Kernel-impl statements desugar to a `State → State` chain
threaded left-to-right:

```lean
-- impl := do f₁; f₂; …; fₙ
-- desugars to:
fun s =>
  let s₁ := f₁_body s
  let s₂ := f₂_body s₁
  …
  fₙ_body sₙ₋₁
```

For the canonical primitives:

```lean
-- flow r amt from a to b
fun s =>
  let fromBal := getBalance s r a
  let s₁ := setBalance s r a (fromBal - amt)
  let toBal := getBalance s₁ r b           -- POST-debit read
  setBalance s₁ r b (toBal + amt)

-- mint r amt to b
fun s => setBalance s r b (getBalance s r b + amt)

-- burn r amt from a
fun s => setBalance s r a (getBalance s r a - amt)

-- reward r amt to b
fun s => setBalance s r b (getBalance s r b + amt)
-- (definitionally equal to mint; the Action layer
-- distinguishes them but the kernel layer doesn't.)

-- freeze_resource r
fun s => s
```

The post-debit read of the receiver in `flow` is the §4.11
self-transfer fix.  The enforcer **forbids any other
desugaring** of `flow`: a `do f` expansion that re-reads
from `s` instead of `s₁` is rejected (this is L010's
underlying purpose — bare `setBalance` calls let the user
write a non-self-transfer-safe form).

### 8.4 Desugaring authority-layer statements

Authority-layer statements desugar to a `KeyRegistry →
KeyRegistry` chain threaded analogously:

```lean
-- register_key a as k
fun reg => KeyRegistry.register reg a k
```

The kernel-impl part of the law's `Transition.apply_impl`
is the identity for laws that have only authority-layer
effects.  For mixed laws, the two desugarings produce two
state-threading chains: the kernel-impl chain feeds
`Transition.apply_impl`, and the authority-layer chain
feeds `applyActionToRegistry`.

### 8.5 Forbidden shapes and their diagnostics

| Shape                                          | Diagnostic | Notes                                                                      |
|------------------------------------------------|------------|----------------------------------------------------------------------------|
| Bare `setBalance` call                         | L010       | Use `flow` / `mint` / `burn` / `reward`.                                   |
| `revoke_key` invocation                        | L022       | The kernel does not yet ship `Action.revokeKey`; v3.                       |
| Helper not tagged `@[lex_impl]`                | L023       | Tag the helper or inline its body.                                         |
| `IO.print …`, `Task.spawn …`                   | L010       | I/O / Task forbidden (also breaks determinism).                            |
| Recursive function call (no `for`)             | L010       | Use `for x in <list>:` instead.                                            |
| Calls that return non-`State` and non-`KeyRegistry` | L021  | Every effect must be one of the two kinds.                                  |
| Empty `impl := do` / `impl := []` with no authority effect either | L021 | Add at least one statement.                                |
| `for x in <iter>:` where `<iter>` is not a `List` | L019    | Convert via `.toList` or use a different bounded iterator.                 |
| `register_key` with a target other than the signed-by actor while `authorized_by self_only` | L011 | Add an `authorized_by` policy or restrict to signer-keyed mutations. |

### 8.6 The `@[lex_impl]` attribute

User-defined helper functions called from `impl` must be
tagged `@[lex_impl]`:

```lean
@[lex_impl]
def proportionalShare (totalReward myStake totalStake : Nat) : Nat :=
  totalReward * myStake / totalStake
```

The attribute is a non-decidability-checking sibling of
`@[lex_pre]`: it just records the helper as part of the
deployment-trusted impl surface, so `lex_lint` can list
every term contributing to state mutation.  No
decidability check; no Prop-shape requirement.

### 8.7 The bare-term escape hatch (v1 only)

For laws not expressible in the calculus (e.g. shapes
needing custom recursion), v1 admits a bare-term escape
hatch:

```lean
impl := do
  fun s => myCustomTransformer s arg₁ arg₂
```

The bare term must have type `State → State` (or
`KeyRegistry → KeyRegistry`) and is checked at elaboration
time.  V2 removes this hatch once every kernel-built-in
law has been re-expressed via the calculus.  Until then,
laws using the hatch land with diagnostic L004 on the
`conservative`/`monotonic` synthesizer (since the
synthesizers cannot reason about arbitrary `State → State`
functions); the author must provide a `proof` override.

### 8.8 Why a fixed calculus

Free-form Lean inside `impl` would return us to the Phase-4
status quo: `apply_impl` could be any `State → State`
function, with no machine-checkable structure.  Lex's
synthesizer library (§10) relies on the fact that `impl`
is a fixed-shape calculus to discharge `IsConservative` /
`IsMonotonic` / `LocalTo` instances by pattern-matching;
without the calculus, the synthesizer would have to invoke
generic theorem-proving search (a non-starter for build-
time elaboration).

The asymmetry is the point: `flow` / `mint` / `burn` /
`reward` are visually distinct so that a reviewer scanning
a 200-line law file can see exactly what the law does
without reading the desugared `setBalance` calls.


## §9 Authority binding semantics (`signed_by`, `authorized_by`)

### 9.1 The `signed_by` strengthening

Per design-doc §6.3, `signed_by sender` does two things:

  1. **Nonce-advance binding.**  Emits `nonces :=
     advanceNonce es.nonces st.signer` in the generated
     `myLaw_apply` shim.  This is structurally identical to
     the existing `apply_admissible_with`'s nonce step
     (`Authority/SignedAction.lean`); Lex just makes it
     explicit at the surface.
  2. **Signer-identity strengthening.**  Adds an
     `st.signer = sender` propositional conjunct to the
     generated shim's hypothesis bundle.  This closes the
     "actor X signs a transfer FROM actor Y" attack class
     by tying the law's named "from" / "by" actor to the
     `SignedAction.signer` field.

The strengthening is delivered as an *additional
propositional conjunct on the generated shim*, not a
modification of `AdmissibleWith` itself.  The kernel's
existing `AdmissibleWith` is unchanged; the shim layer
is non-TCB.

### 9.2 The generated `myLaw_apply` shim

For each Lex law, `lex_codegen` emits a Lean shim wrapping
`apply_admissible_with`:

```lean
-- Generated for `law transfer (...) ...`:
def legalkernel_transfer_apply
    (st : SignedAction) (es : ExtendedState)
    (h          : AdmissibleWith Verify P es st)
    (h_signer   : st.signer = sender)
    : ExtendedState :=
  apply_admissible_with Verify P es st h
```

The `h_signer` hypothesis is:

  * **Decidable.**  `DecidableEq ActorId` (a `Nat`-wrapped
    abbrev) discharges via `inferInstance`.
  * **Supplied by the deployment's `AuthorityPolicy`.**  A
    deployment's `transfer_policy sender r` predicate must
    imply `st.signer = sender`; without this implication
    the shim is unusable.  Concretely, the deployment's
    policy will be of the form

    ```lean
    fun signer action => match action with
      | .transfer r s r' am => signer = s ∧ deployment.allow_transfer signer r ...
      | _ => False
    ```

    The `signer = s` clause is what ties the shim's
    parameter `sender` to `st.signer`; the elaborator
    verifies (via static analysis of the policy
    expression) that the implication holds.

### 9.3 The `self_only` shorthand

`authorized_by self_only` is admissible only when the
`impl` block's static analysis shows that *every* mutated
balance / registry slot is keyed by the signer.  The
enforcer walks `impl_calculus` and checks:

  * `flow r amt from sender to b` — sender must equal the
    `signed_by` actor.
  * `flow r amt from a to sender` — *not* allowed under
    `self_only` (the law mutates an arbitrary `a`'s
    balance).
  * `mint r amt to b` — b must equal the `signed_by`
    actor.
  * `burn r amt from a` — a must equal the `signed_by`
    actor.
  * `reward r amt to b` — b must equal the `signed_by`
    actor.
  * `freeze_resource r` — admissible (touches no actor
    state).
  * `register_key a as k` — a must equal the `signed_by`
    actor.

A statement violating these constraints under `self_only`
is rejected with diagnostic L011.

### 9.4 The mandatory-`authorized_by` rule

Per design-doc §6.3, every law must have an
`authorized_by` clause.  Omitting it is L009.

The rationale (design-doc §6.3 paragraph 5):

> The repeated forgetfulness around authorisation in
> distributed systems is the headline lesson of the last
> fifteen years of permissioned-ledger CVEs; Lex makes it
> impossible to ship a law without confronting the
> question.

### 9.5 Why these aren't lifted into `AdmissibleWith`

Lifting `signed_by` into the kernel-level
`AdmissibleWith` would require extending `Action` with an
"intended signer" field that the kernel checks against
`st.signer` directly.  This is a *wire-format change*: the
existing `Action.transfer r sender receiver amount`
constructor would gain a sixth field, breaking every
log file written under the pre-LX format.

V2 may revisit this (design-doc §14.9 open question).
For v1, the strengthening lives at the shim layer, with
the side condition that the deployment's
`AuthorityPolicy` must imply `st.signer = sender`.

## §10 The property synthesizer library

### 10.1 Library scope

`Lex/DSL/Property.lean` exports synthesizers
for the seven design-doc §6.4 property names:

  1. `conservative` — claims `IsConservative t`
  2. `monotonic` — claims `IsMonotonic t`
  3. `local [{r₁, …, rₙ}]` — claims `LocalTo {r₁,…} t`
  4. `freeze_preserving [{r₁, …, rₙ}]` — claims
     `FreezePreserving {r₁,…} t`
  5. `freeze_preserving [*]` — shorthand for
     `freeze_preserving [{r}]` where `r` ranges over
     every manifest-declared resource (resolved at
     manifest-elaboration time)
  6. `nonce_advances [a]` — claims the nonce of `a` is
     advanced
  7. `registry_preserving` — claims the law preserves
     `KeyRegistry` pointwise

Plus user-defined properties via `proof <P> := …`
overrides; these don't go through the synthesizer at all
(the elaborator splices the user's tactic block in
verbatim).

### 10.2 The three new typeclasses (LX.2)

Three new non-TCB typeclasses are added to
`LegalKernel/Conservation.lean`:

```lean
namespace LegalKernel

/-- `LocalTo S t` — applying `t` mutates only resources in `S`.
    The structural analogue of the existing
    `*_does_not_touch_other_resources` lemma family.

    Uses `List ResourceId` for `S` rather than `Std.TreeSet`
    to match the existing kernel idiom (`MonotonicLawSet.laws :
    List Transition`).  `r ∈ S` decidability follows from
    `DecidableEq ResourceId`. -/
class LocalTo (S : List ResourceId) (t : Transition) : Prop where
  local_to :
    ∀ (r : ResourceId) (a : ActorId) (s : State),
      r ∉ S →
      t.pre s →
      getBalance (step_impl s t) r a = getBalance s r a

/-- `FreezePreserving S t` — `t` preserves `FrozenForResource`
    at every `r ∈ S`. -/
class FreezePreserving (S : List ResourceId) (t : Transition) : Prop where
  preserves :
    ∀ (r : ResourceId), r ∈ S →
    ∀ (snap : Option BalanceMap) (s : State),
      FrozenForResource r snap s →
      t.pre s →
      FrozenForResource r snap (step_impl s t)

/-- `RegistryPreserving a` — Action `a`'s authority-layer
    effect on `KeyRegistry` is the identity.  Trivial for
    every `Action` constructor that does NOT mutate the
    registry — i.e. all but `replaceKey` and `registerIdentity`.

    **Why an `Action`-indexed typeclass, not a
    `Transition`-indexed one.**  The authority-layer effect
    `applyActionToRegistry` dispatches on `Action`, not on
    `Transition`.  Multiple `Action` constructors compile to
    the same `Transition` (e.g. `replaceKey`, `dispute`,
    `disputeWithdraw`, `verdict`, `rollback`,
    `registerIdentity`, `declareLocalPolicy`,
    `revokeLocalPolicy`, and `freezeResource r` for any `r`
    all compile to the kernel-level no-op `Laws.freezeResource
    0` because the `freezeResource` law's body ignores its
    `r` parameter — see CLAUDE.md "type-level design
    properties").  Among those, `replaceKey` and
    `registerIdentity` mutate the registry while the others
    do not.  A typeclass on `Transition` could not
    distinguish them; the `Action`-indexed form can. -/
class RegistryPreserving (a : Action) : Prop where
  preserves : ∀ (kr : KeyRegistry), applyActionToRegistry kr a = kr

end LegalKernel
```

These are *additions* to `Conservation.lean`, not
modifications of the kernel TCB.  The `tcb_audit`
allowlist is unchanged because the new typeclasses live in
the same non-TCB module that already hosts `IsConservative`
and `IsMonotonic`.

The choice of `List ResourceId` over `Std.TreeSet ResourceId
compare` is deliberate: every existing kernel structure
that takes a "set of laws" / "set of resources" uses `List`
(`MonotonicLawSet.laws`, `ConservativeLawSet.laws`).
Membership decidability follows from `DecidableEq ResourceId`
(a `Nat` abbreviation).  A future optimisation may swap to
`TreeSet` if list-membership performance becomes an issue
at scale; the typeclass interface is forward-compatible
because callers see only the `Prop`-level conclusion, not
the `S` representation.

The asymmetry between `LocalTo` / `FreezePreserving` (on
`Transition`) and `RegistryPreserving` (on `Action`)
reflects the underlying architecture: kernel-impl effects
are encoded in `Transition.apply_impl`, while authority-
layer effects are encoded in `applyActionToRegistry`,
which dispatches on `Action`.  The two effect surfaces do
not share an indexing type, and the typeclasses cannot
either.

### 10.3 Per-existing-law instances (LX.2)

Workstream LX.2 / LX.3 land typeclass instances for every
existing kernel-built-in law.  `LocalTo` and `FreezePreserving`
instances are indexed by the law's *kernel-level transition*
(the value of `Action.compileTransition action`);
`RegistryPreserving` instances are indexed by the *action
constructor* itself, since the authority-layer effect is
`Action`-keyed (see §10.2's "why an `Action`-indexed
typeclass" rationale).

| Law (action ctor)                                | `LocalTo` (on `Transition`)          | `FreezePreserving` (on `Transition`) | `RegistryPreserving` (on `Action`) |
|--------------------------------------------------|--------------------------------------|--------------------------------------|------------------------------------|
| `transfer r sender receiver amount`              | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}` (closure) | yes                                |
| `mint r minter receiver amount`                  | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `burn r burner amount`                           | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `freezeResource r`                               | `LocalTo {}` (touches no balance)     | `FreezePreserving [*]` (no balance change preserves any frozen invariant) | yes                                |
| `replaceKey actor newKey`                        | `LocalTo {}`                          | `FreezePreserving [*]`                | **no** (mutates registry)          |
| `reward r minter receiver amount`                | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `distributeOthers r excluded amount`             | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `proportionalDilute r excluded totalReward`      | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `dispute / disputeWithdraw / verdict / rollback` | `LocalTo {}` (kernel-no-op)           | `FreezePreserving [*]`                | yes                                |
| `registerIdentity actor newKey`                  | `LocalTo {}`                          | `FreezePreserving [*]`                | **no** (mutates registry)          |
| `deposit r recipient amount depositId`           | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `withdraw r sender amount recipientL1`           | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                                |
| `declareLocalPolicy / revokeLocalPolicy`         | `LocalTo {}`                          | `FreezePreserving [*]`                | yes                                |

Note that the rows for `freezeResource`, `replaceKey`,
`dispute / …`, `registerIdentity`, and `declareLocalPolicy /
revokeLocalPolicy` all share the **same** `LocalTo` and
`FreezePreserving` instances (since they all compile to a
definitionally-equal `Laws.freezeResource _` Transition);
the table lists them per-law for clarity, but the actual
Lean instance landings are per-Transition (so one shared
instance handles all of them at the kernel-impl level).
Only the `RegistryPreserving` instances are per-Action.

The `FreezePreserving {r' ≠ r}` notation is shorthand for
"every resource other than the law's primary resource"; the
generated instance unfolds to a check against the
manifest's resource set minus `{r}`.  Each instance is
proved using the existing per-law theorems (e.g.
`transfer_other_resource_untouched`).  No new theorem
infrastructure is required; the typeclass is just a
*classification surface* over existing theorems.

### 10.4 Synthesizer dispatch table

The `synth_<P>` functions in `LexProperty.lean` dispatch
by structural induction on `impl_calculus`:

```lean
/-- `synth_conservative` succeeds iff every kernel-impl
    statement is conservation-preserving by structural
    rule.  Fails on any `mint` / `burn` / `reward`. -/
def synth_conservative (calc : List ImplStmt) : SynthResult IsConservativeProof
  | [] => .ok IsConservativeProof.identity
  | s :: rest => match s.kind with
    | .flow => match synth_conservative rest with
                 | .ok p => .ok (IsConservativeProof.flowThen p)
                 | .fail e => .fail e
    | .mint  | .burn | .reward => .fail SynthError.nonConservativeStmt
    | .freeze_resource => match synth_conservative rest with
                            | .ok p => .ok (IsConservativeProof.freezeThen p)
                            | .fail e => .fail e
    | .for body => match synth_conservative body with
                     | .ok _ => .fail SynthError.foldOfFlow  -- v1: synth doesn't handle folds
                     | .fail e => .fail e
    -- ... etc.

/-- `synth_monotonic` succeeds on `flow` / `mint` / `reward`
    / `freeze_resource` / `register_key`; fails on `burn`. -/
def synth_monotonic (calc : List ImplStmt) : SynthResult IsMonotonicProof
  | [] => .ok IsMonotonicProof.identity
  | s :: rest => match s.kind with
    | .flow | .mint | .reward | .freeze_resource | .register_key =>
      synth_monotonic rest |>.map IsMonotonicProof.cons
    | .burn => .fail SynthError.burnNotMonotonic
    -- ...

/-- `synth_local S calc` succeeds iff every kernel-impl
    statement's resource is in `S`. -/
def synth_local (S : List ResourceId) (calc : List ImplStmt) : SynthResult LocalToProof
  | [] => .ok LocalToProof.identity
  | s :: rest => match s.kind with
    | .flow | .mint | .burn | .reward =>
      if s.resource ∈ S then
        synth_local S rest |>.map (LocalToProof.cons · s)
      else
        .fail (SynthError.resourceNotInLocalSet s.resource)
    | .freeze_resource | .register_key | .register_identity =>
      synth_local S rest |>.map LocalToProof.cons-host
    -- ...
```

The synthesizer's *output* is a Lean tactic block that
elaborates to a value of the property typeclass.  For
`conservative` over a single `flow r amt from a to b`, the
emitted body is

```lean
instance legalkernel_transfer_isConservative
    (r : ResourceId) (sender receiver : ActorId) (amount : Nat) :
    IsConservative (legalkernel_transfer_transition r sender receiver amount) where
  conserves := by
    intro r' s hpre
    by_cases h : r' = r
    · subst h
      exact LegalKernel.Laws.transfer_conserves r sender receiver amount s hpre
    · exact LegalKernel.Laws.transfer_conserves_other_resource
              r sender receiver amount s r' h
```

— exactly the shape of the existing hand-written
`Laws/Transfer.lean:226–233`, but emitted by code rather
than typed by hand.

### 10.5 Synthesizer-failure handling

A synthesizer failure for a property `P` produces
diagnostic L004 with:

  * the failing statement's source location,
  * a hint indicating which structural rule failed
    (e.g. "structural induction failed at the `mint`
    statement; `mint` is non-conservative by design"),
  * a remediation suggestion (drop the property, replace
    the offending statement, supply a `proof` override).

The user can then either:

  1. Drop the property from `satisfies` (the law
     genuinely doesn't have it).
  2. Restructure `impl` so the synthesizer succeeds.
  3. Supply `proof <P> := by …` with a manual witness.

### 10.6 The deliberate-conservatism principle

Per design-doc §6.4.4, the synthesizers are deliberately
conservative.  A round-trip law

```lean
impl := do
  flow r amt₁ from x to y
  flow r amt₂ from y to x
```

is informally conservative but the v1 synthesizer rejects
it (the structural induction does not detect that the two
non-conservative-individually flow statements compose to a
zero-net-supply-change).  The author writes a `proof`
override.

Similarly, fold-of-flow shapes
(`for x in <list>: flow …`) are not handled by v1; this
is the canonical case that `distributeOthers` exercises.
V2 plans to extend the synthesizer to handle fold-of-flow
via `List.foldl`-induction (design-doc §14.4 open
question).

### 10.7 Parameter binding into the synthesizer

The synthesizer needs to know the law's parameters (a
`flow r amt from a to b` statement has its `r` as a
parameter, not a literal).  Each `ImplStmt`'s fields hold
*parameter references* that the synthesizer threads through
the emitted instance body.  For a parameterised law, the
generated instance is itself parameterised:

```lean
instance legalkernel_transfer_isConservative
    (r : ResourceId) (sender receiver : ActorId) (amount : Nat) :
    IsConservative (legalkernel_transfer_transition r sender receiver amount) := …
```

`Lean's elaboration` resolves the instance per call site by
specialising `r`, `sender`, etc.

### 10.8 Decidability of the new typeclasses

`LocalTo`, `FreezePreserving`, `RegistryPreserving` are
**Prop-level**, not `Decidable`-level.  They are not
intended to be `decide`d at runtime; they are *static
classification* used by the manifest's `invariant_claims`
synthesis.  This is consistent with `IsConservative` /
`IsMonotonic`'s existing design.

The decidable-by-typeclass-resolution layer is `Std.TreeSet
ResourceId compare`'s `contains`, which is decidable in
O(log |S|).  The Prop-level conclusion of `LocalTo` is
universal over `(r, a, s)`, hence non-decidable in general
(per the kernel's existing typeclass discipline).

### 10.9 Synthesizer integration tests

Each synthesizer ships with a value-level test in
`Lex/Test/DSL/Property.lean`:

  * **Positive case.**  Build a representative `ImplStmt`
    list that the synthesizer should accept; assert the
    emitted instance compiles and the resulting
    `IsConservative`/etc. value is provable via
    `inferInstance`.
  * **Negative case.**  Build an `ImplStmt` list outside
    the synthesizer's domain; assert the synthesizer
    returns `.fail` with the expected error variant.

The test count across LX.13 / LX.14 / LX.15 / LX.16 is
approximately 52 cases (positive + negative per
synthesizer × 6 synthesizers, plus override interaction).

### 10.10 Per-statement decision logic (full table)

The synthesizers' core mechanism is *structural induction
on the `impl_calculus` list*.  Each statement is
classified once; the classification determines whether
each property's synthesizer can succeed on a list ending
in that statement.

The table below is the authoritative dispatch surface.
It is committed to the repository so reviewers can grep
for synthesizer behaviour by statement kind:

| Statement kind   | `synth_conservative` | `synth_monotonic`  | `synth_local`           | `synth_freeze_preserving` | `synth_registry_preserving` |
|------------------|----------------------|--------------------|-------------------------|---------------------------|-----------------------------|
| `flow r amt …`   | ✅ recurse            | ✅ recurse          | ✅ if `r ∈ S`, else ❌   | ✅ if `r ∉ frozen-set`     | ✅ recurse                   |
| `mint r amt …`   | ❌ fail L004 (mint)   | ✅ recurse          | ✅ if `r ∈ S`, else ❌   | ✅ if `r ∉ frozen-set`     | ✅ recurse                   |
| `burn r amt …`   | ❌ fail L004 (burn)   | ❌ fail L004 (burn) | ✅ if `r ∈ S`, else ❌   | ✅ if `r ∉ frozen-set`     | ✅ recurse                   |
| `reward r amt …` | ❌ fail L004 (reward) | ✅ recurse          | ✅ if `r ∈ S`, else ❌   | ✅ if `r ∉ frozen-set`     | ✅ recurse                   |
| `freeze_resource r` | ✅ recurse         | ✅ recurse          | ✅ recurse              | ✅ recurse (no-op)         | ✅ recurse                   |
| `register_key …` | ✅ recurse            | ✅ recurse          | ✅ recurse (no balance) | ✅ recurse                 | ❌ fail L004 (mutates reg)   |
| `register_identity …` | ✅ recurse       | ✅ recurse          | ✅ recurse              | ✅ recurse                 | ❌ fail L004 (mutates reg)   |
| `for x in <list>: <body>` | ❌ fail L004 (fold) | ❌ fail L004 (fold) | ❌ fail L004 (fold) | ❌ fail L004 (fold)        | ❌ fail L004 (fold)          |
| `if <pre> then <s₁> else <s₂>` | recurse on both branches | recurse on both branches | recurse on both branches | recurse on both branches | recurse on both branches |
| `let x := e`     | ✅ recurse            | ✅ recurse          | ✅ recurse              | ✅ recurse                 | ✅ recurse                   |
| `<bare term>`    | ❌ fail L004 (opaque) | ❌ fail L004 (opaque) | ❌ fail L004 (opaque) | ❌ fail L004 (opaque)      | ❌ fail L004 (opaque)        |
| `[]` (empty)     | ✅ identity           | ✅ identity         | ✅ identity             | ✅ identity                | ✅ identity                  |

Reading conventions:

  * **✅ recurse** — the statement is permitted; the
    synthesizer recurses on the rest of the list.
  * **✅ identity** — base case; emits the identity
    proof.
  * **❌ fail L004** — emits diagnostic L004 with the
    parenthesised hint (`mint`, `burn`, `fold`, etc.)
    naming the offending kind.
  * **`if`/`let`** — host primitives propagate through
    both branches.

The `for`-loop fail is the canonical `proof` override
target: the v1 synthesizer is conservative because
`List.foldl`-induction over a parametrised body is
beyond its structural-rule library.  V2 may extend the
synthesizer to handle this case (open question §22.2.4).

### 10.11 Synthesizer body shapes

Each synthesizer emits a Lean `term`-level proof body.
The shape is fixed per property and per `impl_calculus`
shape; reviewers can grep for the emission patterns:

```lean
-- For `synth_conservative` on a single-`flow r amt from a to b`:
instance <law>_isConservative <params> :
    IsConservative (<law>_transition <params>) where
  conserves := by
    intro r' s hpre
    by_cases h : r' = r
    · subst h
      exact LegalKernel.Laws.transfer_conserves r a b amt s hpre
    · exact LegalKernel.Laws.transfer_conserves_other_resource
              r a b amt s r' h

-- For `synth_monotonic` on a single-`mint r amt to b`:
instance <law>_isMonotonic <params> :
    IsMonotonic (<law>_transition <params>) where
  monotone := by
    intro r' s hpre
    by_cases h : r' = r
    · subst h
      exact LegalKernel.Laws.totalSupply_after_mint_le ...
    · exact LegalKernel.Laws.mint_other_resource_untouched_le ...

-- For `synth_local [{r}]` on a single-`flow r amt …`:
instance <law>_localTo <params> :
    LocalTo [r] (<law>_transition <params>) where
  local_to := by
    intro r' a' s hr_not_in hpre
    -- r' ≠ r since r ∈ [r] but r' ∉ [r]:
    have hne : r' ≠ r := by simp [List.Mem] at hr_not_in; exact hr_not_in
    exact LegalKernel.Laws.transfer_does_not_touch_other_resources
            r ... r' hne ...
```

The synthesizer's term-level output is parameterised by
the `LawDecl`'s parameter list (`<params>`); the
emission code substitutes the right Lean variable
identifiers and the right per-statement positional
references.

### 10.12 Multi-statement composition

For `impl` with more than one statement, the synthesizer
threads through a *composition lemma* per property.  For
`conservative`, the composition lemma is:

```lean
theorem isConservative_compose
    (t₁ t₂ : Transition)
    (h₁ : IsConservative t₁) (h₂ : IsConservative t₂) :
    IsConservative (t₁ >> t₂) := …
```

where `t₁ >> t₂` is the kernel-level sequential
composition of two transitions.  Each statement
contributes its conservative witness; the composed
witness chains through `isConservative_compose`.

These composition lemmas are **non-TCB** additions to
`LegalKernel/Conservation.lean`, landed alongside the
typeclass declarations in LX.2.  They mirror the existing
hand-written composition lemmas (e.g.
`transfer_conserves` on the post-debit re-read state) but
generalise to arbitrary `Transition` pairs.

### 10.13 `proof` override interaction with synthesizers

The dispatcher consults `LawDecl.proof_overrides` *before*
the synthesizer dispatch table:

```lean
def dispatchSynthesizer (claim : PropertyClaim) (decl : LawDecl) :
    Lean.Elab.Command.CommandElabM (Except Diagnostic Lean.Term) := do
  match decl.proof_overrides.find? (fun (n, _) => n == claim.propertyName) with
  | some (_, tactic) =>
    -- Override fires; bypass synthesizer.
    return .ok (← buildOverrideInstance claim decl tactic)
  | none =>
    -- No override; dispatch to synthesizer.
    match claim.kind with
    | .conservative => synth_conservative decl.implCalculus
    | .monotonic    => synth_monotonic decl.implCalculus
    | .local S      => synth_local S decl.implCalculus
    -- ...
```

Override semantics:

  * **Synthesizer is bypassed entirely** if an override
    matches the property name.  The synthesizer's
    structural rules are not consulted.
  * **The override's tactic source is captured verbatim**
    from the user's `proof <P> := by …` clause as a
    `Lean.Syntax` value, with its source-position
    metadata preserved.  Errors inside the tactic block
    are anchored at the user's source location.
  * **Override-with-deliberate-redundancy is allowed.**
    A user may supply `proof conservative := by …` for a
    law where the synthesizer would also succeed; the
    override wins.  This is useful for performance
    (a hand-tuned proof body may elaborate faster than
    the synthesizer's generic shape) or for clarity
    (the override may name the lemma it depends on
    explicitly).
  * **User-defined property names** require both
    `@[lex_property]` tagging on a `def <P>` and a
    `proof <P> := by …` clause supplying the witness.
    Either alone fails L020.

### 10.14 Synthesizer determinism

The synthesizers' output term is a *pure function* of
the `impl_calculus`, the property, and the parameter
bindings.  Two macro invocations on equal inputs produce
byte-identical Lean terms.  This is verified by:

  * The Audit-3.9 property test
    `lex_codegen_determinism_property` (re-running the
    codegen pass produces byte-identical output).
  * The M2 strict-equivalence regression `example`s
    (each Lex re-expressed law's emitted instance body
    is `rfl`-equal to the pre-M2 hand-written body).

Determinism is structural: no synthesizer reads the
filesystem, network, environment variables, or wall
clock.  Although the surrounding command elaboration
runs in `CommandElabM` (which *does* admit IO via
`liftIO`), the synthesizers themselves are pure
`Except`-valued functions — IO is segregated to the
explicit `liftIO (writeCodegenInputIdempotent ...)`
call site.  This keeps the synthesizer's output a pure
function of its inputs and makes the
`lex_codegen_determinism_property` test trivially
discharge.


## §11 The `events` block elaborator

### 11.1 What `events` produces

Per design-doc §6.6, the `events` block elaborates to a
branch of `actionEvents` in
`LegalKernel/Events/Extract.lean`.  The actual signature
(from `Events/Extract.lean:lines 109–235`) is

```lean
def actionEvents (preState postState : LegalKernel.State) (action : Action) :
    List Event
```

Note the state arguments are `LegalKernel.State`, not
`ExtendedState`: event extraction reads only balance /
mutated cells; the authority-layer `nonces` and `registry`
views are surfaced via the auto-emitted `nonceAdvanced` /
`identityRegistered` events at the top-level
`extractEvents` wrapper.

### 11.2 Available variable bindings

Inside an `events := do …` block:

  * `preState : LegalKernel.State` — pre-application
    state.
  * `postState : LegalKernel.State` — post-application
    state.
  * The law's parameters are in scope (`r`, `sender`, etc.).
  * The `signed_by` actor is in scope (under its bound
    name; e.g. `sender` for `signed_by sender`).
  * `let`-bound names from previous statements in the
    block are in scope.

Bare `s` is **not** in scope (L027 catches use).

### 11.3 Statement kinds

The events block is itself a small calculus:

| Statement                                       | Desugars to                                                                                  |
|-------------------------------------------------|----------------------------------------------------------------------------------------------|
| `let x := e`                                    | local binding, no event emission                                                            |
| `emit Event.<ctor> <args>`                      | append `[Event.<ctor> <args>]`                                                              |
| `if <pred> then emit … (else emit …)?`           | conditional emission                                                                         |
| `for x in <list>: <stmt>`                       | flatMap fold                                                                                  |
| `<stmt>; <stmt>`                                 | concatenation                                                                                 |

The desugared body is a value of type `List Event`:

```lean
-- events := do
--   let pre_sender := getBalance preState r sender
--   let pre_receiver := getBalance preState r receiver
--   if amount > 0 then emit balanceChanged r sender pre_sender (pre_sender - amount)
--   if amount > 0 then emit balanceChanged r receiver pre_receiver (pre_receiver + amount)
--
-- desugars to:
fun (preState postState : LegalKernel.State) =>
  let pre_sender := getBalance preState r sender
  let pre_receiver := getBalance preState r receiver
  let evS := if amount > 0 then [Event.balanceChanged r sender pre_sender (pre_sender - amount)] else []
  let evR := if amount > 0 then [Event.balanceChanged r receiver pre_receiver (pre_receiver + amount)] else []
  evS ++ evR
```

### 11.4 The empty-events form

For laws with no per-action events (`freezeResource`,
`replaceKey`'s kernel-impl side):

```lean
events := []
```

The grammar accepts `events := []`, `events := do pure ()`,
and `events := do nothing` as equivalent; `lex_format`
rewrites all three to the canonical `events := []`.  L013
prefers the explicit empty form.

### 11.5 Auto-emitted events

Two events are auto-emitted at the *top-level
`extractEvents` wrapper*, not in the per-action
`actionEvents` branch:

  * `Event.nonceAdvanced signer oldNonce newNonce` —
    always emitted (since `signed_by` is mandatory and
    every law advances the signer's nonce).
  * `Event.identityRegistered signer oldKey newKey` —
    auto-emitted when `applyActionToRegistry` mutates
    the registry (currently only on `replaceKey` /
    `registerIdentity` actions).

A user `emit nonceAdvanced …` inside an `events` block is
allowed but produces a warning (L014) recommending removal
in favor of the wrapper's emission.

### 11.6 The L013 warning

The elaborator computes the set of `(resource, actor)`
cells the `impl` touches, and warns if the `events` block
either omits an event for a touched cell or emits one for
an untouched cell.  The warning is *not* an error in v1
because the existing `actionEvents` machinery already
filters zero-deltas (every `balanceChanged` emission is
conditional on `oldV != newV` — see
`Events/Extract.lean:lines 122-123`).  A follow-up release
may promote the warning to an error.

### 11.7 `events` block in the codegen-input

The codegen-input file's `events` field is the AST
representation of the block, with the AST node kinds
documented in §5.3.  `lex_codegen` traverses this AST and
emits the `actionEvents` branch verbatim.

## §12 The codegen pass (`lex_codegen`)

### 12.1 Binary structure

`Lex/Tools/Codegen.lean` is a Lean executable following the
existing `Tools/CountSorries.lean` / `Tools/TcbAudit.lean`
template:

```lean
import Lex.Tools.Common
import Lean.Json

namespace LexCodegen

structure CodegenOptions where
  checkOnly  : Bool := false       -- --check mode
  inputDir   : System.FilePath := "Lex/Inputs/"
  outputs    : Outputs := default

structure Outputs where
  actionFile        : System.FilePath := "LegalKernel/Authority/Action.lean"
  encodingFile      : System.FilePath := "LegalKernel/Encoding/Action.lean"
  eventsFile        : System.FilePath := "LegalKernel/Events/Extract.lean"
  signedActionFile  : System.FilePath := "LegalKernel/Authority/SignedAction.lean"

def main (args : List String) : IO UInt32 := do
  let opts := parseOptions args
  let inputs ← loadCodegenInputs opts.inputDir
  let registry ← loadRegistry "Lex/IndexRegistry.txt"
  validateConsistency inputs registry
  let actionContent       := generateAction inputs
  let encodingContent     := generateEncoding inputs
  let eventsContent       := generateEvents inputs
  let signedActionContent := generateSignedAction inputs
  if opts.checkOnly then
    checkAgainstFiles opts.outputs [actionContent, encodingContent, eventsContent, signedActionContent]
  else
    writeFiles opts.outputs [actionContent, encodingContent, eventsContent, signedActionContent]

end LexCodegen
```

### 12.2 The two operating modes

**Additive mode (M1):**  The default.  `lex_codegen`
appends new content between
`-- BEGIN LEX-GENERATED (do not edit by hand)` and
`-- END LEX-GENERATED` fences in each target file.  Manual
edits *outside* the fence are preserved across runs;
manual edits *inside* the fence are clobbered.

**Canonical regeneration mode (M2):**  Activated by the
presence of a `--canonical` flag.  Removes the fence and
regenerates the entire file body.  This is the mode CI
uses post-M2.

The two modes share the same AST → Lean-source rendering
code; only the file-write strategy differs.

### 12.3 Per-target generator structure

```lean
/-- Renders the `Action` inductive's constructor list and
    the `Action.compileTransition` function from the sorted
    list of `LawDecl` values. -/
def generateAction (laws : List LawDecl) : String :=
  let header := actionFileHeader  -- module docstring, imports, namespace
  let actionInductive := renderActionInductive laws
  let compileTransition := renderCompileTransition laws
  let actionCompile := actionCompileBoilerplate    -- unchanged across regenerations
  let actionInjective := actionInjectiveBoilerplate -- unchanged
  let footer := actionFileFooter
  String.intercalate "\n\n" [header, actionInductive, compileTransition, actionCompile, actionInjective, footer]
```

The `actionInductive` and `compileTransition` portions
are *constructor-driven*: each `LawDecl` produces one
inductive constructor and one match branch.  The
`actionCompile` and `actionInjective` portions are
*boilerplate*: identical across every regeneration,
emitted as a fixed string.  This separation keeps the
diff between runs minimal.

### 12.4 Encoding generation

`generateEncoding` produces the four functions:

  * `Action.fieldsBounded` — per-constructor `Decidable`
    predicate.
  * `Action.encode` — per-constructor byte serialisation.
  * `Action.decode` — per-tag dispatch.
  * `action_roundtrip` and `action_encode_injective`
    theorems — proved by `cases` on `Action`, with each
    arm's body generated from the law's parameter shape.

The roundtrip / injectivity theorems are the trickiest.
Each arm is of the form:

```lean
  case transfer r sender receiver amount =>
    -- parameter encoding round-trip
    have h_r        := nat_roundtrip r.toNat -- (assuming r encodes as Nat)
    have h_sender   := nat_roundtrip sender.toNat
    have h_receiver := nat_roundtrip receiver.toNat
    have h_amount   := nat_roundtrip amount
    -- chain the per-field round-trips through the encoded byte sequence
    simp [Action.encode, Action.decode, h_r, h_sender, h_receiver, h_amount]
```

The synthesizer in `lex_codegen` knows how to produce
this body for each law's parameter shape; non-trivial
parameter shapes (e.g. `Verdict` carrying a list of
signatures) reuse the existing `verdict_roundtrip`-style
lemmas via `proof_overrides` in the codegen-input.

### 12.5 Event generation

`generateEvents` produces the `actionEvents` function's
match branches.  Each branch is the desugared body of the
law's `events` block; the AST → Lean-source rendering is
table-driven by statement kind.

### 12.6 Registry-mutation generation

`generateSignedAction` produces:

  * `applyActionToRegistry` — pattern-matches on `Action`
    and dispatches to the registry effect (per `LawDecl.
    registry_effect`).  V1 admits only `none` /
    `replaceKey` / `registerIdentity`.
  * `non_registry_mutating_preserves_registry` — proved
    by `cases` on `Action`, with each non-registry-mutating
    arm closed by `rfl`.

### 12.7 Determinism

`lex_codegen`'s output is a pure function of:

  * the codegen-input directory's contents,
  * the registry file's contents,
  * the binary's own version string.

No randomness, no timestamps, no environment variables.
Two invocations on byte-identical inputs produce
byte-identical outputs.  This is what `--check` mode
relies on.

### 12.8 The `--check` mode

`--check` runs the generator and *compares* the output
against the checked-in files (per
`Outputs.actionFile`, `.encodingFile`, etc.).  Divergence
fails diagnostic L026 and exits non-zero.  CI runs this
on every PR, the `gofmt -d -check` analogue.

### 12.9 What `lex_codegen` does *not* do

  * **Run the Lean elaborator.**  `lex_codegen` is a
    text-level rewriter; it doesn't typecheck the output.
    `lake build` does that on the next invocation.
  * **Run any tactic search.**  Synthesizer bodies are
    emitted as fixed strings produced by the Lean-side
    macro pass; `lex_codegen` just splices them.
  * **Touch the codegen-input files.**  These are written
    by Pass 1 (the per-file macro) and treated as
    read-only by Pass 2.
  * **Touch the kernel TCB.**  `Kernel.lean` and
    `RBMapLemmas.lean` are not in the output set.
  * **Modify any `.lean` file outside `Outputs.*`.**  The
    output set is closed over the four target files;
    sibling laws / tests / docs are untouched.

### 12.10 The fence-respecting append algorithm (M1 mode)

The fence algorithm is the heart of M1's additive
codegen mode.  It must be precise enough to handle every
edge case the user might present.  Concrete rules:

```text
Algorithm: replaceFence(targetFile, generatedContent)

Inputs:
  targetFile      : System.FilePath -- path to a .lean file
  generatedContent : String         -- new content to splice between fences

Output:
  newFileContent  : String          -- target file's new content

Constants:
  BEGIN_MARKER = "-- BEGIN LEX-GENERATED (do not edit by hand)"
  END_MARKER   = "-- END LEX-GENERATED"

Procedure:
  1. Read targetFile's bytes as a String, normalize line endings to "\n".
  2. Split into lines.
  3. Scan for BEGIN_MARKER:
     a. If exactly one BEGIN_MARKER found, record its line number `B`.
     b. If zero BEGIN_MARKER lines, abort with FATAL_NO_FENCE
        (directs user to add the fence; this would only happen on a
        misconfigured target file).
     c. If multiple BEGIN_MARKER lines, abort with FATAL_MULTIPLE_FENCES.
  4. Scan for END_MARKER:
     a. If exactly one END_MARKER found at line E > B, proceed.
     b. If E < B, abort with FATAL_REVERSED_FENCE.
     c. Otherwise FATAL_NO_END_FENCE.
  5. The lines [0..B-1] are header (preserve verbatim).
  6. The lines [B+1..E-1] are previously-generated content (will be replaced).
  7. The lines [E+1..end] are footer (preserve verbatim).
  8. Construct newFileContent:
       header
    + BEGIN_MARKER + "\n"
    + generatedContent  -- already canonically formatted
    + END_MARKER + "\n"
    + footer
  9. Return newFileContent.

Invariants preserved:
  - Header content (above the fence) is byte-identical pre/post.
  - Footer content (below the fence) is byte-identical pre/post.
  - The two marker lines themselves are byte-identical pre/post.
  - The generatedContent is byte-identical to lex_codegen's output
    (no post-processing).
```

The algorithm is **idempotent**: running it twice with
the same `generatedContent` produces a byte-identical
file the second time (the first run already produced
the same content between markers).

The algorithm is **safe under user mistakes**:

  * If a user inserts a stray line *inside* the fence,
    the next codegen run silently overwrites it (warn
    via diagnostic L013 if it's a code line; allow if
    it's only whitespace).
  * If a user removes the fence markers entirely, the
    next codegen run fails FATAL_NO_FENCE; the operator
    must restore the markers before regenerating.

### 12.11 The M1 → M2 transition: canonical regeneration

When LX.30 lands, the codegen binary's default flips
from additive (fence-respecting) to canonical (full-
file regeneration).  The transition has three steps,
each in a separate commit so reviewers can inspect
each in isolation:

  1. **All kernel-built-in laws are re-expressed in Lex.**
     Each LX.22 – LX.29 commit re-expresses one or two
     laws.  After LX.29 lands, every kernel-built-in
     constructor is backed by a Lex declaration; the
     codegen-input directory has 17 files; the four
     target files have all 17 constructors inside the
     fence (additive mode).
  2. **The codegen binary is updated to support
     `--canonical`.**  This is LX.30's first sub-commit:
     `Lex/Tools/Codegen.lean` gains the canonical-mode
     code path.  The four target files are unchanged
     yet (still using fence-mode).
  3. **The fences are removed and the files are
     regenerated canonically.**  This is LX.30's second
     sub-commit: invoke `lex_codegen --canonical`,
     verify the output is byte-equivalent to the
     pre-flip form (modulo formatting), commit the
     regenerated files without fences.

Step 3 is the irreversible step.  The verification
mechanism is the **regression `example`**: each
re-expressed law's `LegalKernel/Laws/<L>.lean` carries
an `example : <L>_transition <args> = LegalKernel.Laws.<L> <args> := rfl`
that pins the Lex form to the pre-M2 hand-written form.
If any regression `example` fails to elaborate as `rfl`
post-LX.30, the canonical regeneration introduced a
divergence; rollback via `git revert`.

### 12.12 Concurrency and atomicity

The codegen binary is invoked from CI in a single-
process context.  Locally, a developer might run it
concurrently (e.g. via two terminals) by mistake.  The
binary handles this correctly via:

  * **Per-target advisory file lock.**  Before opening
    a target file for write, the binary acquires a
    `.lock` file in the same directory (atomic via
    `O_CREAT|O_EXCL`).  A concurrent invocation
    detects the lock and exits with diagnostic
    `LEX_CODEGEN_LOCKED`.
  * **Atomic writes.**  Each target file is written to
    `<target>.tmp`, fsynced, then renamed to
    `<target>` via `rename(2)` (atomic on POSIX).
    Partial-file states are never observable.
  * **`--check` mode is read-only.**  No locks; safe to
    invoke concurrently from CI parallel jobs.

The codegen-input files are written by Pass 1 with the
same atomic-rename strategy (§6.10).  Concurrent
elaborations of the same `.lean` file (extremely rare;
Lean's incremental build serialises by default) cannot
corrupt the JSON sidecar.

### 12.13 Failure-mode handling

If `lex_codegen` crashes mid-run (e.g. SIGKILL, OOM):

  * **Target file state.**  The atomic-rename strategy
    means the target is either fully old or fully new;
    no partial state.
  * **`.tmp` files.**  May be left orphaned.  A
    subsequent `lex_codegen` run cleans up stale
    `.tmp` files older than 60 seconds before
    proceeding.
  * **Lock files.**  Stale `.lock` files (orphaned by
    a crashed prior run) are detected via the lock-
    file's embedded PID; if the PID is dead, the lock
    is broken automatically.

If the renderer produces malformed Lean source (e.g.
unbalanced braces from a synthesizer bug):

  * `lake build` fails with a Lean syntax error
    pointing at the regenerated file.
  * The diagnostic-translation layer (§18.2) walks
    back from the error position to the
    codegen-input file via the Lex-generated
    constructor's source map; the user sees a
    diagnostic anchored at the relevant Lex law's
    surface syntax.
  * Rollback via `git revert` of the codegen run.

These failure modes are stress-tested in
`Test/Lex/Tools/Codegen.lean`'s LX.20 test suite.

### 12.14 Build-system integration

`lex_codegen` is **not** invoked automatically by `lake
build`.  This is a deliberate decoupling:

  * `lake build` is the canonical Lean compilation
    command; it should not have side-effects on the
    repository (writing source files would surprise
    users).
  * The codegen pass is *generative*: its output is
    committed source.  Treating it as a build-time
    side-effect would muddy the distinction between
    source and build artefacts.
  * The same decoupling is used by other generative
    tools in the project (e.g. `lake exe count_sorries`
    is invoked separately from `lake build`).

The developer's workflow:

  1. Edit a `law` declaration (or add a new one) in a
     `.lean` file.
  2. Run `lake build` — Lean elaborates the macro and
     writes the codegen-input JSON file.
  3. Run `lake exe lex_codegen` — the binary reads the
     codegen-input directory and updates the cross-
     module artefacts (additive in M1; canonical in M2).
  4. Run `lake build` again — the regenerated artefacts
     compile with the new constructor.
  5. Run `lake test`, `lake exe lex_lint`, etc.
  6. Commit all changed files (the `.lean` source, the
     codegen-input JSON, the regenerated artefact files,
     and the registry) in one PR.

CI's gate ordering:

```
1. lake build              (Pass 1 macro emits codegen-input JSON files)
2. lake exe lex_lint       (registry consistency, syntax-level checks)
3. lake exe lex_codegen --check
                            (verifies committed artefacts match generated)
4. lake test               (test suite)
5. lake exe count_sorries  (sorry-count gate)
6. lake exe tcb_audit      (TCB allowlist gate)
7. lake exe stub_audit     (stub-detection gate)
```

The `--check` mode (step 3) is the gating step: if a
developer commits a Lex declaration without running
`lex_codegen`, CI catches the divergence at step 3 and
fails the PR with diagnostic L026.

A future enhancement (deferred): a `pre-commit` hook
script that auto-runs `lex_codegen` before commit.
This is per-developer opt-in; it doesn't replace the
CI gate.

### 12.15 Per-PR developer workflow checklist

Adding a new Lex law (deployment-private or
kernel-extending), the author follows:

```
□ Choose a fresh action_index ≥ 17 (or next-free post-PA).
□ Add the line to Lex/IndexRegistry.txt.
□ Write the `law` declaration in the appropriate .lean file.
□ lake build — confirm Pass 1 macro succeeds.
□ lake exe lex_codegen — regenerate cross-module artefacts.
□ lake build — confirm regenerated artefacts compile.
□ lake test — confirm no test regressions.
□ lake exe lex_lint — confirm Lex-specific lint passes.
□ lake exe lex_codegen --check — confirm artefacts are committed.
□ Add a unit test in `Test/Laws/<MyLaw>.lean` exercising the
  property claims at the value level.
□ git add the .lean source, codegen-input JSON, regenerated
  artefacts, registry, and test file; commit; push; open PR.
```

The post-merge state has every committed artefact in
sync.  CI's `lex_codegen --check` re-verifies this on
every PR.

### 12.16 Multi-author merge-conflict handling

Two developers adding new Lex laws in parallel will
hit a merge conflict on `Lex/IndexRegistry.txt` (both
PRs append at the same next-free index).  The conflict
resolution:

  1. Whichever PR merges first claims the lower index.
  2. The losing PR rebases: shifts its `action_index`
    declaration up by one, re-runs `lex_codegen`,
    and re-commits.
  3. The codegen-input JSON file is renamed if the
     identifier changes (rare; happens only if a PR
     restructures namespacing during rebase).

This is a forward-only constraint: no PR can take an
already-committed index.  GitHub's branch-protection
rules can enforce a "no overlap" check via a custom CI
workflow that compares the head's registry against
trunk's.

### 12.17 Caching and incremental builds

Lake's build cache works as expected with the codegen
pass:

  * The codegen-input JSON files are content-addressed
    by their bytes.  An unchanged JSON ⇒ unchanged
    `lex_codegen` output ⇒ unchanged target file ⇒
    no `lake build` re-fire on dependent files.
  * The regenerated target files (`Authority/Action.lean`
    etc.) are tracked by Lake's content hash.  An
    unchanged regenerated file ⇒ no re-elaboration of
    files depending on it.
  * The macro's idempotent-write strategy (§6.10)
    prevents spurious `mtime` bumps on unchanged
    inputs.

Net effect: an isolated edit to a single `law`
declaration causes only that law's file plus the four
target files to re-elaborate.  The other 17 laws are
unaffected.


## §13 The `lex_lint` binary

### 13.1 What `lex_lint` checks

`Lex/Tools/Lint.lean` walks `LegalKernel/Laws/` and
`Deployments/` (in M3), parses every `.lean` file's `law`
and `deployment` declarations, and verifies a series of
properties:

  1. **Mandatory clauses present.**  Every `law` has
     `identifier`, `version`, `action_index`, `intent`,
     `signed_by`, `authorized_by`, `pre`, `impl`,
     `satisfies`.  Missing clauses emit L001 / L002 /
     L009.
  2. **Registry consistency.**  Each `action_index` in a
     `law` declaration matches the registry entry for the
     declared `identifier`.  Divergence emits L007.
  3. **Action-index uniqueness.**  No two registered laws
     share an `action_index`.  Collision emits L005.
  4. **Reserved-range discipline.**  The first 17 indices
     are reserved for `legalkernel.*`.  Violation emits
     L006.
  5. **`pre` grammar conformance.**  `pre` clauses parse
     under the §7.2 grammar.  Violation emits L003.
  6. **`impl` calculus conformance.**  `impl` blocks
     parse under the §8.1 calculus.  Violation emits L010
     / L022 / L023.
  7. **Synthesizer success.**  Every `satisfies` item
     either is dispatchable to a synthesizer or has a
     `proof <P>` override.  Lacking-both emits L004.
  8. **`intent` non-emptiness.**  The `intent` block
     contains at least one non-whitespace character.
     Empty emits L016 (a sub-class of L015 — version-bump
     discipline).
  9. **`self_only` static check.**  `authorized_by
     self_only` requires the `impl` block's static
     analysis to confirm signer-keyed mutation only.
     Violation emits L011.
  10. **Property-list well-formedness.**  `local [*]` is
      rejected (always trivially satisfied; emits L024);
      `conservative [r]` / `monotonic [r]` (with per-
      resource argument) is rejected (L025).
  11. **Manifest-level (M3).**  `deployment_id` is exactly
      32 bytes (L018); `invariant_claims` items are
      satisfiable (L008).

### 13.2 Parsing strategy

`lex_lint` does **not** invoke Lean's elaborator (would be
prohibitively expensive at audit time).  Instead, it uses
a hand-written tokenising parser that recognises:

  * The `law <ident> ( <params> ) where <clauses>` shape.
  * Each clause's keyword and argument span.
  * `pre := <expr>` clause's expression as a balanced-
    parenthesis-and-brace span (no further parsing).
  * `impl := do <stmts>` clause's statements as a `;`-
    separated list of single-line statements.

This is the same approach `Tools/CountSorries.lean` and
`Tools/TcbAudit.lean` use: regex / line-level pattern
matching, with comment / string masking applied first.

For grammar enforcement (rule 5 above), the parser is
deliberately approximate: it recognises the `∀ x : T, …`
shape (no `∈ <list>`) and emits L003, but cannot
distinguish a hand-written `Decidable` instance for
`actor_is_compliant` from one that fails to synthesize.
The Lean elaborator (Pass 1) is the authoritative check
here; `lex_lint` provides the *fast-fail* surface so CI
can short-circuit before invoking `lake build`.

### 13.3 Exit semantics

`lex_lint` exits:

  * `0` — every law passes every rule.
  * `1` — at least one law / manifest fails at least one
    rule.  Diagnostics are printed to stdout in the
    `<file>:<line>:<col>: error: L<NNN>: <message>` format;
    each diagnostic ends with a hint and remediation
    advice (per design-doc §10.2).
  * `2` — internal binary failure (e.g. cannot read a
    file, cannot find the registry).  Distinct from
    rule-failure exit code so CI can distinguish.

### 13.4 Integration with `lake build`

`lex_lint` is *not* invoked by `lake build`.  Each Lex
declaration's per-file macro (Pass 1) runs the same checks
internally; if `lake build` succeeds, `lex_lint` will
also succeed (modulo the manifest-level checks that don't
have a Lean-elaboration counterpart).

The redundancy is deliberate: `lex_lint` provides a
fast-fail audit surface for CI (it runs in seconds; `lake
build` takes minutes).


## §14 The `lex_diff` binary

### 14.1 What `lex_diff` produces

`Lex/Tools/Diff.lean` takes two git refs (or two checked-in
file paths) and emits a per-law / per-deployment semantic
diff.  Output is intended for PR descriptions, not for
machine consumption:

```
legalkernel.transfer:
  version: 1.0.0 → 1.1.0   (minor — refinement)
  pre:                     diff:
    @@ -1,2 +1,3 @@
       amount > 0
       ∧ getBalance s r sender ≥ amount
    +  ∧ amount ≤ 2^32
  impl: unchanged
  satisfies: unchanged
  events: unchanged
  intent: unchanged
```

The diff is computed on the **parsed AST**, not on source
bytes, so reformatting and comment changes do not appear.

### 14.2 Implementation strategy

`lex_diff` runs the same parser as `lex_lint`, walks both
ref states, and produces a structural diff per law:

```lean
structure LawDiff where
  identifier   : String
  versionBump  : VersionBump   -- patch | minor | major
  preDiff      : Option Diff
  implDiff     : Option Diff
  satisfiesDiff : Option Diff
  eventsDiff   : Option Diff
  intentDiff   : Option Diff
  signedByDiff : Option Diff
  authDiff     : Option Diff
```

The version bump is computed mechanically:

  * Patch (1.0.0 → 1.0.1) — proof refactors only.  No
    change to `pre`, `impl`, `signed_by`, `authorized_by`,
    `satisfies`, `events`, or `intent`.
  * Minor (1.0.x → 1.1.0) — refinement: `pre` may
    strengthen, `impl` may become more restrictive on the
    intersection of preconditions, `satisfies` may add
    items.
  * Major (1.x.0 → 2.0.0) — breaking: anything else.

If the declared version bump disagrees with the computed
one, `lex_diff` flags the discrepancy (L007 family).

### 14.3 Refinement-proof obligations

When a minor bump is detected, `lex_diff` checks for the
presence of a `proof refinement_v<old> := by …` clause in
the new version.  Missing emits L016 — the build fails
until the proof is supplied.

### 14.4 Manifest diffing

`lex_diff` also emits per-deployment diffs:

```
example.usd_clearing:
  version: 1.0.0 → 1.0.1   (patch)
  laws:
    + Burn = legalkernel.burn @ "1.0.0"     -- added
    - Reward = legalkernel.reward @ "1.0.0" -- removed (sunset)
  authority: unchanged
  invariant_claims: unchanged
  deployment_id: unchanged
```

Adding / removing laws to a manifest is a major bump
(L007); changing an authority binding is a minor bump
(deployment authors must accept the increased authorisation
risk consciously).

## §15 The `lex_format` binary

`Lex/Tools/Format.lean` is a pretty-printer that rewrites
`law` and `deployment` declarations into the canonical
form:

  * Clause order: `identifier`, `version`, `action_index`,
    `intent`, `signed_by`, `authorized_by`, `pre`, `impl`,
    `satisfies`, `events`, `proof <P>` (in registration
    order).
  * Indentation: 2 spaces inside `where`; statements in
    `impl := do` and `events := do` aligned to the
    `do` keyword's column.
  * `events := do pure ()` and `events := do nothing` →
    `events := []`.
  * Trailing whitespace removed; final newline ensured.
  * Comments preserved verbatim at their original line.

Idempotent.  Run by `pre-commit` hooks if a deployment
elects.  CI does *not* gate on `lex_format` (formatting
preferences vary across deployments); it's an
author-convenience tool.

## §16 The `deployment` manifest macro

### 16.1 Surface syntax (recap)

```ebnf
deployment ::= "deployment" ident "where" deployment_clause+

deployment_clause
   ::= "identifier"      ident_path
     | "deployment_id"   bytes_lit                    -- 32 bytes
     | "version"         string_lit
     | "resources"       ":=" resource_list
     | "laws"            ":=" law_binding_list
     | "authority"       ":=" authority_binding_list
     | "invariant_claims" ":=" claim_list
     | "attestor"        ident                         -- v2 only
```

### 16.2 Elaboration

A `deployment <name>` declaration elaborates to:

  1. **`def deployment_<name> : Deployment`** — a record
     bundling `identifier`, `deployment_id`, `version`,
     `resources`, `laws`, `authority`, and
     `invariant_claims`.
  2. **One `def` per `invariant_claims` item** —
     synthesizing `MonotonicLawSet` /
     `ConservativeLawSet` / `FreezePreservingLawSet`
     values.  See §16.3.
  3. **`def deployment_<name>_manifest_hash : ByteArray`**
     — a CBE-hash of the manifest source bytes (in v1) or
     of a structurally-canonicalised AST (in v2).  This
     value is what an attestor signs.
  4. **`def deployment_<name>_id : ByteArray`** — the
     32-byte deployment ID, exposed as a Lean constant
     for the runtime adaptor.
  5. **`def deployment_<name>_admissible : ExtendedState
     → SignedAction → Prop := AdmissibleWith Verify
     deployment_<name>_authority_policy
     deployment_<name>_id`** — the deployment-scoped
     admissibility predicate.

### 16.3 Invariant-claim synthesis

For each `invariant_claims` entry, the elaborator emits a
synthesized `def`.  Three claim shapes are supported:

  * `monotonic_law_set [L₁, …, Lₙ]`:
    ```lean
    def deployment_<name>_monotonic_law_set : MonotonicLawSet where
      laws := [
        L₁_transition <args₁>,
        …,
        Lₙ_transition <argsₙ>
      ]
      isMonotonic := by
        intro t htL
        simp [List.mem_cons] at htL
        rcases htL with hL₁ | hL₂ | … | hLₙ
        · exact (L₁_isMonotonic …).monotone
        · exact (L₂_isMonotonic …).monotone
        · …
    ```
  * `conservative_law_set [L₁, …, Lₙ]`: analogous, using
    `IsConservative` and `ConservativeLawSet`.
  * `freeze_preserving_law_set [L₁, …, Lₙ]`: analogous,
    using `FreezePreserving` and a new
    `FreezePreservingLawSet` structure (added in LX.2 as
    part of the typeclass landing).

If any `Lᵢ` lacks the required typeclass instance,
synthesis fails with diagnostic L008 naming the offending
law and the missing instance.  This is the type-level
firewall (per `docs/economic_invariants.md`'s §2) lifted
to *deployment-time* enforcement.

### 16.4 The `Deployment` record

Defined in `Lex/DSL/Deployment.lean`:

```lean
structure Deployment where
  identifier        : String
  deploymentId      : ByteArray            -- 32 bytes; checked at elaboration time
  version           : String                -- semver
  resources         : List (String × Nat)   -- (name, ResourceId)
  laws              : List LawBinding       -- (localName, lawIdent, version)
  authority         : List AuthorityBinding -- (localName, policyExpr)
  invariantClaims   : List InvariantClaim   -- preserved as data for tooling
  manifestHashBytes : ByteArray             -- the `<name>_manifest_hash` constant's value
  deriving Repr
```

The record is *non-TCB* and exists primarily so tooling
(`lex_diff`, future LSP server, future `knomosis manifest
inspect` CLI) has a structured handle.

### 16.5 Cross-deployment-replay protection

`deployment_id` flows into Audit-3.3/3.4's `signingInput`:

```lean
def signingInput (action : Action) (signer : ActorId)
    (nonce : Nonce) (deploymentId : ByteArray) : SigningInput := …
```

A signature produced for `deployment_id = 0xDEAD…` will
not verify against any other deployment's `Verify`
invocation because the deployment-ID bytes are part of the
message under signature.  `signingInput`'s injectivity in
`(action, signer, nonce, deploymentId)` is established at
the value level via the existing
`signInput_distinguishing_deployment` test (see
`Test/Encoding/SignInput.lean`).

## §17 Theorem inventory

This section enumerates every theorem and instance the
workstream introduces, with the file each lives in and
its dependency on existing kernel theorems.

### 17.1 New typeclasses (LX.2)

In `LegalKernel/Conservation.lean`:

  * **`LocalTo (S : List ResourceId) (t : Transition) : Prop`** — class declaration.
  * **`FreezePreserving (S : List ResourceId) (t : Transition) : Prop`** — class declaration.
  * **`RegistryPreserving (a : Action) : Prop`** — class declaration (indexed by `Action`, not `Transition`; see §10.2 for rationale).

In `LegalKernel/Laws/Transfer.lean`:

  * **`transfer_localTo`** : `LocalTo {r} (transfer r sender receiver amount)`.  Built from
    `transfer_does_not_touch_other_resources`.
  * **`transfer_freezePreserving`** : `FreezePreserving (manifestResources \ {r})
    (transfer r sender receiver amount)` for any deployment.  Built from
    `transfer_preserves_freeze`.
  * **`transfer_registryPreserving`** : `RegistryPreserving (Action.transfer r sender receiver amount)`.
    Trivial: `applyActionToRegistry kr (.transfer r sender receiver amount) = kr` by `rfl`
    (the `transfer` arm falls into `applyActionToRegistry`'s catch-all `_ => kr` branch).

(Analogous instances for `mint`, `burn`, `freezeResource`, `reward`,
`distributeOthers`, `proportionalDilute`, `dispute`, `disputeWithdraw`, `verdict`,
`rollback`, `deposit`, `withdraw`, `declareLocalPolicy`,
`revokeLocalPolicy` — 15 of the 17 actions get `RegistryPreserving` instances.
The two negative witnesses are deliberately absent: `replaceKey` and
`registerIdentity` mutate the registry, so `applyActionToRegistry kr
(.replaceKey actor newKey) = kr.insert actor newKey ≠ kr` (in general),
and Lean cannot derive `RegistryPreserving` for them.

Total instance count for LX.3:
  - 17 `LocalTo` (on `Transition`; one per kernel-built-in action's compiled transition;
    several actions share an instance because they compile to definitionally-equal
    transitions — e.g. all 8 actions that compile to `Laws.freezeResource _` share a
    single `LocalTo {}` instance).
  - 17 `FreezePreserving` (same sharing pattern).
  - 15 `RegistryPreserving` (on `Action`; one per non-mutating action constructor).
  - **2 deliberate absences** of `RegistryPreserving` for `replaceKey` and
    `registerIdentity`.

Net: ~31 instance landings (after deduplicating shared
`LocalTo` / `FreezePreserving` instances) plus 2 documented
absences.  The plan's earlier "51 instances" estimate
counted shared instances multiply; the corrected count
reflects the per-Transition / per-Action separation.)

### 17.2 The `FreezePreservingLawSet` structure (LX.2)

In `LegalKernel/Conservation.lean`, mirroring `MonotonicLawSet`:

```lean
structure FreezePreservingLawSet (S : List ResourceId) where
  laws              : List Transition
  isFreezePreserving : ∀ t ∈ laws, FreezePreserving S t
```

with corollary

  * **`freeze_preservation_via_law_set`** : `∀ S, ∀ (lawSet : FreezePreservingLawSet S),
    ∀ s s', ReachableViaLaws lawSet.laws s s' → ∀ r ∈ S, ∀ snap, FrozenForResource r snap s →
    FrozenForResource r snap s'`.

### 17.3 The cross-deployment-replay theorem (LX.32)

In `Lex/DSL/Deployment.lean`:

  * **`deployment_id_in_signingInput_is_injective`** : established at the value level via
    test vectors (matching the existing `Test/Encoding/SignInput.lean` pattern); the
    abstract Lean theorem for arbitrary `deploymentId₁ ≠ deploymentId₂` requires byte-
    surgery on `signInput` and is deferred (a follow-up theorem; the value-level test
    coverage is sufficient for v1 acceptance).

### 17.4 Synthesizer-emitted instance shapes

For each Lex law, the synthesizer emits one instance per
satisfies item.  The instance signatures are stable:

```lean
-- For a parameterised `law foo (p₁ : T₁) … (pₙ : Tₙ) where ...`:

-- Transition-indexed properties (4 of 5):
instance foo_isConservative
    {p₁ : T₁} … {pₙ : Tₙ} :
    IsConservative (foo_transition p₁ … pₙ) := ⟨…⟩

instance foo_isMonotonic ... : IsMonotonic (foo_transition p₁ … pₙ) := ⟨…⟩
instance foo_localTo ... : LocalTo […] (foo_transition p₁ … pₙ) := ⟨…⟩
instance foo_freezePreserving ... : FreezePreserving […] (foo_transition p₁ … pₙ) := ⟨…⟩

-- Action-indexed property (1 of 5; only present if `registry_preserving` is claimed):
instance foo_registryPreserving ... : RegistryPreserving (Action.foo p₁ … pₙ) := ⟨…⟩
```

The instance bodies are produced by the synthesizers.
The Prop-level conclusions, the type signatures, and the
constructor argument lists are all stable across
synthesizer revisions.

Note the indexing-type asymmetry: `foo_isConservative`
through `foo_freezePreserving` are indexed by the
*compiled transition* (`foo_transition p…`); only
`foo_registryPreserving` is indexed by the *action
constructor* (`Action.foo p…`).  This matches the §10.2
typeclass declarations exactly.

### 17.5 Lex-emitted regression tests

For each Lex re-expressed law (M2), a regression `example`
is emitted in the law's source file:

```lean
-- Regression: the Lex-emitted transition is definitionally
-- equal to the pre-M2 hand-written form.
example (r : ResourceId) (sender receiver : ActorId) (amount : Nat) :
    legalkernel_transfer_transition r sender receiver amount =
    LegalKernel.Laws.transfer r sender receiver amount := rfl
```

`rfl` here is a *very strong* claim: it requires that the
synthesizer's choice of statement order, parameter
substitution, and let-binding shape produce a term
*structurally identical* to the hand-written form.  This is
the M2 strict-equivalence invariant (§2.5) made
mechanical.

If any law's regression `example` fails to elaborate as
`rfl`, M2 is failed and the rollback is `git revert`.


## §18 Diagnostics catalogue

### 18.1 The 27 codes (with severity, surface, and remediation)

| Code | Severity | Surface                                                       | Remediation                                                                       | Emitted by             |
|------|----------|---------------------------------------------------------------|-----------------------------------------------------------------------------------|------------------------|
| L001 | error    | Missing `signed_by` clause                                    | Add `signed_by <actor>` naming the actor whose nonce should advance.              | macro / lex_lint       |
| L002 | error    | Missing `satisfies` clause                                    | Add `satisfies := […]` listing at least the relevant properties.                  | macro / lex_lint       |
| L003 | error    | Precondition contains undecidable subexpression `<expr>`      | Replace `<expr>` with a §6.1-grammar shape, or tag the helper `@[lex_pre]`.       | macro / lex_lint       |
| L004 | error    | Property `<P>` not synthesizable for law `<L>`                | Either weaken `satisfies` or supply `proof <P> := by …` with a manual witness.    | macro / lex_lint       |
| L005 | error    | Action index `<N>` already used by law `<L>`                  | Allocate a fresh index ≥ 17 and update `Lex/IndexRegistry.txt`.                  | macro / lex_lint / codegen |
| L006 | error    | Action index `<N>` reserved (kernel-built-in range 0..16)     | Allocate `<N> ≥ 17`.                                                              | macro / lex_lint / codegen |
| L007 | error    | Action index renumbered from `<old>` to `<new>` for `<L>`     | Restore the original index; renumbering is forbidden.                             | macro / lex_lint / codegen |
| L008 | error    | Manifest invariant claim `<C>` not satisfiable                | Either drop the claim or add the missing law's instance.                          | macro / lex_lint       |
| L009 | error    | Missing `authorized_by` clause                                | Add `authorized_by <policy>` or, if appropriate, `authorized_by self_only`.       | macro / lex_lint       |
| L010 | error    | Bare `setBalance` call in `impl`                              | Use `flow` / `mint` / `burn` / `reward` primitives.                               | macro / lex_lint       |
| L011 | error    | `self_only` declared but `impl` mutates non-signer state      | Add an `authorized_by` policy or restrict `impl` to signer-keyed mutations.       | macro / lex_lint       |
| L012 | error    | Registry-mutating law other than `replaceKey`/`registerIdentity` | Defer to v3, or hand-write the registry-effect theorems and disable lex_codegen. | macro / lex_lint       |
| L013 | warning  | `events` block omits or duplicates a balance change           | Align `events` with the cells `impl` touches, or accept the auto-filter.          | macro                  |
| L014 | warning  | Manual emission of an auto-emitted event                      | Remove the manual `emit`; the elaborator will add the canonical form.             | macro                  |
| L015 | error    | `intent` block edited without version bump                    | Bump at least the patch version when editing `intent`.                            | lex_diff               |
| L016 | error    | Refinement proof missing for minor version bump               | Supply `proof refinement_v<old> := by …`.                                         | lex_diff               |
| L017 | error    | Major version bump without action-index reservation           | Allocate a new tombstone index or use a major-bump mechanism documented in §8.    | lex_diff               |
| L018 | error    | Manifest `deployment_id` not 32 bytes                         | Pad to exactly 32 bytes; deployment IDs are fixed-width.                          | macro / lex_lint       |
| L019 | error    | `for x in <iter>:` body's iter is not statically a `List α`   | Convert via `.toList` or use a different bounded iterator.                        | macro / lex_lint       |
| L020 | error    | Unknown property `<P>` referenced in `satisfies`              | Tag a `def <P>` with `@[lex_property]` and provide a `proof <P> := …` clause.     | macro / lex_lint       |
| L021 | error    | Law has no kernel-impl effects and no authority-layer effects | Add at least one statement to `impl`; a no-effect law is not expressible.         | macro / lex_lint       |
| L022 | error    | `revoke_key` used but no `Action.revokeKey` constructor       | Defer to v3; the kernel does not yet ship a `revokeKey` Action constructor.       | macro / lex_lint       |
| L023 | error    | `impl` calls a helper not tagged `@[lex_impl]`                | Tag the helper with `@[lex_impl]` so the deployment-trusted-impl surface is auditable. | macro / lex_lint  |
| L024 | error    | `local [*]` claim (always trivially satisfied)                | Replace with `local [{r₁, …, rₙ}]` naming the touched resources, or drop the claim. | macro / lex_lint     |
| L025 | error    | Per-resource argument `[r]` to `conservative` / `monotonic`   | Drop the `[r]`; the kernel's `IsConservative` / `IsMonotonic` are universal over `ResourceId`. | macro / lex_lint |
| L026 | error    | `lex_codegen --check` finds checked-in artefact divergence    | Run `lake exe lex_codegen` and commit the regenerated files.                      | codegen --check        |
| L027 | error    | Bare `s` reference inside `events := do …`                    | Use the explicit `preState` or `postState` name; `s` is ambiguous.                | macro / lex_lint       |

### 18.2 The diagnostic-translation layer

Every diagnostic must point at the user's surface syntax,
not at the macro-expanded Lean term.  This is achieved by:

  1. **Source-position threading.**  Each `LawDecl` /
     `ImplStmt` / `PreNode` carries a `sourcePos : Position`
     field captured from the original `Syntax` value at
     parse time (via Lean's `Lean.Syntax.getPos?` and
     `Lean.Syntax.getTailPos?` accessors).
  2. **Walker-anchored emission.**  The grammar enforcer,
     synthesizer, and codegen pass each emit diagnostics
     anchored to the relevant node's `sourcePos`.
  3. **Macro-expansion fallback.**  If a Lean-level error
     (e.g. instance synthesis failure inside a synthesizer
     body) bubbles up without a `sourcePos`, the macro
     walks the Lean expansion tree, finds the nearest
     source-mapped node, and re-emits the diagnostic at
     that position.

The format is consistent across emitters:

```text
<file>:<line>:<col>: error: L<NNN>: <message>
  --> note: <context>
  --> note: <auxiliary location, if relevant>
  --> hint: <remediation 1>
  --> hint: <remediation 2>
```

#### 18.2.1 Concrete mechanism

Lean 4's elaborator distinguishes three position kinds:

  * **`Lean.Syntax` source position.**  Always points at
    user-written source.  Captured via
    `Syntax.getRange?`.
  * **Elaboration-site position.**  Points at the command
    invocation site (the user's `law` keyword).  Lean
    propagates this via `CommandElabM`'s `withRef` /
    `withFreshMacroScope` combinators.
  * **Generated-term position.**  Points at the macro's
    generated term, which has *no* source location by
    default.  Lean substitutes the macro-invocation
    position when surfacing errors in generated code.

The `Diagnostic` record's emission honours these layers:

```lean
structure ClauseSource where
  startPos : Lean.Position    -- character position in the source file
  endPos   : Lean.Position
  fileName : System.FilePath  -- absolute path
  deriving Repr, Inhabited

structure Diagnostic where
  code     : String           -- "L003", "L010", etc.
  severity : Severity         -- error | warning | info
  source   : ClauseSource     -- where the diagnostic anchors
  message  : String           -- the headline message
  notes    : List String      -- auxiliary context lines
  hints    : List String      -- remediation suggestions
  deriving Repr

def Diagnostic.emit (d : Diagnostic) : Lean.Elab.Command.CommandElabM Unit := do
  let ref : Lean.Syntax := Lean.Syntax.atom
    (SourceInfo.original d.source.startPos d.source.endPos)
    ""
  Lean.throwErrorAt ref d.formatMessage
```

The `Lean.throwErrorAt` invocation is what anchors the
error at the user's surface syntax (the function is
available in any monad with a `MonadRef` instance,
including `CommandElabM` and `MacroM`).  Lean's
elaborator preserves the supplied `Syntax` reference's
position when surfacing the error in `lake build`'s
output.

#### 18.2.2 Surface-vs-generated error pathways

Three error pathways arise in practice:

  * **Pathway A (surface):**  Lex's grammar / calculus
    enforcers detect a violation at parse time.  The
    enforcer's source-position threading provides the
    exact `Syntax` node; the diagnostic anchors there
    naturally.
  * **Pathway B (generated):**  A Lean-level error
    surfaces inside the macro's generated `def` /
    `instance` (e.g. a type mismatch in the synthesized
    body).  Lean's default behaviour anchors the
    diagnostic at the *macro-invocation site* (the
    user's `law` keyword), which is approximate but
    usable.  The diagnostic-translation layer's
    fallback walks the Lean elaboration error's
    `Syntax` reference, locates the nearest source-
    mapped parent, and re-emits the diagnostic with
    that position plus a note indicating "(error
    surfaced from generated code)".
  * **Pathway C (codegen):**  An error surfaces during
    Pass 2 (`lex_codegen`).  The binary reads each
    codegen-input JSON file's `source_location` field
    and includes it verbatim in the diagnostic; users
    see a position pointing at their original `law`
    declaration even though Pass 2 ran much later.

#### 18.2.3 Multi-file-aware error reporting

When a diagnostic spans multiple files (e.g. a
`satisfies` claim references a property defined in a
sibling module), the formatter prints both:

```text
LegalKernel/Laws/Foo.lean:42:3: error: L020: Unknown property `KYC_compliant`
  --> note: in `satisfies` clause of law `legalkernel.foo`
  --> note: defined here:
      LegalKernel/Compliance/KYC.lean:18:1: def KYC_compliant : Transition → Prop := ...
  --> hint: tag the definition with @[lex_property]
```

This is the standard Lean diagnostic formatting; Lex
uses it whenever cross-file references arise.

#### 18.2.4 Testing the translation layer

`Test/Lex/Tools/Common.lean` includes a "diagnostic
fidelity" test suite (~6 cases as part of LX.4) that
exercises each pathway:

  * Pathway A: trigger a forbidden `pre` shape, assert
    the error position matches the user's source.
  * Pathway B: trigger an instance-synthesis failure in
    a generated synthesizer body, assert the error
    position is anchored at the surface (not at the
    generated `instance` declaration).
  * Pathway C: trigger a codegen failure, assert the
    error position is read from the codegen-input
    JSON file's `source_location` field.

Future work: a v2 LSP integration would expose the
diagnostic positions natively to the user's editor
without text-level parsing of the diagnostic message.
This is on the v3 roadmap (design-doc §13.3).

### 18.3 Diagnostic stability

The numeric codes (L001 – L027) are committed to the
project's external surface.  Renaming or renumbering a code
is a breaking change for downstream tooling (CI scripts,
dashboards, grep-based searches).  L-codes are appended
at the end of the catalogue when new diagnostics are added.

A retired diagnostic's code remains in the catalogue
forever as a tombstone:

```
| L042 | (retired in v2) | (retired in v2) | This diagnostic was replaced by … in v2. |
```

This matches the project's "frozen indices are immovable"
discipline applied to diagnostics.


## §19 Work-unit breakdown

Each work unit is independently buildable, testable, and
reviewable, with the build green at every commit boundary.
This section's per-WU specification is intentionally
detailed: each entry lists files-to-create, files-to-
modify, deliverable Lean declarations / theorems / tests,
acceptance criteria, dependencies on prior WUs, and an
effort estimate (lines of code added; reviewer-hours;
risk class).

The plan splits into **38 work units** across three
milestones, each milestone landing as a separable PR with
its own subset of the §24 acceptance criteria:

  * **M1** (LX.1 – LX.21) — macro skeleton, synthesizer
    library, additive codegen, example Lex law.
  * **M2** (LX.22 – LX.30) — re-express the 17 kernel-
    built-in laws in Lex; flip codegen to canonical
    regeneration mode; deprecate Phase-4 `Law.mk`.
  * **M3** (LX.31 – LX.38) — deployment manifests, semantic
    diff / format binaries, worked example, property-test
    auto-generation.

The 23 work units of the v1 draft (committed in the prior
plan revision) have been **decomposed into 38 finer-
grained units** to better match the project's review
cadence (1 WU ≈ 1 PR, 1 WU ≈ 1–3 reviewer hours, 1 WU ≈
fewer than 500 LOC of net additions).  This is consistent
with the LP / PA workstreams' WU-size distribution.

### 19.1 Dependency DAG

```
LP.14 (post-LP, prerequisite)
  ↓
LX.1 ─ LX.2 ─ LX.3 ─ LX.4 ─ LX.5 ─ LX.6 ─ LX.7 ─ LX.8 ─ LX.9 ─ LX.10 ─ LX.11
                                                                        ↓
LX.12 ─ LX.13 ─ LX.14 ─ LX.15 ─ LX.16
                                  ↓
LX.17 ─ LX.18 ─ LX.19 ─ LX.20
                          ↓
                        LX.21  (M1 ACCEPTANCE)
                          ↓
LX.22 ─ LX.23 ─ LX.24 ─ LX.25 ─ LX.26 ─ LX.27 ─ LX.28 ─ LX.29
                                                          ↓
                                                        LX.30  (M2 ACCEPTANCE)
                                                          ↓
LX.31 ─ LX.32 ─ LX.33 ─ LX.34 ─ LX.35 ─ LX.36 ─ LX.37
                                                  ↓
                                                LX.38  (M3 ACCEPTANCE)
```

Within M1, several units can land in parallel after the
foundational ones (LX.4 / LX.5 / LX.6 / LX.11) are in
place: LX.7 (pre enforcer) and LX.8 (impl enforcer) are
independent; LX.13 / LX.14 / LX.15 (synthesizers) are
independent of each other; LX.17 / LX.18 / LX.19
(codegen renderers) are independent.  Within M2, the law
re-expressions LX.22 – LX.29 are independent (each
exercises one or two laws); they can land in any order
provided LX.30 (canonical-mode flip) lands last.  M3's
LX.31 – LX.36 have a sequential constraint
(LexDeployment must land before LexDiff can diff
deployments), but LX.36 (LexFormat) can land in
parallel with LX.34 / LX.35 (LexDiff phases).

### 19.2 Effort-class legend

Each WU entry tags its effort class:

  * **S (small):** ≤ 200 LOC additions, ≤ 1 reviewer-hour,
    no novel design decisions.
  * **M (medium):** ≤ 500 LOC additions, ≤ 3 reviewer-
    hours, design decisions documented in this plan.
  * **L (large):** ≤ 1000 LOC additions, ≤ 6 reviewer-
    hours, may surface implementation-level decisions
    needing discussion.
  * **X (extra-large):** > 1000 LOC additions; requires
    splitting if encountered (X-class WUs should not
    appear in this plan; if one is uncovered during
    execution, it becomes a multi-WU sub-workstream).

Risk class:

  * **green** — no kernel-correctness risk; bugs surface as
    diagnostic / build / test failures.
  * **yellow** — could produce a wrong but compiling
    artefact; mitigated by regression tests and post-
    landing audit.
  * **red** — could violate a kernel invariant; requires
    two-reviewer gate per CLAUDE.md.  No LX work unit is
    `red` by design (LX is non-TCB).

### 19.3 Milestone M1 — macro skeleton, synthesizers, additive codegen

#### LX.1 — Action-index registry + codegen-input directory

**Effort:** S.  **Risk:** green.  **Depends on:** LP.14.

**Files (new):**

  * `Lex/IndexRegistry.txt` — initialised with the 17
    existing constructors per §4.1.
  * `Lex/Inputs/.gitkeep` — empty file
    asserting the directory exists.
  * `Lex/Inputs/README.md` — schema docs
    summarising §5.2.

**Files modified:**

  * `.gitignore` — explicit *include* of
    `Lex/Inputs/*.json` (these are committed,
    not ignored).
  * `lakefile.lean` — add `extraDepTargets` registering
    the registry file so `lake build` re-fires when the
    registry changes.

**Deliverables:**

  * Registry file with 17 entries in increasing-index
    order, format `<identifier>  <index>  <release>`.
  * Commit-pre-checks that the file is well-formed via a
    pre-commit shell script (optional; not enforced by
    CI).

**Acceptance criteria:**

  * `lake build` succeeds (no Lean code changes).
  * `lake test` succeeds (no test changes).
  * `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit` all pass.
  * The registry-file format passes a shell `awk`
    consistency check (indices monotone, unique
    identifiers, semver-shaped releases).

**Test files:** none new.

**Rollback path:** revert is trivial (add new files only).

#### LX.2 — New non-TCB typeclasses + `FreezePreservingLawSet`

**Effort:** M.  **Risk:** green.  **Depends on:** LX.1.

**Files modified:**

  * `LegalKernel/Conservation.lean` — add the three new
    typeclasses (`LocalTo`, `FreezePreserving`,
    `RegistryPreserving`) and the `FreezePreservingLawSet`
    structure plus `freeze_preservation_via_law_set`
    corollary.

**Deliverables:**

  * `class LocalTo (S : List ResourceId) (t : Transition) : Prop` with single field `local_to`.
  * `class FreezePreserving (S : List ResourceId) (t : Transition) : Prop` with single field `preserves`.
  * `class RegistryPreserving (a : Action) : Prop` with single field `preserves` (indexed by `Action`, not `Transition` — see §10.2 for rationale).
  * `structure FreezePreservingLawSet (S : List ResourceId)` with two fields (`laws`, `isFreezePreserving`).
  * `theorem freeze_preservation_via_law_set` — typeclass-driven non-decrease corollary mirroring `total_supply_global_via_law_set`.

**Acceptance criteria:**

  * `lake build LegalKernel.Conservation` succeeds.
  * `#print axioms` on the new theorem returns a subset of
    `{propext, Classical.choice, Quot.sound}`.
  * `lake exe tcb_audit` passes (the new typeclasses live
    in the same non-TCB module that already hosts
    `IsConservative` / `IsMonotonic`).
  * No new `sorry`.

**Test files:** `Test/ConservationTests.lean` extended
with 5 cases:

  * `LocalTo` decidability sanity (a freshly-built
    instance resolves via `inferInstance`).
  * `FreezePreserving` smoke test with empty resource
    set (vacuously true).
  * `RegistryPreserving` smoke test on an identity
    transition.
  * `FreezePreservingLawSet` constructibility on a
    one-element law list.
  * `freeze_preservation_via_law_set` API stability check.

#### LX.3 — Per-existing-law typeclass instances

**Effort:** M.  **Risk:** green (mechanical; uses existing theorems).  **Depends on:** LX.2.

**Files modified:**

  * `LegalKernel/Laws/Transfer.lean`
  * `LegalKernel/Laws/Mint.lean`
  * `LegalKernel/Laws/Burn.lean`
  * `LegalKernel/Laws/Freeze.lean`
  * `LegalKernel/Laws/Reward.lean`
  * `LegalKernel/Laws/DistributeOthers.lean`
  * `LegalKernel/Laws/ProportionalDilute.lean`
  * `LegalKernel/Laws/Deposit.lean`
  * `LegalKernel/Laws/Withdraw.lean`
  * `LegalKernel/Disputes/LawClassification.lean`
  * `LegalKernel/LocalPolicy/LawClassification.lean`
  * `LegalKernel/Authority/SignedAction.lean` (for
    `replaceKey` / `registerIdentity` instances; LP /
    PA do not affect this).

**Deliverables:**

  * `LocalTo` instances per *compiled transition*: distinct
    transitions get distinct instances; actions sharing a
    transition (e.g. the 9 actions that compile to
    `Laws.freezeResource _`) share a single
    `LocalTo {} (Laws.freezeResource _)` instance.  Net:
    ~9 `LocalTo` instances landed (one per equivalence
    class of compiled transitions).
  * `FreezePreserving` instances on the same per-transition
    basis: ~9 instances landed.
  * 15 `RegistryPreserving` instances per *Action
    constructor* (excluding `replaceKey` and
    `registerIdentity`, which mutate the registry by
    design).
  * **2 deliberate absences** of `RegistryPreserving` for
    `replaceKey` and `registerIdentity` — Lean's
    `inferInstance` fails for these by construction (no
    instance is provided), serving as the negative
    witness.

The shared-instance pattern (`LocalTo` / `FreezePreserving`
on the kernel-level transition) is what allows the M2 strict-
equivalence invariant to hold byte-for-byte: every action
that compiles to `Laws.freezeResource _` participates in
the same instance bag, matching the pre-LX hand-written
form's structural shape.

**Acceptance criteria:**

  * Each instance proves using exactly the existing per-law theorems
    (e.g. `transfer_does_not_touch_other_resources` for
    `transfer_localTo`).  No new theorem infrastructure.
  * Each instance `#print axioms` returns the standard three.
  * `lake build` succeeds.
  * `lake test` passes.

**Test files:** `Test/ConservationTests.lean` extended
with 17 instance-resolution tests — one
`example : LocalTo {r} (Laws.transfer r s r' am) := inferInstance`-style
check per law, exercising both the typeclass declaration and the
per-law instance landing.

#### LX.4 — `Lex/Tools/Common.lean` shared infrastructure

**Effort:** L.  **Risk:** green.  **Depends on:** LX.1.

**Files (new):**

  * `Lex/Tools/Common.lean` — shared utilities consumed by
    `LexLint`, `LexCodegen`, `LexDiff`, `LexFormat`.

**Files modified:**

  * `lakefile.lean` — declare `lean_lib LexCommon`.

**Deliverables:**

  * `LawDecl` Lean structure mirroring §5.2's JSON schema
    (every field a Lean-typed value, with `Repr` and
    `DecidableEq` instances).
  * `RegistryEntry` structure + `parseRegistry`.
  * `loadCodegenInputs : System.FilePath → IO (List LawDecl)` reading the directory.
  * `LawDecl.toJson` / `LawDecl.fromJson` codec via
    `Lean.Json` (deterministic field order).
  * `Diagnostic` record (`code`, `severity`, `position`,
    `message`, `notes`, `hints`) plus the standard
    formatter producing the `<file>:<line>:<col>: error: L<NNN>: …` shape.
  * `Position` threading utilities (alias for `Lean.Position`).
  * Source-mapped error helpers: `Diagnostic.error`,
    `Diagnostic.warning`, `Diagnostic.atSyntax`.
  * Generic file-walker `walkLeanFiles : System.FilePath → IO (List System.FilePath)`.

**Acceptance criteria:**

  * `lake build Lex.Tools.Common` succeeds.
  * Round-trip: `parseRegistry (formatRegistry r) = .ok r`
    on representative inputs.
  * Round-trip: `LawDecl.fromJson (LawDecl.toJson l) = .ok l`
    on representative inputs.
  * Determinism: two `LawDecl.toJson` invocations on the
    same `LawDecl` produce byte-identical bytes.

**Test files:** `Test/Lex/Tools/Common.lean` (new) — 14 cases:

  * 6 cases on registry parsing (happy path; malformed
    line; duplicate identifier; duplicate index;
    out-of-order; gap detection).
  * 4 cases on JSON round-trip (each `LawDecl` field
    type — primitive, list, AST node).
  * 2 cases on file-walker (empty directory; mixed
    `.lean` and non-`.lean` content).
  * 2 cases on diagnostic formatting (error, warning).

#### LX.5 — `Lex/Tools/Lint.lean` skeleton

**Effort:** S.  **Risk:** green.  **Depends on:** LX.4.

**Files (new):**

  * `Lex/Tools/Lint.lean` — audit binary skeleton.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_lint`,
    `supportInterpreter := true`.
  * `.github/workflows/ci.yml` — append `lake exe lex_lint`
    to the CI matrix (no-op pre-LX.6 since no Lex
    declarations exist yet).

**Deliverables:**

  * `Lex/Tools/Lint.lean`'s `main : List String → IO UInt32`.
  * Initial check set: registry well-formedness only
    (rules 1–5 of §13.1).  Macro-level checks are added
    by LX.7 / LX.8 / LX.10 / LX.16 as the corresponding
    macro features land; `lex_lint` consumes the same
    walkers via `LexCommon`.
  * Exit code semantics per §13.3.

**Acceptance criteria:**

  * `lake build Lex.Tools.Lint` succeeds.
  * `lake exe lex_lint` exits 0 on the registry from
    LX.1.
  * A deliberately corrupted test registry (gap in
    indices) fails with exit code 1 and the L007 code
    in stderr.
  * CI matrix passes.

**Test files:** `Test/Lex/Tools/Lint.lean` (new) — 6 cases:

  * Clean registry → exit 0.
  * Each of L005, L006, L007, L018 (those rules covered
    in this WU's check set) → exit 1 with correct code.
  * Internal-failure exit (cannot find file) → exit 2.

#### LX.6 — `Lex/DSL/Law.lean` Phase 1: surface syntax + clause parser

**Effort:** L.  **Risk:** green.  **Depends on:** LX.4.

**Files (new):**

  * `Lex/DSL/Law.lean` — the `law` macro
    skeleton.  Phase-1 deliverable: parses the surface
    syntax into a `LawDecl` value and emits no
    declarations yet (no Lean code generated; the
    macro elaborates to a `#check ()` placeholder).

**Files modified:**

  * `LegalKernel.lean` — re-export
    `Lex.DSL.Law`.

**Deliverables:**

  * Lean `syntax` declarations for the `law` keyword and
    every clause keyword (`identifier`, `version`,
    `action_index`, `intent`, `signed_by`,
    `authorized_by`, `pre`, `impl`, `satisfies`,
    `events`, `proof`).
  * `parseLawDecl : Lean.Syntax → Lean.Elab.Command.CommandElabM (Except Diagnostic LawDecl)` — converts the parsed `Syntax` to a `LawDecl` value, surfacing missing-clause errors (L001 / L002 / L009).
  * Source-position threading: every clause's syntax
    position is captured in the `LawDecl`.
  * Placeholder `elab_rules : command` block emitting only
    a `pure ()` ensuring the parsed law can be referenced
    at the call site without polluting the namespace.
    Subsequent WUs (LX.7 – LX.11) extend this elaborator
    with grammar enforcement, calculus enforcement,
    instance generation, and the codegen-input write.

**Acceptance criteria:**

  * `lake build Lex.DSL.Law` succeeds.
  * A minimal `law foo where identifier example.foo
    version "1.0.0" action_index 17 intent {…} signed_by
    actor authorized_by self_only pre := … impl := …
    satisfies := []` elaborates without error (the
    placeholder emits `#check ()` only).
  * Each missing-required-clause variant emits the
    expected L-code at the law's source position.

**Test files:** `Lex/Test/DSL/Law.lean` (new) — 12 cases:

  * 1 minimal-law happy-path elaboration.
  * 9 missing-required-clause cases (one per required
    clause).
  * 1 unknown-clause-keyword case (graceful failure).
  * 1 source-position fidelity check (a `pre := …`
    error's `(file, line, col)` matches the
    `Position` field in the surface syntax).

#### LX.7 — `pre` grammar enforcer + `@[lex_pre]` attribute

**Effort:** L.  **Risk:** yellow (over-conservatism causes user friction; mitigation is the `@[lex_pre]` escape valve).  **Depends on:** LX.6.

**Files modified:**

  * `Lex/DSL/Law.lean` — extend with the
    `parsePreExpr : Term → Except Diagnostic PreNode`
    walker (per §7.3) and the `@[lex_pre]` attribute
    declaration.
  * `Lex/Tools/Lint.lean` — extend the lint binary with a
    parallel string-level grammar enforcer.  The macro's
    Lean-side enforcer is authoritative; lint catches the
    same shape pre-build for fast feedback.

**Deliverables:**

  * `inductive PreNode` per §7.2's signature.
  * `inductive NatNode`, `ActorNode`, `ResourceNode`,
    `BoundedIter` per §7.2.
  * `parsePreExpr : Term → Except (Position × String) PreNode`
    walker exhaustive over the §7.2 grammar.
  * `parseNatExpr` etc. helpers.
  * `@[lex_pre]` `Lean.ParametricAttribute` declaration
    (per §7.4).
  * `checkLexPreDecidability` attach-time decidability
    check (best-effort: synthesizes a `Decidable` for the
    tagged function applied to one representative input
    each; failure rejects the attribute attach).
  * Diagnostic emission for L003 anchored at the
    offending sub-expression's source position.

**Acceptance criteria:**

  * `lake build Lex.DSL.Law` succeeds.
  * Each forbidden-shape variant in §7.5 fires L003 at the
    correct source position.
  * Allowed-shape predicates (§7.6 example) elaborate
    cleanly.
  * `@[lex_pre]` rejects a non-decidable predicate at
    attach time with a clear error.

**Test files:** `Lex/Test/DSL/Law.lean` extended (+15
cases): 8 forbidden-shape rejections, 5 allowed-shape
acceptances, 2 `@[lex_pre]` attribute attach-time tests.

#### LX.8 — `impl` calculus enforcer + `@[lex_impl]` attribute

**Effort:** L.  **Risk:** yellow.  **Depends on:** LX.6 (independent of LX.7; can land in parallel).

**Files modified:**

  * `Lex/DSL/Law.lean` — extend with the
    `parseImplCalculus : Lean.Syntax → Except Diagnostic (List ImplStmt)`
    walker (per §8) and the `@[lex_impl]` attribute.
  * `Lex/Tools/Lint.lean` — extend with the parallel
    string-level calculus enforcer.

**Deliverables:**

  * `inductive ImplStmt` covering all the §8.1 calculus
    primitives plus the bare-term escape hatch.
  * `parseImplCalculus` walker.
  * Per-statement effect classification: kernel-impl /
    authority / host (§8.2).
  * Desugaring functions: `desugarFlow`,
    `desugarMintBurn`, `desugarReward`, `desugarFreeze`,
    `desugarRegisterKey`, `desugarFor`, `desugarIf`,
    `desugarLet`.
  * `@[lex_impl]` `Lean.TagAttribute` declaration.
  * Diagnostic emission for L010, L019, L022, L023.

**Acceptance criteria:**

  * Each forbidden-shape variant in §8.5 fires the right
    L-code at the right position.
  * `flow` desugaring exactly matches the §4.11
    self-transfer-fix shape (verified by string-level
    comparison of the emitted desugaring against the
    `Laws.transfer` body).
  * `@[lex_impl]` attribute attach-time check is a no-op
    pass-through (no decidability requirement).

**Test files:** `Lex/Test/DSL/Law.lean` extended (+18
cases): per-primitive happy paths, per-forbidden-shape
rejections, the self-transfer-fix shape pin, mixed
kernel-impl + authority effect routing.

#### LX.9 — `signed_by` / `authorized_by` semantics + shim generation

**Effort:** M.  **Risk:** yellow (the shim's correctness
gates every Lex law's admissibility check).  **Depends on:** LX.8.

**Files modified:**

  * `Lex/DSL/Law.lean` — extend the macro to
    emit the `signed_by`-strengthened shim and the
    `authorized_by`-validated policy reference.

**Deliverables:**

  * Per-law `def <law>_apply` shim (per §9.2) carrying
    the `h_signer : st.signer = sender` extra hypothesis.
  * `self_only` static-analysis check (per §9.3).
  * `authorized_by self_only` rejection for non-signer-
    keyed mutations (L011).
  * `signed_by` actor name recorded in the codegen-input's
    `signed_by` field for downstream synthesizers (LX.15).
  * Decidability of `h_signer` via `DecidableEq ActorId`.

**Acceptance criteria:**

  * The shim compiles for the minimal Lex law fixture
    from LX.6.
  * `self_only` rejects a `flow r amt from other to
    sender` statement under L011.
  * The shim's parameter list + body match §9.2's
    template structurally.

**Test files:** `Lex/Test/DSL/Law.lean` extended (+8
cases): shim-shape stability, `self_only` happy path
(every statement is signer-keyed), `self_only` rejection
paths, signed_by name binding.

#### LX.10 — `events` block elaborator + `@[lex_event_ctor]` attribute

**Effort:** L.  **Risk:** green.  **Depends on:** LX.6.

**Files modified:**

  * `Lex/DSL/Law.lean` — extend the macro with
    the `parseEventBlock` walker and the
    `@[lex_event_ctor]` attribute.

**Deliverables:**

  * `inductive EventStmt` covering `let` / `emit` /
    `ifEmit` / `for`.
  * `parseEventBlock` walker.
  * Desugaring to a `List Event`-valued expression
    threading through `(preState, postState) :
    LegalKernel.State × LegalKernel.State`.
  * `@[lex_event_ctor]` attribute marking which `Event`
    constructors are admissible inside `emit`.  The 13
    existing constructors (post-LP) are tagged in this
    WU.
  * Diagnostic emission for L013, L014, L027.
  * The empty-form `events := []` accepted alongside
    `events := do pure ()` and `events := do nothing`;
    `lex_format` (LX.36) canonicalises to `events := []`.

**Acceptance criteria:**

  * Empty-form `events := []` elaborates.
  * Multi-statement events block with `let` + conditional
    `emit` elaborates correctly and produces the expected
    `List Event` value at fixed `(preState, postState)`.
  * The L013 warning fires when `events` omits a touched
    cell or includes an untouched one.
  * `emit` of an untagged `Event` constructor emits L020.

**Test files:** `Lex/Test/DSL/Law.lean` extended (+12
cases): empty form, single-emit, conditional-emit, fold-
emit, the three diagnostic cases, attribute-tagged
constructors.

#### LX.11 — Codegen-input JSON writer + idempotency

**Effort:** M.  **Risk:** yellow (idempotency bugs cause spurious build re-fires).  **Depends on:** LX.6, LX.7, LX.8, LX.10.

**Files modified:**

  * `Lex/DSL/Law.lean` — extend the macro
    elaboration pipeline to write the codegen-input JSON
    file at the end of Pass 1.

**Deliverables:**

  * `LawDecl.toCanonicalJson : LawDecl → String` —
    produces deterministic JSON with field order matching
    §5.2 exactly, no trailing whitespace, fixed indent.
  * `writeCodegenInput : LawDecl → IO Unit` — writes the
    JSON to `Lex/Inputs/<identifier>.json`.
  * `writeCodegenInputIdempotent : LawDecl → IO Unit` —
    the production wrapper: reads any existing file,
    parses it, compares structurally to the new
    `LawDecl`, skips the write if equal (no `mtime`
    bump).
  * Atomic write strategy: write to
    `<identifier>.json.tmp`, then rename to
    `<identifier>.json`.  Avoids partial-file states
    visible to a concurrent reader.
  * Command-level `IO.FS.writeFile` invocation via
    `liftIO` inside `CommandElabM` (the `law` keyword
    is registered as a Lean 4 *command* via `elab_rules :
    command`, which has full IO access; this is distinct
    from the pure `MacroM` used by the Phase-4 `Law.mk`
    macro, which has no IO surface).

**Acceptance criteria:**

  * The minimal Lex law from LX.6 produces a codegen-
    input JSON file at the expected path.
  * Re-elaborating the same law produces no file-system
    write (idempotency check fires).
  * Two concurrent elaborations (simulated via two
    `lake build` processes on a clean checkout) do not
    corrupt the file (atomic-rename verified by replay).
  * `LawDecl.fromJson` round-trip succeeds on every
    written file.

**Test files:** `Lex/Test/DSL/Law.lean` extended (+8
cases): write happy path, idempotency (no-mtime-bump on
unchanged), atomic-rename verified at the IO level,
schema-version pin (`schema_version = 1` is present),
JSON round-trip (`fromJson ∘ toJson = id`).

#### LX.12 — `Lex/DSL/Property.lean` skeleton + `@[lex_property]` attribute + dispatch table

**Effort:** M.  **Risk:** green.  **Depends on:** LX.11.

**Files (new):**

  * `Lex/DSL/Property.lean` — the synthesizer
    library skeleton.

**Files modified:**

  * `Lex/DSL/Law.lean` — wire the macro's
    `satisfies` clause emission to the synthesizer
    dispatcher.

**Deliverables:**

  * `inductive PropertyClaim` enumerating the seven v1
    property names plus user-defined.
  * `parsePropertyList : Lean.Syntax → Except Diagnostic (List PropertyClaim)`.
  * `dispatchSynthesizer : PropertyClaim → ImplCalculus → Except Diagnostic (Lean.Term)` — the central dispatch (initially calling stub synthesizers; LX.13 – LX.15 fill in the real bodies).
  * `@[lex_property]` `Lean.TagAttribute` for user-defined
    property names.
  * Diagnostic emission for L004 (synthesizer failure),
    L020 (untagged user-property), L024 (`local [*]`),
    L025 (per-resource `[r]` on `conservative` /
    `monotonic`).
  * Stub synthesizers returning a "not implemented"
    diagnostic; LX.13 – LX.15 replace them with real
    bodies.

**Acceptance criteria:**

  * `lake build Lex.DSL.Property` succeeds.
  * The minimal Lex law's `satisfies := []` block is
    accepted (no claims, no synthesizer firing).
  * A `satisfies := [conservative]` block with the stub
    synthesizers fails L004 with the placeholder
    diagnostic (this becomes a real success when LX.13
    lands).

**Test files:** `Lex/Test/DSL/Property.lean` (new) — 8
cases: parse positive (each property name), parse
negative (L024 / L025), `@[lex_property]` happy path,
`@[lex_property]` not-tagged rejection (L020), stub
dispatcher.

#### LX.13 — `synth_conservative` + `synth_monotonic`

**Effort:** L.  **Risk:** yellow (synthesizer correctness gates every law's classification).  **Depends on:** LX.12, LX.3.

**Files modified:**

  * `Lex/DSL/Property.lean` — replace the stub
    synthesizers for `conservative` and `monotonic` with
    real bodies.

**Deliverables:**

  * `synth_conservative : ImplCalculus → SynthResult Lean.Term` — succeeds iff every kernel-impl statement is conservation-preserving (`flow` / `freeze_resource` / `register_key` / no-op kernel branch); fails on `mint` / `burn` / `reward` / `for` / `bareTerm`.
  * `synth_monotonic : ImplCalculus → SynthResult Lean.Term` — succeeds on `flow` / `mint` / `reward` / `freeze_resource` / `register_key` / `register_identity`; fails on `burn` / `for` / `bareTerm`.
  * Per-statement composition: each statement's witness
    chains through `IsConservativeProof.cons` /
    `IsMonotonicProof.cons` (introduced as helper data
    types) so the emitted instance body is a
    `cases`-on-`impl_calculus` pattern producing one Lean
    sub-term per statement.
  * The emitted Lean term is byte-identical to the
    pre-LX.13 hand-written instance for the kernel-built-
    in laws; a regression `example` in
    `LegalKernel/Laws/Transfer.lean` (added at LX.22)
    pins this via `rfl`.

**Acceptance criteria:**

  * Single-`flow` `impl_calculus` produces a
    `conservative` synthesizer success matching the
    `transfer` law's pre-existing `IsConservative`
    instance (byte-identical Lean term).
  * Single-`mint` produces a `monotonic` success but a
    `conservative` failure (L004 with a hint pointing at
    `mint`).
  * Single-`burn` produces a `conservative` failure AND a
    `monotonic` failure (L004 in both cases).
  * `bareTerm` / `for` produce L004 with hints.

**Test files:** `Lex/Test/DSL/Property.lean` extended
(+18 cases): per-primitive synthesizer outcome (positive /
negative for each of 9 primitives × 2 properties), plus
chained-statement compositions.

#### LX.14 — `synth_local` + `synth_freeze_preserving`

**Effort:** L.  **Risk:** yellow.  **Depends on:** LX.12, LX.3.

**Files modified:**

  * `Lex/DSL/Property.lean` — fill in the
    parameterised `local [{r₁,…}]` and
    `freeze_preserving [{r₁,…}]` synthesizers.

**Deliverables:**

  * `synth_local : List ResourceId → ImplCalculus → SynthResult Lean.Term` — succeeds iff every kernel-impl statement's resource is in the supplied set; fails with L004 naming the offending statement and the resource that escaped the set.
  * `synth_freeze_preserving : List ResourceId → ImplCalculus → SynthResult Lean.Term` — succeeds iff every kernel-impl statement is on a resource ∉ the set, or `pre` is decidable-incompatible with `FrozenForResource r snap s` for each `r` in the set.
  * Wildcard `freeze_preserving [*]` resolution: at
    *manifest-elaboration time* (LX.33), the wildcard is
    expanded to the manifest's full resource list; at
    Lex-law-elaboration time, the synthesizer accepts it
    as a *family* check (succeeds iff the law touches no
    resource at all).

**Acceptance criteria:**

  * Single-`flow r₁ amt from a to b` with claim `local [{r₁}]` succeeds; with `local [{r₂}]` fails L004.
  * `local [*]` rejection at the parser surface (L024).
  * `freeze_preserving [{r₂}]` on a `flow r₁ …` law succeeds (the law's kernel-impl is on `r₁`, which is outside the freeze set).
  * Wildcard `freeze_preserving [*]` on a no-op law (kernel-impl identity) succeeds.

**Test files:** `Lex/Test/DSL/Property.lean` extended (+12
cases): per-set-membership variants for `local`, per-
resource-presence variants for `freeze_preserving`,
wildcard expansion sanity.

#### LX.15 — `synth_nonce_advances` + `synth_registry_preserving`

**Effort:** S.  **Risk:** green (these are derived/trivial).  **Depends on:** LX.12, LX.9.

**Files modified:**

  * `Lex/DSL/Property.lean` — fill in the two
    derived synthesizers.

**Deliverables:**

  * `synth_nonce_advances : Name → SynthResult Lean.Term` — succeeds iff the `signed_by` actor name matches the property's argument (the nonce-advance is structural under `signed_by`, so the synthesizer is a one-line check).
  * `synth_registry_preserving : ImplCalculus → SynthResult Lean.Term` — succeeds iff `impl_calculus` contains no `register_key` / `register_identity` statement.

**Acceptance criteria:**

  * `signed_by sender` + `nonce_advances [sender]` succeeds; with mismatched name (`nonce_advances [other]`) fails L004.
  * Lex law without `register_key` + `registry_preserving` succeeds; with `register_key` fails.

**Test files:** `Lex/Test/DSL/Property.lean` extended
(+6 cases).

#### LX.16 — `proof <P>` override mechanism

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.12.

**Files modified:**

  * `Lex/DSL/Law.lean` — extend the macro to
    capture `proof <P> := by …` clauses into the
    `LawDecl.proof_overrides` field.
  * `Lex/DSL/Property.lean` — extend the
    dispatcher to consult `proof_overrides` before the
    synthesizer; if an override is present, use it
    verbatim.

**Deliverables:**

  * Override-capture: each `proof <P> := by <tac>` clause
    captures `<tac>` as a `Syntax` value (preserving the
    user's source span) into `LawDecl.proof_overrides`.
  * Override-application: when `dispatchSynthesizer` sees
    a `(P, override-syntax)` pair in
    `proof_overrides`, it bypasses the synthesizer and
    splices `override-syntax` into the generated
    instance body.
  * User-defined property names: `proof <P>` for an
    untagged `<P>` fires L020.
  * `proof <P>` redundancy with a synthesizer-discharable
    `<P>` is allowed (the override wins; this is useful
    for laws where the synthesizer is correct but the
    author wants a more efficient proof body).

**Acceptance criteria:**

  * `distributeOthers`-shaped Lex law with `proof
    monotonic := by exact distributeOthers_isMonotonic …`
    elaborates cleanly (the synthesizer would fail on the
    `for`-loop, but the override handles it).
  * `proof KYC_compliant := by …` for a user-defined,
    `@[lex_property]`-tagged `KYC_compliant` elaborates.
  * Source-position fidelity: an error inside the
    override's tactic block points at the user's tactic
    code, not at the macro expansion.

**Test files:** `Lex/Test/DSL/Property.lean` extended
(+10 cases): synthesizer-bypass on each property,
user-defined property handling, source-position fidelity,
override-with-tactic-error rejection.

#### LX.17 — `Lex/Tools/Codegen.lean` Action renderer

**Effort:** L.  **Risk:** yellow (renderer correctness gates M2's wire equivalence).  **Depends on:** LX.4.

**Files (new):**

  * `Lex/Tools/Codegen.lean` — codegen binary skeleton +
    Action renderer.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_codegen`,
    `supportInterpreter := true`.
  * `LegalKernel/Authority/Action.lean` — add the
    `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED`
    fence (no content yet).

**Deliverables:**

  * `LexCodegen.main : List String → IO UInt32` — entry
    point with `--check` flag.
  * `loadCodegenInputs` (reused from `LexCommon`).
  * `renderActionInductive : List LawDecl → String` —
    emits the constructor list inside the fence.
  * `renderCompileTransition : List LawDecl → String` —
    emits the per-constructor `compileTransition` branch.
  * `actionFileFences : System.FilePath → IO (FenceContext)` — locates the fence in the target file.
  * `replaceFence : String → FenceContext → String → String` — replaces fence content; preserves text outside.
  * Initial run: `lake exe lex_codegen` is a no-op on a
    clean checkout (no Lex declarations exist yet);
    `--check` also passes.

**Acceptance criteria:**

  * `lake build Lex.Tools.Codegen` succeeds.
  * `lake exe lex_codegen` runs without error on a
    fresh checkout.
  * `lake exe lex_codegen --check` passes (no
    divergence).
  * The fence position in `Action.lean` is preserved
    across runs (idempotency).
  * Adding a fixture codegen-input file causes the next
    `lex_codegen` run to insert a constructor + branch
    inside the fence.

**Test files:** `Test/Lex/Tools/Codegen.lean` (new) — 10
cases: `loadCodegenInputs` happy path, fence-locator
positive / negative / corrupted-fence, `replaceFence`
text-preservation, action-renderer determinism.

#### LX.18 — `Lex/Tools/Codegen.lean` Encoding renderer

**Effort:** L.  **Risk:** yellow.  **Depends on:** LX.17.

**Files modified:**

  * `Lex/Tools/Codegen.lean` — extend with the encoding
    renderer.
  * `LegalKernel/Encoding/Action.lean` — add the
    fence.

**Deliverables:**

  * `renderActionFieldsBounded : List LawDecl → String` —
    emits the per-constructor `fieldsBounded` predicate
    body.
  * `renderActionEncode : List LawDecl → String` — emits
    the per-constructor `encode` body.
  * `renderActionDecode : List LawDecl → String` — emits
    the per-tag `decode` dispatch.
  * `renderActionRoundtripTheorem : List LawDecl → String`
    — emits the `action_roundtrip` proof's per-arm body.
  * `renderActionInjectivityTheorem : List LawDecl → String`
    — emits the `action_encode_injective` proof's
    per-arm body.
  * Per-parameter encoding: `Nat`, `ActorId`, `ResourceId`,
    `Amount`, `ByteArray`, `LogIndex` all map to existing
    `Encodable` instances; complex types (`Dispute`,
    `Verdict`, `LocalPolicy`) reuse the existing
    `<type>_roundtrip` lemmas.

**Acceptance criteria:**

  * Adding a fixture codegen-input file causes the
    encoding renderer to emit byte-identical content to
    the pre-LX.18 hand-written form for the matching
    constructor (modulo formatting; checked via
    `lex_format` normalisation).
  * Round-trip theorems prove for the fixture
    constructor.

**Test files:** `Test/Lex/Tools/Codegen.lean` extended
(+12 cases): per-renderer output stability, encoding
round-trip on fixture, type-handler coverage.

#### LX.19 — `Lex/Tools/Codegen.lean` Events + SignedAction renderer

**Effort:** L.  **Risk:** yellow.  **Depends on:** LX.17.

**Files modified:**

  * `Lex/Tools/Codegen.lean` — extend with two more
    renderers.
  * `LegalKernel/Events/Extract.lean` — add the fence.
  * `LegalKernel/Authority/SignedAction.lean` — add the
    fence around `applyActionToRegistry` and
    `non_registry_mutating_preserves_registry`.

**Deliverables:**

  * `renderActionEvents : List LawDecl → String` — emits
    the per-constructor `actionEvents` branch from the
    `events` AST in each `LawDecl`.
  * `renderApplyActionToRegistry : List LawDecl → String`
    — emits the per-constructor `applyActionToRegistry`
    dispatch from the `registry_effect` field.
  * `renderNonRegistryMutating : List LawDecl → String` —
    emits the proof that non-mutating laws preserve the
    registry (`rfl`-shaped per arm).
  * The `applyActionToLocalPolicies` extension landed by
    LP.5 is preserved verbatim (Lex does not regenerate
    it; it lives outside the fence).

**Acceptance criteria:**

  * Events renderer emits byte-identical content to the
    pre-LX.19 hand-written form for the fixture
    constructor.
  * `non_registry_mutating_preserves_registry` proves for
    the fixture constructor.

**Test files:** `Test/Lex/Tools/Codegen.lean` extended
(+10 cases): events-renderer output, registry-effect
dispatch (none / replaceKey / registerIdentity / localPolicy
variants), non-mutating proof emission.

#### LX.20 — `Lex/Tools/Codegen.lean` `--check` mode + fence-respecting append

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.17, LX.18, LX.19.

**Files modified:**

  * `Lex/Tools/Codegen.lean` — extend with the `--check`
    flag's diff-and-fail behaviour and the fence-
    respecting append algorithm.

**Deliverables:**

  * `--check` mode: runs the renderers, compares against
    the checked-in target files (byte-level), exits 0
    iff equal, exits 1 with L026 diagnostic and a unified
    diff otherwise.
  * **Fence-respecting append algorithm** — concrete
    rules:
    1. Locate `-- BEGIN LEX-GENERATED (do not edit by hand)` and `-- END LEX-GENERATED`.
    2. If both fences are missing, abort with a fatal
       error directing the user to add the fences.
    3. If only one is present, abort (corrupted fence).
    4. Replace text between the fences (exclusive)
       with the rendered content.
    5. If the rendered content is empty (no Lex
       declarations), leave the fence boundary lines
       in place but the body empty.
    6. Preserve text outside the fences verbatim
       (including trailing newline).
  * Concurrency safety: the binary acquires an
    advisory file lock (`flock` on POSIX,
    `LockFile` on Windows) on each target before
    rewriting; concurrent invocations serialise.
  * `--check` uses no locking (it is a pure read).

**Acceptance criteria:**

  * `lake exe lex_codegen --check` exits 0 on a
    fresh checkout (no Lex declarations).
  * Adding a fixture codegen-input file and running
    `lex_codegen` (without `--check`) appends the
    constructor inside the fence; running `--check`
    passes; manually editing inside the fence and
    running `--check` fails L026.
  * Two concurrent `lex_codegen` invocations on the
    same target serialize via the file lock.

**Test files:** `Test/Lex/Tools/Codegen.lean` extended
(+6 cases): fence-locator on missing-fence /
corrupted-fence / valid-fence inputs, `--check` exit
codes, concurrency stress (two-process simulation).

#### LX.21 — Lakefile + CI integration + example Lex law + M1 acceptance

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.5, LX.11, LX.16, LX.20.

**Files (new):**

  * `Lex/Examples/ExampleLex.lean` — a single Lex law
    `example.example_lex_only_law` that exercises the
    macro's full surface (parameters, all clause types,
    a small `satisfies` list, an `events` block).

**Files modified:**

  * `Lex/IndexRegistry.txt` — append the example law's
    line at index 17 (or higher if PA has merged).
  * `LegalKernel/Authority/Action.lean` — codegen-
    appended constructor + `compileTransition` branch
    inside the fence.
  * `LegalKernel/Encoding/Action.lean` — codegen-
    appended encoding branches inside the fence.
  * `LegalKernel/Events/Extract.lean` — codegen-
    appended event branch inside the fence.
  * `LegalKernel/Authority/SignedAction.lean` — codegen-
    appended `non_registry_mutating` branch inside the
    fence.
  * `.github/workflows/ci.yml` — confirm `lake exe
    lex_lint` and `lake exe lex_codegen --check` are in
    the matrix; add ordering: build → test → audits →
    lex_lint → lex_codegen --check.
  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"knomosis-lex-m1-additive"`.
  * `LegalKernel/Test/Umbrella.lean` — update build-tag
    literal.
  * `CLAUDE.md` — Active Development Status entry
    describing the M1 landing.

**Deliverables:**

  * The example law elaborates cleanly.
  * `lake exe lex_codegen` regenerates the four target
    files with the new branches inside the fence.
  * `lake build` succeeds with the regenerated content.
  * Every existing test still passes byte-for-byte.
  * `lake exe lex_codegen --check` passes (committed
    artefacts match generated).
  * The 27 diagnostics catalogue is reachable
    (`Test/Tools/DiagnosticCoverage.lean` confirms each
    L-code is exercised by at least one test).

**Acceptance criteria (M1 milestone gate):**

  * All seven CI gates pass (build, test, count_sorries,
    tcb_audit, stub_audit, lex_lint, lex_codegen
    --check).
  * The example law's regression `example` (proving its
    `transition_def` matches the synthesizer's output)
    elaborates as `rfl`.
  * `#print axioms` on the example law's instances
    returns the standard three.
  * Documentation updated.

**Test files:** `Test/Laws/ExampleLex.lean` (new) — 12
cases: positive elaboration, instance resolution per
property, signed_by strengthening, end-to-end value-level
acceptance, codegen-input round-trip.


### 19.4 Milestone M2 — Re-express the 17 kernel-built-in laws

M2's nine WUs decompose the §12.2 design-doc migration
into nine independently-bisectable PRs.  Each PR
re-expresses a small group of laws of similar shape; a
synthesizer regression in one PR can be bisected back to
the offending law in seconds rather than across the
entire 17-law batch.  The order is chosen so that the
canonical-mode flip (LX.30) is preceded by every other
re-expression: any law lagging behind would mean the
canonical-mode regenerated `Action.lean` has a missing
constructor, breaking the build.

The dependency invariant within M2: each WU adds Lex
declarations + regression `example`s + regenerated
artefacts (under additive-mode codegen until LX.30).
After every M2 WU lands, every kernel-level theorem
about the affected law continues to prove byte-for-byte;
this is verified by `lake build` + `lake test` succeeding
without modification.

#### LX.22 — Re-express `transfer` (canary law)

**Effort:** M.  **Risk:** yellow (first synthesizer-driven law; baseline for M2's strict-equivalence invariant).  **Depends on:** LX.21.

**Files modified:**

  * `LegalKernel/Laws/Transfer.lean` — replace the
    hand-written `Transition` with a `law transfer …`
    declaration.

**Deliverables:**

  * Lex declaration matching the design-doc §5.2 worked
    example.
  * Regression `example` asserting `legalkernel_transfer_transition r sender receiver amount = LegalKernel.Laws.transfer r sender receiver amount := rfl`.
  * One entry appended to `Lex/Inputs/`.
  * `lake exe lex_codegen` appends the codegen-emitted
    classes inside the fence; the appended encoding /
    events / non-registry-mutating arms must be byte-
    equivalent to the pre-LX.22 hand-written form for
    `transfer`.

**Acceptance criteria:**

  * `lake build` succeeds.
  * `lake test` passes byte-for-byte (test count
    unchanged from M1).
  * `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe lex_codegen --check` all pass.
  * `#print axioms LegalKernel.Laws.transfer` returns
    `[propext, Classical.choice, Quot.sound]`.
  * The byte-equivalence regression test (added in
    `Test/Laws/Transfer.lean`) passes.

**Rollback path:** `git revert` LX.22's commit reinstates
the hand-written form; the build returns to its M1 state.

#### LX.23 — Re-express `mint` and `burn`

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.22.

**Files modified:**

  * `LegalKernel/Laws/Mint.lean` — Lex declaration.
  * `LegalKernel/Laws/Burn.lean` — Lex declaration.

**Deliverables:**

  * Lex declarations following design-doc §5.3 (`mint`)
    and §15.1 (`burn`) worked examples.
  * 2 regression `example`s.
  * 2 codegen-input entries.
  * `mint` exercises the `synth_monotonic` path (succeeds)
    and the `synth_conservative` path (fails by design).
  * `burn` exercises both negative paths (the `proof`
    overrides for negative witnesses are *not* needed —
    the synthesizer correctly fails L004 on these
    properties; the Lex declaration omits the unsupported
    properties from `satisfies`, leaving only `local`,
    `freeze_preserving`, `nonce_advances`,
    `registry_preserving`).

**Acceptance criteria:**  Same as LX.22, plus:

  * The instance `IsMonotonic burn` is correctly *not*
    derivable from the Lex declaration (Lex emits no
    `monotonic` instance because the property is not
    claimed); `inferInstance` fails as expected.

#### LX.24 — Re-express `freezeResource` and `reward`

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.22.

**Files modified:**

  * `LegalKernel/Laws/Freeze.lean` — Lex declaration.
  * `LegalKernel/Laws/Reward.lean` — Lex declaration.

**Deliverables:**

  * Lex declarations following design-doc §15.2
    (`freezeResource`) — uses `freeze_resource r` impl
    primitive — and the analog of §5.3 for `reward`.
  * `freezeResource` exercises `LocalTo {}` (touches no
    balance cell) and `FreezePreserving [*]` (no balance
    change preserves any frozen invariant).
  * `reward` exercises `synth_monotonic` (succeeds) and
    `synth_conservative` (fails by design); the Lex
    declaration omits `conservative` from `satisfies`.
  * 2 codegen-input entries.

**Acceptance criteria:**  Same as LX.22.

#### LX.25 — Re-express `replaceKey` and `registerIdentity`

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.22.

**Files modified:**

  * `LegalKernel/Laws/ReplaceKey.lean` (new file, or
    moved from `Authority/Identity.lean`) — Lex
    declaration.
  * `LegalKernel/Laws/RegisterIdentity.lean` (new) — Lex
    declaration.

**Deliverables:**

  * Lex declarations following design-doc §5.4
    (`replaceKey`).
  * Both laws use the `register_key` impl primitive
    (which routes to the authority-layer `applyActionToRegistry`,
    not to `apply_impl`).
  * `RegistryPreserving` is **not** claimed in
    `satisfies` for either law (correctly so; both
    mutate the registry).
  * The codegen-input's `registry_effect` field is set
    to `"replaceKey"` and `"registerIdentity"`
    respectively.
  * 2 regression `example`s.

**Acceptance criteria:**  Same as LX.22, plus:

  * The codegen pass routes the `registry_effect` field
    through `applyActionToRegistry`, not through the
    `non_registry_mutating_preserves_registry` proof.
  * `apply_admissible_with`'s registry-mutation step
    (`Authority/SignedAction.lean` lines 539+) continues
    to dispatch correctly.

#### LX.26 — Re-express `deposit` and `withdraw`

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.22.

**Files modified:**

  * `LegalKernel/Laws/Deposit.lean` — Lex declaration.
  * `LegalKernel/Laws/Withdraw.lean` — Lex declaration.

**Deliverables:**

  * Lex declarations using `mint`-style impl for
    `deposit` (crediting the recipient's balance) and
    `burn`-style for `withdraw` (debiting the sender's
    balance).
  * `deposit` parameters: `r : ResourceId`, `recipient :
    ActorId`, `amount : Nat`, `depositId : Nat`.
  * `withdraw` parameters: `r : ResourceId`, `sender :
    ActorId`, `amount : Nat`, `recipientL1 : EthAddress`.
  * The 20-byte `EthAddress` parameter on `withdraw`
    requires the encoding generator to use the lossless
    `EthAddress.toBytes` encoding (per the Workstream-C
    audit-2 fix).  This is captured in the codegen-input's
    parameter type system.
  * 2 regression `example`s.

**Acceptance criteria:**  Same as LX.22, plus:

  * The 20-byte `EthAddress` encoding regression test
    in `Test/Encoding/Action.lean` continues to pass
    (the Workstream-C audit-2 hardening is preserved).

#### LX.27 — Re-express `dispute`, `disputeWithdraw`, `verdict`, `rollback`

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.22.

**Files modified:**

  * `LegalKernel/Laws/Dispute.lean` (new or moved from
    `Disputes/LawClassification.lean`) — Lex
    declarations for all four dispute-pipeline laws.

**Deliverables:**

  * Lex declarations following design-doc §15.4
    (`dispute`).  Each is a kernel-level no-op
    (`impl := do freeze_resource 0`); the
    observable effect lives in the dispute pipeline
    modules.
  * 4 regression `example`s.
  * Each declaration's `events` block emits the
    appropriate dispute event (`disputeFiled`,
    `disputeWithdrawn`, `verdictApplied`); for
    `rollback`, no per-action event (the rollback's
    effect is observed via `extractEvents`'s rebuild
    against the rolled-back log).

**Acceptance criteria:**  Same as LX.22, plus:

  * The §15.4 worked example's `events := do` block is
    structurally identical to the regenerated
    `Events/Extract.lean` branch (verified by
    `lex_codegen --check`).

#### LX.28 — Re-express `declareLocalPolicy` and `revokeLocalPolicy`

**Effort:** M.  **Risk:** yellow.  **Depends on:** LX.22.

**Files modified:**

  * `LegalKernel/Laws/LocalPolicy.lean` (new) — Lex
    declarations for both LP-introduced laws.

**Deliverables:**

  * Lex declarations.  Both have kernel-impl identity
    (`freeze_resource 0`) and an authority-layer
    effect (`applyActionToLocalPolicies`-mutating).
  * The codegen-input's `registry_effect` field is
    extended with a `"localPolicy"` variant; LX.19's
    SignedAction renderer routes this to
    `applyActionToLocalPolicies` rather than
    `applyActionToRegistry`.
  * 2 regression `example`s.

**Acceptance criteria:**  Same as LX.22, plus:

  * `applyActionToLocalPolicies` (LP.5's helper) is
    invoked on the new Lex-declared laws; its existing
    behaviour is preserved.
  * The Workstream-LP test suite (66 LP-specific cases)
    continues to pass byte-for-byte.

#### LX.29 — Re-express `distributeOthers` and `proportionalDilute`

**Effort:** L.  **Risk:** yellow (these laws exercise the `proof` override path; the override correctness is the gate).  **Depends on:** LX.22, LX.16.

**Files modified:**

  * `LegalKernel/Laws/DistributeOthers.lean` — Lex
    declaration with `for`-loop impl + `proof monotonic
    := …` override.
  * `LegalKernel/Laws/ProportionalDilute.lean` — same
    shape.

**Deliverables:**

  * Lex declarations following design-doc §15.3
    (`distributeOthers`) — both use `for x in
    affectedActors_at r excluded:` and supply
    `proof monotonic := by exact distributeOthers_isMonotonic …`
    referencing the existing kernel theorem.
  * 2 regression `example`s.
  * The `proof` override mechanism (LX.16) is exercised
    end-to-end: the synthesizer fails on `for`-shaped
    impl, the override fires, and the resulting instance
    is byte-equivalent to the pre-LX.29 hand-written
    form.

**Acceptance criteria:**  Same as LX.22, plus:

  * The `proof monotonic := …` override's source position
    is preserved; an error inside the override's tactic
    block points at the user's tactic code, not at the
    macro expansion.

#### LX.30 — Flip lex_codegen to canonical mode; deprecate Phase-4 Law.mk; M2 acceptance

**Effort:** M.  **Risk:** yellow (the canonical-mode flip is irreversible without `git revert`).  **Depends on:** LX.22 – LX.29 (all preceding M2 WUs).

**Files modified:**

  * `Lex/Tools/Codegen.lean` — flip default to
    `--canonical` (regenerate full file body, no
    fences).
  * `LegalKernel/Authority/Action.lean` — entire body
    now generated; fences removed.
  * `LegalKernel/Encoding/Action.lean` — same.
  * `LegalKernel/Events/Extract.lean` — same.
  * `LegalKernel/Authority/SignedAction.lean` — same
    (for the `applyActionToRegistry` and
    `non_registry_mutating_preserves_registry` portions;
    the rest of the file remains hand-written).
  * `LegalKernel/DSL/Law.lean` (Phase-4 macro) — add
    `@[deprecated "Use Lex's `law` macro instead."]`
    on `Law.mk`.
  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"knomosis-lex-m2-canonical"`.
  * `LegalKernel/Test/Umbrella.lean` — update build-tag
    literal.
  * `CLAUDE.md` — Active Development Status entry.

**Deliverables:**

  * Canonical-mode is now the default.  The four target
    files have no `-- BEGIN LEX-GENERATED` fences;
    their entire body is generated.
  * Phase-4 `Law.mk` continues to compile (the
    deprecation is a warning, not an error).
  * The Phase-4 `transferDSL` example is preserved as
    a regression test for `Law.mk` until v2.
  * Every kernel-level theorem signature is unchanged.

**Acceptance criteria (M2 milestone gate):**

  * All seven CI gates green.
  * Test count unchanged from M1.
  * `#print axioms` on every kernel theorem still
    returns the standard three (or a subset).
  * Diff against pre-M2 main is exactly: removal of
    hand-written cases plus addition of Lex declarations
    plus regenerated artefact files (modulo
    `lex_format` normalisation).
  * The pre-M2 wire encoding is byte-equivalent
    (verified by replaying every test fixture through
    the regenerated codec).
  * `Test/Encoding/Action.lean`'s 12 cases pass byte-
    for-byte.
  * `Test/Authority/Action.lean`'s 31 cases pass
    byte-for-byte.

**Rollback path:** `git revert` reinstates the
hand-written forms.  M1's additive infrastructure
remains useful even if M2 is reverted; the canonical-
mode flip is the only irreversible step.


### 19.5 Milestone M3 — Manifests, governance tooling, property-test auto-generation

#### LX.31 — `Lex/DSL/Deployment.lean` Phase 1: parser + `Deployment` record

**Effort:** L.  **Risk:** green.  **Depends on:** LX.30.

**Files (new):**

  * `Lex/DSL/Deployment.lean` — the
    `deployment` macro skeleton.

**Files modified:**

  * `LegalKernel.lean` — re-export
    `Lex.DSL.Deployment`.

**Deliverables:**

  * Lean `syntax` declarations for the `deployment`
    keyword and every clause keyword (`identifier`,
    `deployment_id`, `version`, `resources`, `laws`,
    `authority`, `invariant_claims`, `attestor`).
  * `parseDeployment : Lean.Syntax → Lean.Elab.Command.CommandElabM (Except Diagnostic DeploymentDecl)` walker.
  * `DeploymentDecl` Lean structure mirroring §16.4's
    `Deployment` record + parsing-time intermediate
    fields (e.g. `manifestSourceBytes` for the eventual
    hash).
  * Diagnostic emission for L018 (32-byte
    `deployment_id`).
  * Phase-1 macro elaboration emits the skeleton `def
    deployment_<name> : Deployment` only; the
    invariant-claim synthesis (LX.33) and manifest-hash
    constant (LX.32) are added by later WUs.

**Acceptance criteria:**

  * `lake build Lex.DSL.Deployment` succeeds.
  * A minimal manifest (one law, no claims, 32-byte
    `deployment_id`) elaborates.
  * L018 fires when `deployment_id` is not 32 bytes.

**Test files:** `Test/DSL/LexDeployment.lean` (new) — 8
cases: minimal-manifest happy path, missing-clause
errors, `deployment_id` length validation.

#### LX.32 — `LexDeployment` Phase 2: elaboration + manifest hash + deployment_id wiring

**Effort:** M.  **Risk:** green.  **Depends on:** LX.31.

**Files modified:**

  * `Lex/DSL/Deployment.lean` — extend the
    macro to emit:
    – `def deployment_<name>_id : ByteArray := <32-byte literal>`
    – `def deployment_<name>_manifest_hash : ByteArray`
    – `def deployment_<name>_admissible : ExtendedState → SignedAction → Prop`

**Deliverables:**

  * Manifest-hash computation: a CBE-encoded canonical
    serialisation of the manifest's parsed AST is hashed
    via `Runtime.Hash.hashBytes`.
  * Determinism: two builds of the same manifest produce
    byte-equal manifest hashes.
  * `deployment_<name>_admissible` is `AdmissibleWith
    Verify <policy> deployment_<name>_id`, parameterised
    on the `<policy>` from the `authority` block (the
    deployment's `AuthorityPolicy` value).

**Acceptance criteria:**

  * The manifest hash is byte-stable across builds.
  * Distinct manifests produce distinct hashes (a
    cross-manifest distinguishability check via test
    fixtures).
  * The generated `deployment_<name>_admissible`
    elaborates and resolves correctly at the runtime-
    adaptor call site.

**Test files:** `Test/DSL/LexDeployment.lean` extended
(+5 cases): manifest-hash determinism, cross-manifest
distinguishability, admissible-predicate wiring.

#### LX.33 — `LexDeployment` Phase 3: `invariant_claims` synthesis

**Effort:** L.  **Risk:** yellow (synthesis correctness gates the manifest's safety properties).  **Depends on:** LX.32, LX.3.

**Files modified:**

  * `Lex/DSL/Deployment.lean` — extend the
    macro with the `invariant_claims` synthesizer.

**Deliverables:**

  * `synth_monotonic_law_set : List Name → Term` — emits
    a `MonotonicLawSet` value referencing each named
    law's `IsMonotonic` instance.
  * `synth_conservative_law_set : List Name → Term` —
    analogous for `ConservativeLawSet`.
  * `synth_freeze_preserving_law_set : List Name → Term`
    — analogous for `FreezePreservingLawSet`.
  * Per-claim instance look-up via `inferInstance`;
    missing instances fail L008 naming the offending
    law.
  * Wildcard `freeze_preserving_law_set [* @ {*}]`
    expansion: at manifest-elaboration time, the
    wildcard resource set is expanded to the manifest's
    `resources` list (per §10.2's wildcard handling
    note).
  * The §16.3 design-doc note about *parameterised laws*
    is honoured: `monotonic_law_set [Transfer, Mint, …]`
    is a *declarative* assertion (every constructor of
    these laws inhabits `IsMonotonic`); the actual
    `MonotonicLawSet` value is constructed on demand at
    the runtime adaptor's call site, not at manifest-
    elaboration time.  The macro therefore emits a
    `MonotonicLawSet` *constructor* rather than a
    `MonotonicLawSet` *value*.

**Acceptance criteria:**

  * The example USD-clearing manifest's `monotonic_law_set
    [Transfer, Mint, Freeze, ReplaceKey]` synthesis
    elaborates.
  * Adding `Burn` to the same `monotonic_law_set` fails
    L008 with the message naming `Burn` and
    `IsMonotonic`.
  * The synthesised `MonotonicLawSet` constructor
    behaves like the existing
    `MonotonicLawSet` shape (verified by API stability
    test).

**Test files:** `Test/DSL/LexDeployment.lean` extended
(+8 cases): per-claim happy paths, L008 rejection paths,
wildcard expansion, parameterised-law handling.

#### LX.34 — `Lex/Tools/Diff.lean` Phase 1: parser + per-clause diff

**Effort:** L.  **Risk:** green.  **Depends on:** LX.30.

**Files (new):**

  * `Lex/Tools/Diff.lean` — semantic-diff binary.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_diff`.

**Deliverables:**

  * `LexDiff.main : List String → IO UInt32` — entry
    point with two git-ref arguments.
  * `LawDiff` record (`identifier`, `versionBump`,
    per-clause-`Option Diff`).
  * `parseLawDeclFromGitRef : String → System.FilePath → IO LawDecl` — uses `git show <ref>:<path>` to fetch the law source at a specific revision.
  * Per-clause structural diff: AST-level comparison of
    `pre_ast`, `impl_calculus`, `events`, `satisfies`,
    `signed_by`, `authorized_by`, `intent`, `version`,
    `action_index`.
  * Output formatting matching design-doc §14.1.

**Acceptance criteria:**

  * `lake exe lex_diff <ref-a> <ref-b>` produces a
    semantic diff in the §14.1 format on representative
    inputs.
  * Reformatting-only changes produce empty output.

**Test files:** `Test/Lex/Tools/Diff.lean` (new) — 8
cases: per-clause diff detection, reformatting
invariance, multi-law batching.

#### LX.35 — `Lex/Tools/Diff.lean` Phase 2: version-bump classifier + refinement-proof check

**Effort:** M.  **Risk:** green.  **Depends on:** LX.34.

**Files modified:**

  * `Lex/Tools/Diff.lean` — extend with classifier and
    refinement check.

**Deliverables:**

  * `classifyVersionBump : LawDiff → VersionBump` —
    deterministic mapping from the diff to one of
    `patch` / `minor` / `major` per §14.2.
  * `checkRefinementProof : LawDecl → IO Bool` — a
    minor-bump-classified law must declare a
    `proof refinement_v<old> := by …` clause; missing
    fires L016.
  * `checkVersionDeclaration : LawDiff → Except Diagnostic Unit` — confirms the declared version bump matches the classifier's; mismatch fires L007.
  * Manifest-level diffing: `DeploymentDiff` record;
    law-set / authority-set / claim-set diff.  A
    deployment's `laws` / `authority` block change
    triggers a major manifest bump.

**Acceptance criteria:**

  * `lake exe lex_diff` correctly classifies all six
    canonical bump scenarios (3 law-level, 3 manifest-
    level).
  * A minor-bump without refinement proof fails L016.
  * A patch-claim with non-proof-only changes fails L007.

**Test files:** `Test/Lex/Tools/Diff.lean` extended (+10
cases): bump classifier on each canonical scenario,
refinement-proof check, manifest-diff path.

#### LX.36 — `Lex/Tools/Format.lean` pretty-printer

**Effort:** M.  **Risk:** green.  **Depends on:** LX.30 (independent of LX.34 / LX.35).

**Files (new):**

  * `Lex/Tools/Format.lean` — pretty-printer binary.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_format`.

**Deliverables:**

  * `LexFormat.main : List String → IO UInt32`.
  * Canonical formatting: clause order per §3.3,
    indentation, blank-line conventions, trailing-
    newline ensure.
  * Comment preservation: comments stay attached to the
    preceding clause; in-clause comments preserved at
    their original position.
  * Empty-events canonicalisation: `events := do pure ()`
    and `events := do nothing` → `events := []`.
  * Idempotency: format-then-format = format.

**Acceptance criteria:**

  * `lake exe lex_format <file>` produces deterministic
    output on representative inputs.
  * Idempotency holds (verified by property test).
  * Comments in original file appear at corresponding
    lines in formatted file.

**Test files:** `Test/Lex/Tools/Format.lean` (new) — 10
cases: clause-order canonicalisation, indentation,
empty-events forms, comment preservation, idempotency.

#### LX.37 — Worked example deployment + amendment workflow walkthrough

**Effort:** M.  **Risk:** green.  **Depends on:** LX.33, LX.35.

**Files (new):**

  * `Deployments/Examples/UsdClearing.lean` — the
    USD-clearing manifest from design-doc §7.2.
  * `docs/lex_amendment_walkthrough.md` — a checked-in
    walkthrough of bumping `legalkernel.transfer` from
    `1.0.0` to `1.1.0` (refinement adding an upper
    bound on `amount`).

**Files modified:**

  * `CLAUDE.md` — Active Development Status update.

**Deliverables:**

  * Example manifest elaborates cleanly.
  * `lex_diff` exercises the minor-bump path on the
    walkthrough's example commit pair.
  * Walkthrough covers each step: author edits, lint
    runs, semantic diff produces, refinement proof
    supplied, PR review proceeds.

**Acceptance criteria:**

  * The walkthrough's example commands produce the
    documented output.
  * The example manifest's `manifest_hash` is recorded
    in the walkthrough document for stability tracking.

**Test files:** `Test/Deployments/UsdClearing.lean`
(new) — 6 cases: manifest elaboration, deployment_id
constancy, manifest_hash determinism,
invariant_claims synthesis, attestor-key-handle
placeholder (v2 reservation).

#### LX.38 — Property-test auto-generation + M3 acceptance

**Effort:** L.  **Risk:** green.  **Depends on:** LX.30, LX.21.

**Files modified:**

  * `Lex/Tools/Codegen.lean` — extend with optional
    property-test auto-generation (gated by a
    `--gen-property-tests` flag).
  * `lakefile.lean` — register
    `Lex/Test/AutoGenProperties.lean` as a
    test-driver suite if it exists.
  * `LegalKernel.lean` — bump `kernelBuildTag` to
    `"knomosis-lex-m3-manifests"`.
  * `LegalKernel/Test/Umbrella.lean` — update build-tag
    literal.
  * `CLAUDE.md` — Active Development Status entry
    describing M3 completion.

**Files (new, auto-generated):**

  * `Lex/Test/AutoGenProperties.lean` — auto-
    generated property tests, one harness call per
    `(law, property)` pair.

**Deliverables:**

  * Auto-generation logic for `conservative` ⇒ random-
    state property test.
  * Auto-generation logic for `monotonic` ⇒ same shape
    with `≥`.
  * Auto-generation logic for `local [{r₁,…}]` ⇒
    pointwise-unchanged-on-other-resources test.
  * Auto-generation logic for `freeze_preserving
    [{r₁,…}]` ⇒ frozen-resource invariant preservation.
  * Skip envelope: each generated test wrapped in
    `if env KNOMOSIS_AUTOGEN_SKIP = "1" then return ()`
    so CI can opt out for fast cycles.
  * `lex_codegen --check` includes the auto-generated
    file in its consistency check.

**Acceptance criteria (M3 milestone gate):**

  * Auto-generated tests compile and run on default
    iteration count.
  * For each kernel-built-in law's claimed properties,
    the auto-generated test passes 100/100 iterations.
  * `lake exe lex_codegen --check` does not flag the
    auto-generated file.
  * All M1 + M2 + M3 acceptance criteria from §24
    satisfied simultaneously.
  * Documentation updated.

**Test files:** the auto-generated suite is itself the
test deliverable.  Plus `Test/Lex/Tools/Codegen.lean`
extended (+4 cases) covering the auto-generation logic
itself.

### 19.6 Module file size estimates

This sub-section gives reviewers concrete LOC estimates
per WU so they can plan review capacity.  Estimates are
*upper bounds*: actual implementations may come in
under.  The estimates are based on the LP / PA work-unit
sizes (analogous-shape codegen + macro infrastructure).

| WU      | Files (new + modified)                                               | Net LOC added (est.) | Effort | Reviewer-hrs (est.) |
|---------|----------------------------------------------------------------------|----------------------|--------|---------------------|
| LX.1    | registry + sidecar dir + `.gitignore` + `lakefile.lean`              | ~50                  | S      | 0.5                 |
| LX.2    | `Conservation.lean` (+typeclasses)                                   | ~120                 | M      | 1.5                 |
| LX.3    | 11 law-module additions (instance bodies)                            | ~400                 | M      | 3.0                 |
| LX.4    | `Lex/Tools/Common.lean` (new)                                         | ~450                 | L      | 4.0                 |
| LX.5    | `Lex/Tools/Lint.lean` (new) + CI                                      | ~250                 | S      | 1.5                 |
| LX.6    | `LexLaw.lean` (new, Phase 1)                                         | ~350                 | L      | 4.0                 |
| LX.7    | `LexLaw.lean` (+pre walker) + `lex_pre` attr                         | ~400                 | L      | 5.0                 |
| LX.8    | `LexLaw.lean` (+impl walker) + `lex_impl` attr                       | ~450                 | L      | 5.0                 |
| LX.9    | `LexLaw.lean` (+shim generation)                                     | ~200                 | M      | 2.5                 |
| LX.10   | `LexLaw.lean` (+events walker) + `lex_event_ctor` attr               | ~300                 | L      | 3.5                 |
| LX.11   | `LexLaw.lean` (+JSON writer)                                         | ~200                 | M      | 2.5                 |
| LX.12   | `LexProperty.lean` (new, skeleton) + `lex_property` attr             | ~250                 | M      | 2.5                 |
| LX.13   | `LexProperty.lean` (+conservative+monotonic synth)                   | ~300                 | L      | 4.0                 |
| LX.14   | `LexProperty.lean` (+local+freeze_preserving synth)                  | ~300                 | L      | 4.0                 |
| LX.15   | `LexProperty.lean` (+nonce_advances+registry_preserving)             | ~120                 | S      | 1.5                 |
| LX.16   | `LexProperty.lean` (+proof override mechanism)                       | ~150                 | M      | 2.0                 |
| LX.17   | `Lex/Tools/Codegen.lean` (new, Action renderer)                       | ~350                 | L      | 4.0                 |
| LX.18   | `LexCodegen.lean` (+Encoding renderer)                               | ~400                 | L      | 5.0                 |
| LX.19   | `LexCodegen.lean` (+Events+SignedAction renderers)                   | ~350                 | L      | 4.0                 |
| LX.20   | `LexCodegen.lean` (+--check + fence)                                 | ~250                 | M      | 3.0                 |
| LX.21   | example law + CI + docs                                              | ~250                 | M      | 3.0                 |
| **M1 total** |                                                                 | **~5990 LOC**        |        | **~65 hrs**         |
| LX.22   | `Laws/Transfer.lean` (Lex re-expression)                             | ~80 (net diff)       | M      | 2.0                 |
| LX.23   | `Laws/Mint.lean` + `Laws/Burn.lean`                                  | ~140 (net diff)      | M      | 2.5                 |
| LX.24   | `Laws/Freeze.lean` + `Laws/Reward.lean`                              | ~140                 | M      | 2.5                 |
| LX.25   | `Laws/ReplaceKey.lean` + `Laws/RegisterIdentity.lean`                | ~140                 | M      | 2.5                 |
| LX.26   | `Laws/Deposit.lean` + `Laws/Withdraw.lean`                           | ~140                 | M      | 2.5                 |
| LX.27   | `Laws/Dispute.lean` (4 ctors)                                        | ~180                 | M      | 3.0                 |
| LX.28   | `Laws/LocalPolicy.lean` (2 ctors)                                    | ~120                 | M      | 2.0                 |
| LX.29   | `Laws/DistributeOthers.lean` + `Laws/ProportionalDilute.lean`        | ~180                 | L      | 3.5                 |
| LX.30   | `lex_codegen --canonical` flip + Phase-4 deprecation                  | ~150                 | M      | 3.0                 |
| **M2 total** |                                                                 | **~1270 LOC**        |        | **~24 hrs**         |
| LX.31   | `LexDeployment.lean` (new, Phase 1)                                  | ~350                 | L      | 4.0                 |
| LX.32   | `LexDeployment.lean` (+hash + admissible)                            | ~200                 | M      | 2.5                 |
| LX.33   | `LexDeployment.lean` (+claim synth)                                  | ~300                 | L      | 4.0                 |
| LX.34   | `Lex/Tools/Diff.lean` (new, parser+diff)                              | ~400                 | L      | 4.0                 |
| LX.35   | `LexDiff.lean` (+classifier + refinement check)                      | ~250                 | M      | 3.0                 |
| LX.36   | `Lex/Tools/Format.lean` (new)                                         | ~350                 | M      | 3.5                 |
| LX.37   | `Deployments/Examples/UsdClearing.lean` + amendment doc              | ~200                 | M      | 2.5                 |
| LX.38   | `LexCodegen.lean` (+property-test gen) + AutoGen.lean                | ~400                 | L      | 4.5                 |
| **M3 total** |                                                                 | **~2450 LOC**        |        | **~28 hrs**         |
| **Workstream LX total** |                                                      | **~9710 LOC**        |        | **~117 hrs**        |

The reviewer-hours estimate aggregates to roughly three
sustained reviewer-weeks of focus time across the
workstream's lifetime; in practice this distributes across
multiple reviewers on multiple PRs.  This is consistent
with the LP / PA workstreams' historical effort curves.

## §20 Test plan

### 20.1 New test suites

The workstream introduces ten new test suites:

  1. `Test.Lex.Tools.Common` — registry parsing, JSON
     schema, source-position threading.  ~14 cases (LX.4).
  2. `Test.Lex.Tools.Lint` — registry-consistency rules,
     diagnostic anchoring.  ~6 cases (LX.5).
  3. `Test.DSL.LexLaw` — macro elaboration, grammar
     enforcement, calculus enforcement, `signed_by` /
     `authorized_by` semantics, events block, codegen-
     input writer idempotency.  ~73 cases (split across
     LX.6, LX.7, LX.8, LX.9, LX.10, LX.11).
  4. `Test.DSL.LexProperty` — synthesizers (positive +
     negative per property), `proof` overrides.
     ~52 cases (split across LX.12, LX.13, LX.14, LX.15,
     LX.16).
  5. `Test.Lex.Tools.Codegen` — codegen renderers (Action,
     Encoding, Events, SignedAction), fence-respecting
     append, `--check` mode, property-test generation.
     ~42 cases (split across LX.17 – LX.20, LX.38).
  6. `Test.Laws.ExampleLex` — the M1 acceptance law's
     properties.  ~12 cases (LX.21).
  7. `Test.DSL.LexDeployment` — manifest elaboration,
     `deployment_id` validation, manifest-hash
     determinism, invariant-claim synthesis.  ~21 cases
     (split across LX.31 – LX.33).
  8. `Test.Lex.Tools.Diff` — per-clause / per-manifest
     semantic diff, version-bump classification,
     refinement-proof obligation.  ~18 cases (split
     across LX.34 – LX.35).
  9. `Test.Lex.Tools.Format` — pretty-printer
     idempotency, clause-order canonicalisation, comment
     preservation.  ~10 cases (LX.36).
  10. `Test.Deployments.UsdClearing` — example-manifest
      end-to-end checks.  ~6 cases (LX.37).

Total new tests: ~254.  Plus per-existing-law
classification-instance tests in the LX.3 extension to
`Test.ConservationTests` (~22 cases: 17 instance-resolution
checks + 5 typeclass-shape sanity checks from LX.2),
plus a fresh diagnostic-coverage audit in
`Test.Tools.DiagnosticCoverage` (~27 cases, one per
L-code, landed alongside LX.21).

The post-LX test count is approximately:

  * Pre-LX: 1228 (post-LP).
  * After LX.1 – LX.21 (M1): 1228 + ~298 = ~1526.
  * After LX.22 – LX.30 (M2): unchanged at ~1526 (M2
    re-expression preserves byte-identity; only
    regression `example`s added, which the existing
    test driver does not count as cases).
  * After LX.31 – LX.38 (M3): ~1526 + ~55 = ~1581.

Plus the auto-generated property suite (LX.38) which can
expand the cumulative test invocation count significantly
per-property × per-law × per-iteration, but is gated
behind `KNOMOSIS_AUTOGEN_SKIP=1` for fast CI cycles.

### 20.2 Property-based tests (Audit-3.9 harness)

The `LegalKernel/Test/Property.lean` harness is reused
for the Lex auto-generation work in LX.38.  Three first-
wave properties go in for the LX.21 acceptance gate
(landing alongside the example Lex law and exercising
the macro pipeline end-to-end):

  * `lex_macro_idempotency_property` — re-elaborating a
    Lex law produces byte-identical codegen-input
    output.
  * `lex_codegen_determinism_property` — running
    `lex_codegen` twice on the same input produces
    byte-identical output.
  * `lex_diff_reformatting_invariance_property` — diff
    of a file against `lex_format <file>` is empty.

Each runs at the default 100-sample iteration count
overrideable via `KNOMOSIS_PROPERTY_ITERATIONS`.

### 20.3 Integration tests (M2 milestone gate)

LX.30's M2 acceptance is gated on a comprehensive
integration test:

  * Round-trip every kernel-built-in `Action` constructor
    through the regenerated codec; assert byte-identical
    output to the pre-M2 form.
  * Walk every kernel-built-in test (`Test.Laws.Transfer`
    etc.) and assert it passes byte-for-byte without
    modification.
  * `#print axioms` on every kernel theorem; assert
    `[propext, Classical.choice, Quot.sound]` (or a
    subset).

Failure of *any* sub-check fails M2.

### 20.4 Smoke tests for the example deployment (M3 milestone gate)

LX.37's M3 acceptance is gated on:

  * `Deployments/Examples/UsdClearing.lean` elaborates.
  * The deployment's `manifest_hash` is byte-stable
    across builds.
  * The `monotonic_law_set` invariant claim's
    `isMonotonic` field is provable from the
    instance bag.
  * `lex_lint`, `lex_codegen --check`, `lex_diff <prev>
    <head>` all pass.

### 20.5 Negative-case coverage

Every diagnostic L-code (L001 – L027) has at least one
test that triggers the diagnostic and asserts:

  * The L-code is in the error message.
  * The source location anchors at the offending node
    (not at the surrounding macro expansion).
  * The exit code is non-zero (for `lex_lint` /
    `lex_codegen`).

Coverage matrix is enforced by a new audit utility:
`Test/Tools/DiagnosticCoverage.lean` walks all
declared L-codes and asserts every one has at least one
test.

## §21 Backwards compatibility

### 21.1 Phase-4 `Law.mk` macro

The Phase-4 macro lives in `LegalKernel/DSL/Law.lean` and
remains compiling throughout LX.  In M2 (LX.30), it is
marked `@[deprecated]` but continues to function.  In a
post-LX v2, it may be removed entirely; until then,
deployments using `Law.mk` directly are not impacted.

The Phase-4 `transferDSL` example in
`LegalKernel/DSL/Law.lean` (lines 154-181) is preserved as
a regression test for `Law.mk` with its full elaboration
(verifying the Phase-4 macro continues to produce a
`Transition` definitionally equal to `Laws.transfer`).

### 21.2 Existing law module structure

In M1, no existing law module is modified beyond the
*additive* typeclass instances landed in LX.2 / LX.3.  No
theorem signature changes.

In M2, the modules under `LegalKernel/Laws/` lose their
hand-written `Transition` definitions in favour of the Lex
declarations, but every theorem signature is preserved
(the Lex-emitted instances have the same type signatures
as the pre-M2 hand-written instances).  Downstream
consumers see no API drift.

### 21.3 On-disk log format

The frozen action indices 0..16 are unchanged.  Pre-M2 logs
decode unchanged under the post-M2 build.  Post-LX example
laws (LX.21 onward) inhabit fresh indices ≥ 17, so they
don't alias any historical log entry.

### 21.4 ABI stability

The CBE encoder for each existing constructor produces
byte-identical output before and after M2.  This is the
M2 strict-equivalence invariant (§2.5) made
mechanically-checkable.

The runtime `knomosis` binary's CLI surface is unchanged; the
same subcommands work, the same input formats are
accepted, the same output is produced.

### 21.5 Build-tag bump

`LegalKernel.lean`'s `kernelBuildTag` constant is bumped:

  * After M1 lands: `"knomosis-lex-m1-additive"`.
  * After M2 lands: `"knomosis-lex-m2-canonical"`.
  * After M3 lands: `"knomosis-lex-m3-manifests"`.

The umbrella build-tag check in `Test/Umbrella.lean` is
updated in lockstep with each milestone's PR.

### 21.6 CLAUDE.md updates

Each milestone's PR updates CLAUDE.md's:

  * "Active development status" section — name LX as
    in-progress / complete.
  * "Source layout" subsection — list the new Lex
    modules, audit binaries, and registry / sidecar
    directory.
  * "Module dependency graph" — extend with the LX
    modules' edges.
  * "Type-level design properties" table — append the
    new typeclasses' headline theorems.


## §22 Risks and open questions

### 22.1 Resolved risks

  * **TCB expansion.**  Resolved: every LX module is
    non-TCB; `tcb_audit` allowlist unchanged.
  * **Axiom expansion.**  Resolved: no new `axiom` or
    `opaque`; every new theorem depends only on the
    standard three Lean built-ins.
  * **Sorry creep.**  Resolved: every Lex-emitted
    instance body is either a fixed direct call to an
    existing lemma (synthesizer) or a user-supplied
    `proof` block (whose source is committed and reviewed
    individually).  No `sorry` in Lex's emission paths.
  * **Macro / codegen coupling.**  Resolved by the
    two-pass pipeline: Pass 1 emits sidecar JSON files;
    Pass 2 reads them and regenerates cross-module
    artefacts.  No global accumulation hook is required.
  * **Action-index collision risk.**  Resolved by the
    registry file's increasing-index discipline +
    `lex_lint` enforcement.  Two laws sharing an index
    fail at the registry-update step before a single
    line of generated code is touched.
  * **Wire-format break risk in M2.**  Resolved by the
    M2 strict-equivalence invariant (§2.5) backed by
    regression `example`s in every Lex re-expressed
    law.  A byte-level divergence fails the build.
  * **Synthesizer correctness risk.**  Mitigated by:
    (a) generating the same instance shapes the
    pre-M2 hand-written instances had; (b) regression
    `example`s asserting byte-level transition equality;
    (c) the kernel-level theorems
    (`transfer_conserves` etc.) being unchanged — the
    synthesizer just reuses them.  A synthesizer bug
    that changed the *Prop-level conclusion* of an
    instance would fail compilation; one that produced
    a *different proof body* would still elaborate so
    long as the body's term-level type matches.
  * **Diagnostic-translation accuracy.**  Mitigated by
    threading `sourcePos` through every walker and
    emitter.  A mis-anchored diagnostic is a usability
    regression, not a correctness issue; tests in
    `Test.DSL.LexLaw` confirm anchoring on representative
    inputs.

### 22.2 Open questions / design-document open questions

The design document's §14 lists nine open questions; this
plan defers each to a follow-up workstream:

  1. **Refinement direction for `pre`** (design §14.1).
     V1 ships *strengthening* (new `pre` implies old);
     v2 may admit *weakening* under explicit author
     opt-in.  Tracked in the design doc's §14.1.

  2. **In-flight signed actions across amendments**
     (design §14.2).  V1 leaves the policy unspecified
     — deployments choose to reject in-flight or queue
     for replay.  Tracked.

  3. **Cross-law invariant synthesis** (design §14.3).
     V1's `invariant_claims` block supports only per-
     law-set claims (`monotonic_law_set [L₁,…,Lₙ]`).
     Cross-law claims like "no two laws grant the same
     actor minting authority" are deferred.

  4. **Compositional property dispatch over fold-of-
     flow** (design §14.4).  V1 falls back to `proof`
     overrides for `distributeOthers` /
     `proportionalDilute`.  V2 may extend the
     synthesizer.

  5. **Property-test seed reproducibility** (design
     §14.5).  V1 uses `KNOMOSIS_PROPERTY_SEED` env var
     plus embedded literal in the auto-generated test
     file; full reproducibility deferred.

  6. **Deployment-ID derivation** (design §14.6).  V1
     ships literal 32-byte deployment IDs only; v2
     considers a derivation sub-language.

  7. **Role types vs role values** (design §14.7).
     Deferred to v3 entirely.

  8. **`@[lex_pre]` decidability auditing** (design
     §14.8).  V1 ships a best-effort attribute-attach-
     time check; v2 may require the attribute to
     synthesise a `Decidable` for representative inputs
     (the v1 implementation is the answer to the open
     question, with the strengthening deferred).

  9. **Signer-identity strengthening lift to the kernel**
     (design §14.9).  V1 ships shim-layer; v2 considers
     kernel-level lift.

### 22.3 Implementation-specific risks

  * **Lean macro performance.**  Each `law` declaration
    runs the per-file macro, which writes a JSON file.
    For deployments with hundreds of laws, the
    cumulative I/O cost might be noticeable.  Mitigation:
    the macro skips unchanged-content writes (§6.5
    idempotency).
  * **Large `events` block elaboration time.**  An
    `events` block with many `for x in <large-list>:` /
    `if <complex-pred>:` statements may compile slowly.
    Mitigation: the compiler is the same Lean compiler
    that already handles complex `events` blocks for
    `distributeOthers`; no new performance regression
    expected.
  * **Codegen-input file growth.**  Each Lex law adds a
    JSON file to `Lex/Inputs/`.  At 50+ laws
    the directory's read-all step is non-trivial.
    Mitigation: use Lean's parallel file IO when reading
    the directory; cache parsed inputs across runs (a
    follow-up optimization).
  * **Cross-platform path handling.**  `IO.FS.writeFile`
    on Windows uses `\`-separated paths.  Mitigation: use
    `System.FilePath` join operators consistently; never
    embed literal `/` in path strings.
  * **Diagnostic-translation edge cases.**  Macro-
    expansion-induced source positions may point inside
    a generated `def` rather than at the user's surface
    syntax.  Mitigation: thread `sourcePos` through every
    intermediate AST; on macro-expansion error, walk up
    the expansion tree to find the nearest source-mapped
    parent (per §18.2 fallback rule).
  * **Re-export discipline.**  Adding new `LegalKernel.
    DSL.*` modules requires updating `LegalKernel.lean`'s
    re-export block.  Mitigation: each LX work unit
    explicitly lists this as a "files modified" entry.
  * **`@[lex_pre]` / `@[lex_impl]` attribute hygiene.**
    Tagging an arbitrary Lean function with `@[lex_pre]`
    bypasses the grammar enforcer's normal checks.
    Mitigation: the attribute attach-time handler
    performs decidability synthesis; CI's
    `lex_lint` walks the tagged set and confirms
    decidability is provable for each.
  * **CI gate ordering.**  `lake exe lex_codegen --check`
    requires `lake build` to have run first (since the
    codegen-input files are written by Pass 1).  This is
    handled by the CI matrix declaring `lex_codegen
    --check` as depending on `lake build`'s
    success.  Mitigation: documented in `.github/
    workflows/ci.yml`.
  * **`CompiledAction` wrapper interaction.**  The Lex-
    emitted constructors must compose correctly with the
    existing `CompiledAction.source` projection; an
    incorrect ordering would break `Action.compile_
    injective`'s one-line proof.  Mitigation: regression
    `example` for `Action.compile_injective` ensures
    structural injectivity holds across the regeneration.

### 22.4 Known limitations

  * **No deployment-private `Action` extension** until v3
    (per §1.2).  Every Lex law must register in the
    global `Action` inductive at a frozen index ≥ 17.
  * **No registry-mutating laws beyond `replaceKey` /
    `registerIdentity`** until v3 (per §1.2).  The
    `register_key` primitive only supports the existing
    two effect kinds.
  * **No `revoke_key` primitive** until the kernel ships
    `Action.revokeKey` (per §1.2).
  * **No LSP integration** until v3 (per §1.2).
  * **Auto-generated property tests are opt-in** in v1
    (gated by `KNOMOSIS_AUTOGEN_SKIP`); default-on in v2.
  * **Manifest signing requires v2's attestor flow.**  V1
    manifests are checked-in source files whose identity
    is the source bytes.

## §23 Mathematical soundness statement

This section pins the proof-correctness claims the LX
workstream commits to.  Each statement is backed by either
a Lean theorem or a value-level test; none rely on
unverified machinery.

### 23.1 Soundness of the synthesizer library

For every Lex law `foo` with a `satisfies := [P]` claim
discharged by the synthesizer:

  * **Soundness.**  The synthesizer-emitted `instance foo_<P>
    : <P-typeclass> foo_transition` is a Lean instance whose
    body discharges the typeclass's stated proof obligation
    using only existing kernel-level theorems
    (`transfer_conserves`, `transfer_does_not_touch_other_resources`,
    etc.).  No new axioms; no `sorry`; the theorem's
    `#print axioms` returns a subset of `{propext, Classical.
    choice, Quot.sound}`.

  * **Completeness (deliberately partial).**  The
    synthesizer succeeds on a *fixed structural subset* of
    the `impl` calculus (per §10.4's dispatch table).  Laws
    outside the subset require `proof` overrides.  The
    deliberate-conservatism principle (design-doc §6.4.4)
    is the reason: predictability over cleverness.

  * **Determinism.**  Two synthesizer invocations on the
    same `(satisfies-item, impl_calculus)` pair produce
    byte-identical Lean expression terms.  Verified by
    regression test: a re-run of `lex_codegen` produces
    byte-identical output.

### 23.2 Soundness of the per-file macro

For every Lex law `foo`:

  * **`foo_transition`'s `pre` is decidable.**  The
    grammar enforcer (§7) restricts `pre` to a shape such
    that `inferInstance` discharges `[DecidablePred pre]`.
    Lean's instance synthesizer is the witness; the grammar
    is the structural guarantee.

  * **`foo_transition`'s `apply_impl` is total.**  The
    `impl` calculus's primitives (`flow`, `mint`, `burn`,
    `reward`, `freeze_resource`, `register_key`) are total
    functions in `State → State` (or `KeyRegistry →
    KeyRegistry`); composition of total functions is
    total.  This is a *structural* property of the
    calculus; no proof obligation arises.

  * **`foo_transition`'s `apply_impl` is deterministic.**
    The `impl` calculus admits no `IO`, `Task`, or
    `Random.State` primitives.  Determinism is a structural
    property of the admitted node set.

  * **The codegen-input file's content equals the
    elaborated `LawDecl` value's canonical JSON
    serialisation.**  Two macro invocations on equal
    surface syntax produce equal codegen-input bytes.
    Verified by Audit-3.9 property test
    `lex_macro_idempotency_property`.

### 23.3 Soundness of `lex_codegen`

For every codegen-input set `I`:

  * **Determinism.**  `lex_codegen I` produces byte-
    identical output across runs (no timestamps, no
    randomness, no environment dependence beyond the
    explicit input set).  Verified by Audit-3.9 property
    test `lex_codegen_determinism_property`.

  * **Idempotency.**  Running `lex_codegen I` twice
    produces no second-run changes.  Implied by
    determinism plus check-mode equality.

  * **`--check` mode soundness.**  `lex_codegen I --check`
    exits 0 iff the checked-in target files equal
    `lex_codegen I`'s output.  Failure exits non-zero
    with diagnostic L026.

  * **Generated artefacts compile.**  `lake build` over
    the regenerated `LegalKernel/Authority/Action.lean`
    etc. succeeds.  Verified by CI: `lake exe lex_codegen
    --check` is followed in the CI matrix by `lake
    build`, and the latter must succeed.

### 23.4 Soundness of M2's strict-equivalence invariant

For every kernel-built-in law `L` re-expressed in Lex:

  * **`L_transition` is `rfl`-equal to the pre-M2
    hand-written form.**  Proved as a `rfl` regression
    `example` in `LegalKernel/Laws/<L>.lean`.

  * **`Action.<L>`'s wire encoding is byte-identical to
    pre-M2.**  Verified by regression test in
    `Test/Encoding/Action.lean`.

  * **Every kernel-level theorem about `L`
    (`L_conserves`, `L_does_not_touch_other_resources`,
    etc.) has an unchanged signature and proves
    successfully under the regenerated `Action.lean`.**
    Verified by `lake build` + `lake test` succeeding.

### 23.5 Soundness of `signed_by` strengthening

For every Lex law with `signed_by sender`:

  * **The generated shim's `h_signer : st.signer = sender`
    hypothesis is Decidable.**  Via `DecidableEq ActorId`
    (a `Nat`-wrapped abbrev).
  * **The shim's body returns the same `ExtendedState` as
    `apply_admissible_with` does (modulo the additional
    hypothesis).**  Verified at the value level.
  * **The deployment's `AuthorityPolicy` *must* imply
    `st.signer = sender`** for the shim to be invocable.
    This is a deployment-side proof obligation; Lex
    surfaces it explicitly via the shim's parameter list.

### 23.6 Soundness of the new typeclasses

For each new typeclass (`LocalTo`, `FreezePreserving`,
`RegistryPreserving`):

  * **The class is a `Prop`-valued single-field record.**
    Resolves via Lean's standard typeclass resolution.

  * **Per-existing-law instances depend only on existing
    kernel theorems.**  No new theorem infrastructure
    required.

  * **`#print axioms`** on each instance returns a subset
    of `{propext, Classical.choice, Quot.sound}`.

  * **`FreezePreservingLawSet` is structurally compatible
    with the existing `MonotonicLawSet` /
    `ConservativeLawSet`** (same `laws : List Transition`
    field; analogous `isFreezePreserving` field).  The
    `freeze_preservation_via_law_set` corollary mirrors the
    existing `total_supply_global_via_law_set` / `total_
    supply_globally_nondecreasing_via_law_set`.

### 23.7 Boundary case: laws with the bare-term escape hatch

V1 admits a bare-term escape hatch in `impl`.  Such laws:

  * Cannot have `conservative` / `monotonic` /
    `local [{…}]` / `freeze_preserving [{…}]` claims
    discharged by the synthesizer (the synthesizer
    cannot inspect arbitrary `State → State` functions).
  * Must supply `proof <P> := by …` overrides for any
    such claim.
  * Each override's tactic block is committed and
    reviewed individually.  This is no different from the
    current Phase-4 status quo where laws are entirely
    hand-written.

V2 removes the escape hatch entirely; until then, the
soundness chain has the override as its weakest link.  The
project's existing review discipline (CLAUDE.md's
two-reviewer rule for kernel-touching changes; one
reviewer for laws / tests) applies to every override.

### 23.8 Replay protection unchanged

LX adds no new `Action` constructor, mutates no existing
constructor's wire encoding, and changes no `Admissible`
conjunct.  The existing `replay_impossible` and
`nonce_uniqueness` theorems
(`LegalKernel/Authority/SignedAction.lean`) re-elaborate
verbatim across every milestone of the workstream.
Replay protection is a structural invariant of the
unchanged kernel, unaffected by Lex's surface-level
transformations.

### 23.9 Composition with LP and PA

LX adds no admissibility conjunct; the post-LX
admissibility predicate is **byte-identical** to the
post-LP (or post-LP-post-PA, if PA has merged) form.

This means:

  * The `admissible_no_local_no_caps_no_param_action_iff_pre_LP_PA`
    theorem (PA's strict-narrowing characterisation) holds
    verbatim post-LX.
  * The LP+PA composition `admissible_lp_pa_compose`
    theorem (PA's §7.5) holds verbatim post-LX.
  * Deployments using LP / PA combine seamlessly with Lex
    declarations: a Lex law's `pre` clause may reference
    `LocalPolicy.permits` and `Parameters.maxTransferAmount`
    via `@[lex_pre]`-tagged helpers; the elaborator
    threads them through the §6.1 grammar.


## §24 Acceptance criteria

The LX workstream is complete when, on the head commit of
the landing branch, all of the following hold.  The
criteria are partitioned into M1 / M2 / M3 milestones; each
milestone ships in a separable PR with its own gating
subset.

### 24.1 M1 acceptance (LX.1 – LX.21)

  1. **Build green.**  `lake build` succeeds on a clean
     checkout.
  2. **Tests green.**  `lake test` reports zero failures
     across every registered suite (existing + new).
  3. **No sorries.**  `lake exe count_sorries` returns 0.
  4. **TCB audit passes.**  `lake exe tcb_audit` reports
     zero allowlist violations.
  5. **Stub audit passes.**  `lake exe stub_audit` reports
     zero placeholder bodies in non-allowlisted positions.
  6. **Lex lint passes.**  `lake exe lex_lint` reports
     zero violations across `LegalKernel/Laws/` and
     `Deployments/`.
  7. **Lex codegen check passes.**  `lake exe lex_codegen
     --check` reports no divergence between checked-in
     and generated artefacts.
  8. **Axiom audit passes.**  Every theorem introduced
     by M1 depends only on a subset of `{propext,
     Classical.choice, Quot.sound}`.
  9. **The 27 diagnostics are all reachable.**
     `Test/Tools/DiagnosticCoverage.lean` confirms each
     L-code is exercised by at least one test.
  10. **The example Lex-only law elaborates.**
      `Lex/Examples/ExampleLex.lean`'s declaration
      compiles, its classification instances resolve, and
      its end-to-end test passes.
  11. **Phase-4 `Law.mk` continues to function** (not yet
      deprecated in M1).
  12. **Documentation updated.**  CLAUDE.md's "Active
      development status" names M1 as complete; the
      source-layout listing reflects the new modules; the
      type-level properties table gains LX entries; the
      `kernelBuildTag` literal is bumped to
      `"knomosis-lex-m1-additive"`.

### 24.2 M2 acceptance (LX.22 – LX.30)

In addition to all M1 criteria:

  13. **The 17 kernel-built-in laws are all expressed in
      Lex.**  Each `LegalKernel/Laws/<L>.lean` is a Lex
      declaration; the hand-written `Transition` is
      removed.
  14. **M2 strict-equivalence invariant holds.**  For
      every kernel-built-in law:
      – `L_transition` is `rfl`-equal to the pre-M2
        form (verified by regression `example`).
      – `Action.<L>`'s wire encoding is byte-identical
        to pre-M2 (verified by test vector).
      – Every existing `Test.Laws.<L>` test passes
        byte-for-byte.
  15. **Cross-module artefacts regenerated.**
      `LegalKernel/Authority/Action.lean`,
      `LegalKernel/Encoding/Action.lean`,
      `LegalKernel/Events/Extract.lean`, and
      `LegalKernel/Authority/SignedAction.lean` are now
      lex-codegen-managed (the
      `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED`
      fences span the entire managed sections; in
      canonical mode, the entire body is regenerated).
  16. **Phase-4 `Law.mk` is deprecated.**
      `LegalKernel/DSL/Law.lean`'s `Law.mk` carries
      `@[deprecated "Use Lex's `law` macro instead."]`.
      The Phase-4 `transferDSL` example still compiles
      (deprecation is a warning, not an error).
  17. **`#print axioms` unchanged.**  Every kernel
      theorem still depends on a subset of `{propext,
      Classical.choice, Quot.sound}`.
  18. **Test count unchanged.**  M2 introduces no new
      tests beyond regression `example`s; the Tests.lean
      driver count is unchanged from M1.
  19. **Documentation updated.**  CLAUDE.md's "Active
      development status" names M2 as complete; the
      `kernelBuildTag` literal is bumped to
      `"knomosis-lex-m2-canonical"`.

### 24.3 M3 acceptance (LX.31 – LX.38)

In addition to all M1 + M2 criteria:

  20. **Manifest macro lands.**
      `Lex/DSL/Deployment.lean` exports the
      `deployment` macro; example manifest elaborates
      cleanly.
  21. **Worked example deployment ships.**
      `Deployments/Examples/UsdClearing.lean` elaborates;
      its `manifest_hash` is byte-stable; its
      `monotonic_law_set` invariant claim's
      `isMonotonic` field is provable from the instance
      bag.
  22. **`lex_diff` and `lex_format` ship.**  Both audit
      binaries build and pass their respective test
      suites.
  23. **Property-test auto-generation skeleton ships.**
      `Lex/Tools/Codegen.lean` can emit
      `Lex/Test/AutoGenProperties.lean`; the
      generated tests pass when run.
  24. **Amendment workflow walkthrough documented.**
      `docs/lex_amendment_walkthrough.md` is checked in
      and renders correctly.
  25. **Documentation updated.**  CLAUDE.md's "Active
      development status" names M3 as complete; the
      `kernelBuildTag` literal is bumped to
      `"knomosis-lex-m3-manifests"`.

### 24.4 Workstream-wide gate

The workstream is **not** complete (and the M3 PR is not
landable) until every gate above passes simultaneously.
Partial completion is documented as in-progress and
committed only with the `work-in-progress` PR label.

If a milestone lands in a separate PR (M1 → M2 → M3 as
distinct PRs), each PR's acceptance criteria need only
include its own milestone's items plus the prior
milestones'; the workstream-completion gate is at the M3
PR's merge commit.

If a serious problem is discovered post-M2, the rollback
path is to revert the M2 PR and continue maintaining
hand-written code under the M1 additive surface.  M1 and
M3 are independent of M2 in the sense that:

  * M1 is useful even without M2 (operators can opt in to
    Lex per-law without the kernel-built-ins migrating).
  * M3 (the manifest layer) is useful with or without M2
    (a manifest can reference both Lex declarations and
    pre-Lex hand-written laws via the `laws` block,
    treating them uniformly).

This decoupling is the project's safety net.

## Cross-references

  * **Design document.**  `docs/law_language_design.md` is
    the canonical specification for the Lex surface.  This
    plan implements that document; divergences are
    resolved in the design document's favour pending the
    plan's completion.

  * **Phase-4 DSL macro.**  `LegalKernel/DSL/Law.lean`
    (WU 4.9) is the existing primitive Lex extends and
    eventually deprecates.  See §21.1.

  * **Workstream LP.**  `docs/planning/actor_scoped_policies_plan.md`
    introduces per-actor `LocalPolicy` filters at the
    admissibility layer.  LX does not interact with LP at
    the type level; both compose via the existing
    `AdmissibleWith` predicate.  See §23.9.

  * **Workstream PA.**  `docs/planning/parameterized_laws_plan.md`
    introduces deployment-wide vote-mutable parameters.
    LX does not interact with PA either; both compose at
    the admissibility layer without coupling.  See §23.9.

  * **Audit-3.2 (Attested Snapshots).**
    `LegalKernel/Runtime/AttestedSnapshot.lean` is the
    pattern Lex's v2 manifest signing reuses.  V1
    manifests rely on source-byte identity.

  * **Audit-3.3/3.4 (Cross-Deployment Replay
    Protection).**  `LegalKernel/Authority/SignedAction.
    lean`'s `signingInput` is the integration point for
    Lex's `deployment_id`.  See §16.5.

  * **Audit-3.9 (Property-Based Testing Harness).**
    `LegalKernel/Test/Property.lean` is reused for LX.38's
    auto-generation.  See §20.2.

  * **Genesis Plan §13.6 (TCB Amendment Process).**  No
    LX work unit triggers the §13.6 two-reviewer gate
    (every change is non-TCB).

  * **`docs/decidability_discipline.md` (WU 1.6).**  The
    decidability rule §7.2's grammar enforces by
    construction.

  * **`docs/economic_invariants.md`.**  The firewall
    semantics §16.3's `MonotonicLawSet` synthesis
    preserves.

  * **`docs/abi.md`.**  The on-disk format the
    action-index commitments surface in.  LX preserves
    the format byte-for-byte.

## Appendix A — Surface ↔ generated mapping cheat sheet

The following table shows what each Lex clause emits.
This is a quick-reference for reviewers walking a
generated diff after `lex_codegen` has run.

| Lex clause              | Pass-1 output (per-file)                                                | Pass-2 output (codegen)                                                                       |
|-------------------------|-------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `identifier`            | `def myLaw_identifier : String := "..."`                                | (key in the codegen-input file; consulted by registry checker)                                |
| `version`               | `def myLaw_version : String := "..."`                                   | (key)                                                                                         |
| `action_index`          | (consulted by registry consistency check; `def myLaw_action_index : Nat := <N>`) | the constructor's tag in `Action.encode`                                              |
| `intent`                | `Lean docstring on myLaw_transition`                                    | (preserved as docstring on the `Action` constructor in the regenerated file)                  |
| `signed_by sender`      | (consulted by `synth_nonce_advances`; recorded in shim parameter list)  | the `nonces := advanceNonce …` line in `compileTransition`                                    |
| `authorized_by P`       | (string-captured into the shim's hypothesis bundle)                     | (consulted by manifest's `authority` block)                                                    |
| `pre := <expr>`         | `def myLaw_pre : State → Prop := <expr>`                                | (consumed by the synthesizers; recorded in `pre_ast` for downstream tooling)                  |
| `impl := do <stmts>`    | `def myLaw_apply_impl : State → State := <desugared>`                   | the `compileTransition` branch's `apply_impl`                                                  |
| `satisfies := [...]`    | one `instance` per item, dispatched through synthesizers                | (consumed by manifest's `invariant_claims` synthesis)                                         |
| `events := do <stmts>`  | (recorded in `events` for codegen)                                      | the `actionEvents` branch in `Events/Extract.lean`                                             |
| `proof <P> := <tactic>` | (recorded in `proof_overrides`; replaces synthesizer body for `P`)      | (no codegen output; the override is in the per-file emission)                                  |

## Appendix B — Decidability discipline reminders

`docs/decidability_discipline.md` (WU 1.6) is the
authoritative source for the `decPre := fun _ =>
inferInstance` rule.  Lex enforces this rule by:

  1. Restricting `pre` to a §7.2 grammar that Lean's
     instance synthesizer is guaranteed to discharge.
  2. Tagging user-defined predicates with `@[lex_pre]` and
     verifying decidability at attribute-attach time.
  3. Catching residual failures with diagnostic L003
     anchored at the offending sub-expression's source
     location.

Authors who need a non-instance-decidable predicate
must:

  1. Drop the surface-level Lex `law` declaration.
  2. Hand-write the `Transition` directly (the Phase-4
     `Law.mk` form, or pre-Phase-4 manual `Transition.mk`).
  3. Hand-write the seven supporting branches (this is
     the status quo for the kernel-built-in laws today;
     it remains valid for v1).

This escape valve preserves the design document's
"deliberately conservative" principle (§6.4.4): Lex
prioritises ergonomic precision over expressive
completeness; authors who need completeness drop down to
the kernel-level surface.

## Appendix C — Glossary

  * **AST** — abstract syntax tree.  The internal Lean
    representation of a law's parsed clauses.
  * **CBE** — Knomosis Binary Encoding.  The strictly-
    canonical fixed-width binary form Knomosis uses for
    on-wire serialisation, deviating from RFC 8949
    canonical CBOR for proof tractability (Phase 4).
  * **Codegen-input file** — `Lex/Inputs/
    <identifier>.json` capturing a Lex law's metadata for
    consumption by `lex_codegen`.
  * **Diagnostic translation layer** — the macro-pass
    component that anchors error messages at the user's
    surface-syntax position rather than at the macro-
    expansion point.
  * **Frozen index** — an `action_index` value that, once
    committed to a tagged release, can never change.
  * **`@[lex_pre]`** — the attribute tagging a user-
    defined predicate as admissible inside a `pre`
    clause.
  * **`@[lex_impl]`** — the attribute tagging a user-
    defined helper as admissible inside an `impl` clause.
  * **`@[lex_property]`** — the attribute tagging a
    user-defined property name as admissible inside a
    `satisfies` clause.
  * **Manifest** — a `deployment <name>` declaration
    binding a law set, an authority configuration, a
    deployment ID, and an `invariant_claims` block.
  * **Pass 1** — the per-file Lean macro elaboration that
    runs at `lake build` time and emits the codegen-
    input file plus instance declarations.
  * **Pass 2** — the build-time `lex_codegen` invocation
    that reads all codegen-input files and regenerates
    cross-module artefacts.
  * **Property synthesizer** — a function in
    `Lex/DSL/Property.lean` that takes a
    parsed `impl` calculus and a property name, and
    emits a Lean `instance` body discharging the
    property.
  * **Registry** — `Lex/IndexRegistry.txt`, the
    project-wide source of truth for action-index
    assignments.
  * **Strict-equivalence invariant** — M2's gating
    property that every kernel-built-in law re-expressed
    in Lex produces a `Transition` `def` `rfl`-equal to
    the pre-M2 hand-written form.
  * **Synthesizer** — see "property synthesizer".

## Appendix D — Worked Lex law (full template)

```lean
/-! Worked example for §15.5 of the design document, included
    here as an authoring template for new deployment-private
    laws. -/

import Lex.DSL.Law
import Lex.DSL.Property
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer

namespace MyDeployment

open LegalKernel
open LegalKernel.DSL

/-- The deployment's escrow actor.  Reserved at deploy time. -/
def escrowActor : ActorId := 42

law staking_lock
    (r : ResourceId) (staker : ActorId) (amount : Nat)
    (unlockHeight : Nat)
where
  identifier   my_deployment.staking_lock
  version      "1.0.0"
  action_index 17                 -- whatever's next-free post-LP / post-PA

  intent {
    Lock `amount` units of `r` belonging to `staker` for use as
    voting weight or anti-fraud collateral.  The locked amount
    moves into a deployment-managed escrow account
    (`MyDeployment.escrowActor`).  The `unlockHeight` is recorded
    for off-chain consumption; the kernel does not interpret it.
  }

  signed_by      staker
  authorized_by  MyDeployment.staking_policy staker r

  pre := fun s =>
    amount > 0
    ∧ getBalance s r staker ≥ amount

  impl := do
    flow r amount from staker to MyDeployment.escrowActor

  satisfies := [
    conservative,
    monotonic,
    local             [{r}],
    freeze_preserving [{r}],
    nonce_advances    [staker],
    registry_preserving
  ]

  events := do
    let pre_staker := getBalance preState r staker
    let pre_escrow := getBalance preState r MyDeployment.escrowActor
    if amount > 0 then
      emit balanceChanged r staker
        pre_staker (pre_staker - amount)
    if amount > 0 then
      emit balanceChanged r MyDeployment.escrowActor
        pre_escrow (pre_escrow + amount)
    emit stakingLocked staker amount unlockHeight   -- user-defined event

end MyDeployment
```

This template demonstrates every clause type the v1 surface
admits.  Authors should copy it as a starting point and
modify per their law's specific behaviour.  CI's
`lex_lint` will guide them through any clause-validation
errors; `lex_codegen --check` will confirm the cross-module
artefacts are up-to-date.

---

**Document version:** v1, drafted on branch
`claude/lex-implementation-planning-ZzOSx`.  Subsequent
edits track real implementation decisions and are reflected
in the in-tree changelog (CLAUDE.md "Active development
status").  This file is informational; the canonical
specification is `docs/law_language_design.md`, and the
canonical specification of the kernel surface Lex compiles
into is `docs/GENESIS_PLAN.md`.


---

## Appendix E — Audit-1 changelog

This section records the corrections applied during the
v1 plan's first deep audit (the audit-1 pass), so
follow-up readers can distinguish the audited (current)
form from the pre-audit form.  Per the project's "Names
describe content, never provenance" rule (CLAUDE.md), the
changes themselves carry no provenance markers in
declaration names; this changelog is the authoritative
provenance record.

The audit-1 pass was performed against the post-LP
state of the codebase.  It validated every codebase
reference, every Lean-mechanism claim, and every
typeclass formulation against the actually-shipped
sources.  Three substantive defects were found and
fixed; several smaller cross-reference and naming
inconsistencies were resolved at the same time.

### E.1 Substantive defects found and corrected

#### E.1.1 `RegistryPreserving` indexed on `Transition` instead of `Action` (mathematical-correctness defect)

**Pre-audit form:**

```lean
class RegistryPreserving (t : Transition) : Prop where
  registry_preserves :
    ∀ (oldRegistry : KeyRegistry) (action : Action),
      Action.compileTransition action = t →
      applyActionToRegistry action oldRegistry = oldRegistry
```

**Post-audit form (§10.2):**

```lean
class RegistryPreserving (a : Action) : Prop where
  preserves : ∀ (kr : KeyRegistry), applyActionToRegistry kr a = kr
```

**Why the pre-audit form was broken.**  `applyActionToRegistry`
dispatches on `Action`, not on `Transition`.  Multiple `Action`
constructors compile to definitionally-equal `Transition`
values: `replaceKey`, `dispute`, `disputeWithdraw`, `verdict`,
`rollback`, `registerIdentity`, `declareLocalPolicy`,
`revokeLocalPolicy`, and `freezeResource r` (for any `r`)
all compile to `Laws.freezeResource _` (the `freezeResource`
law's body ignores its `r` parameter, per CLAUDE.md "type-
level design properties").  Among these, `replaceKey` and
`registerIdentity` mutate the registry, while the others do
not.  The pre-audit `RegistryPreserving` typeclass on
`Transition` would therefore require a single Prop value
to be simultaneously true (for `dispute` etc.) and false
(for `replaceKey`) — a contradiction.

**Why the post-audit form is correct.**  The typeclass is
now indexed by `Action`, so each constructor's `applyActionToRegistry`
arm is independently classified.  `RegistryPreserving (.transfer
…)` reduces to `applyActionToRegistry kr (.transfer …) = kr`,
which holds by `rfl` (the catch-all branch returns `kr`
unchanged).  `RegistryPreserving (.replaceKey actor newKey)`
reduces to `kr.insert actor newKey = kr`, which is false in
general — Lean's `inferInstance` correctly fails, serving as
the negative witness.

**Surface impact:**
  * §10.2 typeclass declaration updated.
  * §10.3 instance table now distinguishes "on `Transition`"
    (`LocalTo`, `FreezePreserving`) from "on `Action`"
    (`RegistryPreserving`).
  * §17.1 theorem inventory clarifies the per-Transition vs
    per-Action instance count.
  * §17.4 generated-instance shape updated to reflect the
    indexing-type asymmetry.
  * §19.6 LX.2 / LX.3 work-unit deliverables updated.

The §10.2 docstring carries the full rationale so future
readers don't need to consult this changelog.

#### E.1.2 `applyActionToRegistry` argument-order error

**Pre-audit form:**

```lean
applyActionToRegistry action oldRegistry = oldRegistry
```

**Post-audit form (matches actual signature
`def applyActionToRegistry (kr : KeyRegistry) : Action →
KeyRegistry`):**

```lean
applyActionToRegistry kr a = kr
```

**Why this matters.**  Even if the pre-audit
`RegistryPreserving` formulation were not broken
(see E.1.1), it would not type-check against the actual
kernel signature: `applyActionToRegistry` takes
`KeyRegistry` first, `Action` second.  The post-audit
formulation matches the kernel signature exactly.

**Surface impact:** §10.2 declaration updated; §17.1
theorem statements updated.

#### E.1.3 `MacroM` vs `CommandElabM` for IO at elaboration time

**Pre-audit claim:**  The plan repeatedly claimed the
`law` keyword would be implemented via `macro_rules`
running in `MacroM`, with `IO.FS.writeFile` calls for the
codegen-input JSON sidecar emitted "via Lean's `MacroM`
IO surface (using `Lean.MacroM.lift`)".

**Reality:**  Lean 4's `MacroM` is `ReaderT Macro.Context
(EStateM Exception Macro.State)` — a pure syntactic
transformer monad with no general IO access.  Writing a
JSON file at elaboration time requires `CommandElabM`
(the command-elaboration monad), which has full `IO`
access via `MonadLiftT IO CommandElabM`.

**Post-audit form:**  The plan now uses `elab_rules :
command` (or equivalently `elab "law" … : command`)
throughout.  The skeleton in §6.6 was rewritten;
references in §6.2, §6.3, §10.13, §16.1, §18.2, §19.6
LX.6 / LX.11 / LX.31 were updated.

**Why this matters.**  A Lean 4 `command` is the natural
home for a syntactic surface that needs to:
  1. emit multiple top-level declarations (`def`,
     `instance`, etc.) into the surrounding namespace —
     `Lean.Elab.Command.elabCommand` handles this in
     `CommandElabM`;
  2. perform IO at elaboration time (write the codegen-
     input file) — `liftIO` works in `CommandElabM`;
  3. emit diagnostics anchored at user-source positions
     — `Lean.throwErrorAt` works in any monad with a
     `MonadRef` instance, including `CommandElabM`.

The Phase-4 `Law.mk` macro (`LegalKernel/DSL/Law.lean`)
correctly uses `macro_rules` because it has no IO needs
— it only emits a single `Transition` term.  Lex's
broader scope (multiple emitted decls + sidecar IO) makes
the `command`-elaboration approach correct.

**Surface impact:**  All `MacroM` references in the plan
were updated to `CommandElabM` *except* in
contrastive contexts (e.g. "the pure `MacroM` used by the
Phase-4 macro" — which is correctly `MacroM`).  The
Phase-4 macro's identity is unchanged.

### E.2 Cross-reference inconsistencies resolved

The work-unit decomposition from 23 to 38 WUs (in the
v1-refinement commit) left a handful of stale WU-number
references in `§2.1` (architectural overview),
`§17.3` (theorem inventory), `§17.5` (regression-`example`
spec), and the `_lex_inputs/` directory caption.  All have
been updated to reference the post-decomposition WU IDs:

| Pre-audit reference          | Post-audit reference              | Location           |
|------------------------------|-----------------------------------|--------------------|
| LX.18 (LexDeployment)         | LX.31–33                          | §2.1 module graph  |
| LX.20 (LexDiff)              | LX.34–35                          | §2.1 module graph  |
| LX.21 (LexFormat)            | LX.36                             | §2.1 module graph  |
| LX.22 (Deployments/)         | LX.37                             | §2.1 module graph  |
| LX.4 / LX.18 (umbrella)      | LX.6 / LX.12 / LX.31              | §2.1 module graph  |
| LX.18 (cross-deployment-replay) | LX.32                          | §17.3 header       |
| LX.7 (LexProperty)           | LX.12 (skeleton; LX.13–16 fill)   | §2.1 module graph  |
| LX.8 (LexCodegen)            | LX.17 (skeleton; LX.18–20 fill)   | §2.1 module graph  |

### E.3 Unchanged (verified accurate)

The following claims were verified correct against the
actual codebase and required no changes:

  * `MonotonicLawSet` field name (`isMonotonic`) at
    `Conservation.lean` line 615.
  * `compileTransition` defined at `Authority/Action.lean`
    line 286, with `replaceKey` mapping to
    `Laws.freezeResource 0` at line 291.
  * `Events/Extract.lean`'s `if oldV != newV` zero-delta
    filter at lines 95, 128, 132 (the "lines 122-123"
    citation in §6.6 was anchored on context, not exact
    line; spot-checked OK).
  * 17 `Action` constructors at indices 0..16 (counted
    via `grep -E "^\s*\| (transfer|...|revokeLocalPolicy)"`).
  * `kernelBuildTag` value `"knomosis-local-policies"` at
    `LegalKernel.lean` line 219 (corresponds to the
    plan's "Pre-LX" baseline).
  * Test count `1228` post-LP (verified via CLAUDE.md's
    Workstream-LP changelog entry).
  * TCB allowlist (`tcb_allowlist.txt`) contains exactly
    `Std.Data.TreeMap`; the plan's claim of zero allowlist
    edits is correct.
  * Phase-4 `Law.mk` macro uses `macro_rules` (verified
    at `DSL/Law.lean` line 106) — the plan's deprecation
    plan is consistent with the existing surface.
  * `signingInput` signature
    `(action : Action) (signer : ActorId) (nonce : Nonce)
     (deploymentId : ByteArray) : SigningInput` matches
    the post-Audit-3.3/3.4 form at
    `Authority/SignedAction.lean` line 171.
  * `applyActionToRegistry` matches `(kr : KeyRegistry) →
    Action → KeyRegistry` at `Authority/SignedAction.lean`
    line 465 (the argument-order issue in E.1.2 was a
    plan-side error; the kernel signature itself is
    unchanged).
  * `LegalKernel/Authority/Nonce.lean`'s
    `localPolicies := LocalPolicies.empty` default at
    line 140 — the plan's claim that pre-LP fixtures
    "keep elaborating" (§13.1 backwards-compat note) is
    accurate.

### E.4 Post-audit invariants

The post-audit plan satisfies:

  * **Mathematical correctness.**  Every typeclass
    formulation type-checks against the actual kernel
    signatures.  Every theorem statement names a real
    kernel theorem or instance.
  * **Lean 4 feasibility.**  Every Lean mechanism
    referenced (`elab_rules`, `CommandElabM`,
    `Lean.throwErrorAt`, `ParametricAttribute`,
    `liftIO`, atomic-rename via `IO.FS.rename`, etc.)
    exists in current Lean core (≥ 4.10) and is
    discoverable via `#check` against a fresh
    elaboration.
  * **No provenance markers in declaration names.**  Per
    CLAUDE.md, identifiers describe content; the audit-1
    record lives only in this changelog and (where
    applicable) in docstrings.
  * **No new opaque or axiom declarations.**  The three
    typeclasses are `Prop`-valued single-field records
    using only standard Lean built-ins.
  * **No expansion of the kernel TCB.**  The
    `tcb_allowlist.txt` is unchanged; new modules under
    `LegalKernel/DSL/`, `Tools/`, `Deployments/`, and
    additive instance landings under `LegalKernel/Laws/`
    are all non-TCB.
  * **Strict-narrowing of admissibility preserved.**  The
    `signed_by`-strengthening conjunct lives at the shim
    layer (per §9.1), not at `AdmissibleWith`.  Existing
    `replay_impossible`, `nonce_uniqueness`, and the
    Workstream-LP / PA composition theorems re-elaborate
    verbatim post-LX.
  * **Cross-deployment-replay protection preserved.**
    `signingInput`'s injectivity in `(action, signer,
    nonce, deploymentId)` (Audit-3.3/3.4) is the
    integration point Lex's `deployment_id` flows into;
    the plan's §16.5 description is accurate.

A v0.2 audit pass — once the M1 checkpoint (LX.1 – LX.21)
lands — will produce an Appendix F with whatever further
corrections the implementation surfaces.


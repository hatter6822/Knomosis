<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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

The motivating observation is that adding a new law to Canon
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
  * [§19 Work-unit breakdown](#19-work-unit-breakdown) — LX.1 – LX.23 (M1: LX.1–LX.11; M2: LX.12–LX.17; M3: LX.18–LX.23)
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

## Status

  * **Drafted on branch:** `claude/lex-implementation-planning-ZzOSx`.
  * **Phase prefix:** `LX` (Lex) — work units labelled `LX.1`
    … `LX.23` to disambiguate from the Genesis-Plan
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
  * **Frozen indices reserved by this workstream:** none
    in M1 (no new `Action` or `Event` constructors).  M2
    leaves the existing 17 `Action` constructor indices
    (0..16) unchanged; the Lex re-expressions inhabit the
    same indices.  M3's example deployment-private law
    (`my_deployment.staking_lock`, §15.5 of the design
    document) is illustrative-only and is not registered
    in `lex_index_registry.txt`.

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
  3. **An action-index registry** (`lex_index_registry.txt`)
     pins frozen wire indices to law identifiers and first-
     release tags.  Two laws sharing an index, or a law
     renumbering, fails the new `lex_lint` audit binary.
     See §4.
  4. **A codegen-input directory**
     (`LegalKernel/_lex_inputs/`) accumulates per-law JSON
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
     (`LegalKernel/DSL/LexProperty.lean`) discharges seven
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
    landed in LX.23; default-on wiring deferred to v2.
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
LegalKernel.DSL.LexLaw                     (LX.4; new — the `law` macro elaborator)
  ├── imports Conservation
  ├── imports DSL.Law (re-exports `Law.mk` for v1 callers)
  └── exports `law` syntax + per-file emission

LegalKernel.DSL.LexProperty                (LX.7; new — synthesizer library)
  ├── imports Conservation + Laws.* + LexLaw
  └── exports synthesizer-internal helpers

LegalKernel.DSL.LexDeployment              (LX.18; new — `deployment` manifest macro)
  ├── imports Encoding.SignInput + LexLaw + LexProperty
  └── exports `deployment` syntax + `Deployment` record

Tools.LexCommon                            (LX.3; new — shared parsing utilities)
  └── imports Tools.Common

Tools.LexLint                              (LX.3; new — audit binary)
  └── imports Tools.LexCommon

Tools.LexCodegen                           (LX.8; new — codegen binary)
  └── imports Tools.LexCommon

Tools.LexDiff                              (LX.20; new — semantic-diff binary)
  └── imports Tools.LexCommon

Tools.LexFormat                            (LX.21; new — pretty-printer binary)
  └── imports Tools.LexCommon

LegalKernel._lex_inputs/                   (LX.1; new directory — codegen-input metadata)
  ├── <one .json per Lex law, named by identifier>
  └── (consumed by Tools.LexCodegen)

lex_index_registry.txt                     (LX.1; new file — frozen action-index registry)

LegalKernel.lean                           (extended in LX.4 / LX.18: re-export new modules)

Deployments/                               (LX.22; new directory — example deployments)
  └── Examples/UsdClearing.lean            (LX.22; illustrative manifest)

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
     `LegalKernel/_lex_inputs/<identifier>.json` capturing
     the declaration's metadata for Pass 2.

**Pass 2 (build-time codegen):**  Runs as `lake exe
lex_codegen` (invoked manually by the author and as a
`--check` gate by CI).  Reads every codegen-input file
under `LegalKernel/_lex_inputs/`, sorts by `action_index`,
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

During M1 (LX.1 – LX.11), no existing kernel module is
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
(LX.11) inhabits a **fresh action index** (initially `17`,
or whichever is next-free after PA's potential merge), and
its supporting branches are appended via Pass 2's
append-only mode.  This is the first wire-extending change
LX makes.  Until LX.11, the on-wire format is byte-identical
to pre-LX.

### 2.5 The strict-equivalence invariant (M2)

During M2 (LX.12 – LX.17), every Lex declaration of a
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
    `lex_index_registry.txt`.  Selects the `invariant_claims`
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
  * **Operator.**  Runs the `canon` runtime CLI with a
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
    wire tag.  Pinned in `lex_index_registry.txt`.  Cannot
    change without a Genesis-Plan amendment.
  * **Identifier** (`identifier : String`).  The canonical
    fully-qualified name of a law, e.g.
    `legalkernel.transfer` or `my_deployment.staking_lock`.
    Used as the key in `lex_index_registry.txt` and as the
    file name in `LegalKernel/_lex_inputs/`.
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
  * **Codegen-input file.**  A `LegalKernel/_lex_inputs/
    <identifier>.json` JSON document capturing the law's
    metadata.  Pass 1 emits one per law; Pass 2 reads them
    all to regenerate cross-module artefacts.
  * **`lex_index_registry.txt`.**  The checked-in
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

`lex_index_registry.txt` is the project-wide source of
truth for the assignment of frozen wire tags to law
identifiers.  Its purpose is to prevent the
*action-index renumbering attack* — an accidental or
malicious renumbering that would silently re-route every
historical log entry's constructor lookup to a different
law, breaking replay determinism.

### 4.1 File format

```text
# Canon — Lex action-index registry
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
     `LegalKernel/_lex_inputs/<identifier>.json` file's
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
     `lex_index_registry.txt`:
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

Each `LegalKernel/_lex_inputs/<identifier>.json` file has
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
inside `LegalKernel/DSL/LexLaw.lean`.  Per §16 of the
design document's audit-1 changelog, clause grammar is
fixed (no colon between `flow`'s resource and amount
arguments; bare-term escape hatch for `impl` is preserved
for v1, removed in v2).

### 6.2 Per-file elaboration steps

The macro's `macro_rules` block does the following, in
order, at file-elaboration time:

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
  8. **Emit the codegen-input file.**  The macro
     serialises the `LawDecl` value to JSON and writes it
     to `LegalKernel/_lex_inputs/<identifier>.json`.  The
     write is *deterministic*: equal `LawDecl` values
     produce byte-equal JSON.  The write happens via
     `IO.FS.writeFile` from inside a `MacroM` action;
     because Lean macros may run more than once during
     incremental builds, the write is idempotent.
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
    plus (optionally) `lex_index_registry.txt` for the
    consistency `#check_failure`.
  * Run any tactic over `apply_admissible` shape.

The constraint is structural: a Lean 4 macro is a *pure*
syntax-tree transformer over the file being parsed, plus
`MacroM`-restricted IO (file reads under a controlled
allowlist).  The cross-module artefacts are emitted by a
separate binary.

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
`PreNode` defined inside `LegalKernel/DSL/LexLaw.lean`:

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

`LegalKernel/DSL/LexProperty.lean` exports synthesizers
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

/-- `RegistryPreserving t` — `t`'s authority-layer effect is
    the identity on `KeyRegistry`.  Trivial for every
    `Action` constructor whose `compileTransition` is a
    kernel-level no-op (i.e. all but `replaceKey` and
    `registerIdentity`). -/
class RegistryPreserving (t : Transition) : Prop where
  registry_preserves :
    ∀ (oldRegistry : KeyRegistry) (action : Action),
      Action.compileTransition action = t →
      applyActionToRegistry action oldRegistry = oldRegistry

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

### 10.3 Per-existing-law instances (LX.2)

Workstream LX.2 lands typeclass instances for every
existing kernel-built-in law:

| Law                                              | `LocalTo`                            | `FreezePreserving`                   | `RegistryPreserving` |
|--------------------------------------------------|--------------------------------------|--------------------------------------|----------------------|
| `transfer r sender receiver amount`              | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}` (closure) | yes                  |
| `mint r minter receiver amount`                  | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `burn r burner amount`                           | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `freezeResource r`                               | `LocalTo {}` (touches no balance)     | `FreezePreserving [*]` (no balance change preserves any frozen invariant) | yes |
| `replaceKey actor newKey`                        | `LocalTo {}`                          | `FreezePreserving [*]`                | **no**               |
| `reward r minter receiver amount`                | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `distributeOthers r excluded amount`             | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `proportionalDilute r excluded totalReward`      | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `dispute / disputeWithdraw / verdict / rollback` | `LocalTo {}` (kernel-no-op)           | `FreezePreserving [*]`                | yes                  |
| `registerIdentity actor newKey`                  | `LocalTo {}`                          | `FreezePreserving [*]`                | **no**               |
| `deposit r recipient amount depositId`           | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `withdraw r sender amount recipientL1`           | `LocalTo {r}`                         | `FreezePreserving {r' ≠ r}`           | yes                  |
| `declareLocalPolicy / revokeLocalPolicy`         | `LocalTo {}`                          | `FreezePreserving [*]`                | yes                  |

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
`Test/DSL/LexProperty.lean`:

  * **Positive case.**  Build a representative `ImplStmt`
    list that the synthesizer should accept; assert the
    emitted instance compiles and the resulting
    `IsConservative`/etc. value is provable via
    `inferInstance`.
  * **Negative case.**  Build an `ImplStmt` list outside
    the synthesizer's domain; assert the synthesizer
    returns `.fail` with the expected error variant.

The test count for LX.7 is approximately 30 cases (5 per
synthesizer × 7 synthesizers, minus user-defined which
has no synthesizer).


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

`Tools/LexCodegen.lean` is a Lean executable following the
existing `Tools/CountSorries.lean` / `Tools/TcbAudit.lean`
template:

```lean
import Tools.LexCommon
import Lean.Json

namespace LexCodegen

structure CodegenOptions where
  checkOnly  : Bool := false       -- --check mode
  inputDir   : System.FilePath := "LegalKernel/_lex_inputs/"
  outputs    : Outputs := default

structure Outputs where
  actionFile        : System.FilePath := "LegalKernel/Authority/Action.lean"
  encodingFile      : System.FilePath := "LegalKernel/Encoding/Action.lean"
  eventsFile        : System.FilePath := "LegalKernel/Events/Extract.lean"
  signedActionFile  : System.FilePath := "LegalKernel/Authority/SignedAction.lean"

def main (args : List String) : IO UInt32 := do
  let opts := parseOptions args
  let inputs ← loadCodegenInputs opts.inputDir
  let registry ← loadRegistry "lex_index_registry.txt"
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

## §13 The `lex_lint` binary

### 13.1 What `lex_lint` checks

`Tools/LexLint.lean` walks `LegalKernel/Laws/` and
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

`Tools/LexDiff.lean` takes two git refs (or two checked-in
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

`Tools/LexFormat.lean` is a pretty-printer that rewrites
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

Defined in `LegalKernel/DSL/LexDeployment.lean`:

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
(`lex_diff`, future LSP server, future `canon manifest
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
  * **`RegistryPreserving (t : Transition) : Prop`** — class declaration.

In `LegalKernel/Laws/Transfer.lean`:

  * **`transfer_localTo`** : `LocalTo {r} (transfer r sender receiver amount)`.  Built from
    `transfer_does_not_touch_other_resources`.
  * **`transfer_freezePreserving`** : `FreezePreserving (manifestResources \ {r})
    (transfer r sender receiver amount)` for any deployment.  Built from
    `transfer_preserves_freeze`.
  * **`transfer_registryPreserving`** : `RegistryPreserving (transfer r sender receiver amount)`.
    Trivial: `transfer`'s `applyActionToRegistry` branch is `id`.

(Analogous instances for `mint`, `burn`, `freezeResource`, `replaceKey`, `reward`,
`distributeOthers`, `proportionalDilute`, `dispute`, `disputeWithdraw`, `verdict`,
`rollback`, `registerIdentity`, `deposit`, `withdraw`, `declareLocalPolicy`,
`revokeLocalPolicy` — 17 laws × 3 typeclasses = 51 instances total in M1.  Negative
witnesses for `replaceKey`'s and `registerIdentity`'s `RegistryPreserving` are
*intentionally absent* — those laws mutate the registry; trying to derive an instance
fails by design.)

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

### 17.3 The cross-deployment-replay theorem (LX.18)

In `LegalKernel/DSL/LexDeployment.lean`:

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

instance foo_isConservative
    {p₁ : T₁} … {pₙ : Tₙ} :
    IsConservative (foo_transition p₁ … pₙ) := ⟨…⟩

instance foo_isMonotonic ... : IsMonotonic ... := ⟨…⟩
instance foo_localTo ... : LocalTo {…} ... := ⟨…⟩
instance foo_freezePreserving ... : FreezePreserving ... := ⟨…⟩
instance foo_registryPreserving ... : RegistryPreserving ... := ⟨…⟩
```

The instance bodies are produced by the synthesizers.
The Prop-level conclusions, the type signatures, and the
constructor argument lists are all stable across
synthesizer revisions.

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
| L005 | error    | Action index `<N>` already used by law `<L>`                  | Allocate a fresh index ≥ 17 and update `lex_index_registry.txt`.                  | macro / lex_lint / codegen |
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
     parse time.
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
reviewable.  LX.1 has no Lex-side dependencies (it just
adds a registry file and a sidecar directory); LX.2 –
LX.10 follow LX.1's dependency chain.  M2's units (LX.12 –
LX.17) depend on M1 having landed.  M3's units (LX.18 –
LX.23) depend on M2.

Total: 23 work units.

The dependency DAG:

```
LP.14 (LP complete; merged or in same PR)
  ↓
LX.1 → LX.2 → LX.3 → LX.4 → LX.5 → LX.6 → LX.7 → LX.8 → LX.9 → LX.10 → LX.11
                                                                          ↓
                                                                   (M1 acceptance)
                                                                          ↓
LX.12 → LX.13 → LX.14 → LX.15 → LX.16 → LX.17
   (re-express the 17 kernel-built-ins, then flip to canonical regen)
                                                                          ↓
                                                                   (M2 acceptance)
                                                                          ↓
LX.18 → LX.19 → LX.20 → LX.21 → LX.22 → LX.23
            (manifest macro + tooling + worked example + property test gen)
                                                                          ↓
                                                                   (M3 acceptance)
```

### LX.1 — Action-index registry + codegen-input directory

**Files (new):**

  * `lex_index_registry.txt` — initialised with the 17
    existing constructors, formatted per §4.1.
  * `LegalKernel/_lex_inputs/` — empty directory plus a
    `.gitkeep` and a `README.md` documenting the schema
    (§5.2).

**Files modified:**

  * `.gitignore` — explicit *include* of `_lex_inputs/*.json`
    (the directory's contents are committed; this is the
    Pass 1 → Pass 2 communication channel).
  * `lakefile.lean` — add the registry's `extraDepTargets`
    so `lake build` re-runs when the registry changes.

**Deliverables:**

  * The registry file with 17 entries.
  * A shell-level test that confirms the 17 entries are
    in increasing-index order and unique.

**Acceptance criteria:**

  * `lake build` succeeds (no Lean code changes).
  * `lake test` succeeds.
  * `lake exe count_sorries` succeeds (no new Lean files).
  * `lake exe tcb_audit` succeeds (no new TCB-touching
    imports).

**Test files:** no Lean tests added in this WU; the
shell-level test above suffices.

### LX.2 — New non-TCB typeclasses + per-existing-law instances

**Files modified:**

  * `LegalKernel/Conservation.lean` — add `LocalTo`,
    `FreezePreserving`, `RegistryPreserving` typeclasses
    and the `FreezePreservingLawSet` structure plus the
    `freeze_preservation_via_law_set` corollary.

**Files modified (instances on existing laws):**

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

(The `replaceKey` and `registerIdentity` instances live in
`Authority/SignedAction.lean` and `Authority/Identity.lean`
as additive instance declarations; both lack
`RegistryPreserving` instances by design.)

**Deliverables:**

  * 51 typeclass instances (3 typeclasses × 17 laws minus
    the 2 missing `RegistryPreserving` instances for
    `replaceKey` / `registerIdentity`).
  * `FreezePreservingLawSet` structure + corollary.
  * Each instance proved using existing per-law theorems.
    No new theorem infrastructure introduced.

**Acceptance criteria:**

  * `lake build LegalKernel.Conservation` succeeds.
  * Every instance `#print axioms`-clean (the standard
    three).
  * `lake exe tcb_audit` succeeds (the new typeclasses
    live in the existing non-TCB module
    `Conservation.lean`; no allowlist edits).
  * No `sorry`.

**Test files:**  `Test/ConservationTests.lean` extended
with 17 instance-resolution checks (one per law); each
is a one-line `example : LocalTo {r} (Laws.transfer r s
r' am) := inferInstance`-style test.

### LX.3 — `Tools/LexCommon.lean` + `Tools/LexLint.lean` skeleton

**Files (new):**

  * `Tools/LexCommon.lean` — shared utilities: `LawDecl`
    skeleton, JSON schema constants, registry parsing
    helpers, source-position threading.
  * `Tools/LexLint.lean` — audit binary skeleton with
    `main` function dispatching on subcommand.

**Files modified:**

  * `lakefile.lean` — declare `lean_lib LexCommon` and
    `lean_exe lex_lint`, both `supportInterpreter := true`.
  * `.github/workflows/ci.yml` — add `lake exe lex_lint`
    to the CI matrix (no-op until Lex laws appear).

**Deliverables:**

  * `LexCommon.lean` exporting:
    – `LawDecl` (struct mirroring §5.2's JSON schema);
    – `parseRegistry : String → Except String (List RegistryEntry)`;
    – `loadCodegenInputs : System.FilePath → IO (List LawDecl)`;
    – `Diagnostic` record + emitter helpers.
  * `LexLint.lean` exporting `main : List String → IO UInt32`
    that walks `LegalKernel/Laws/` (no-op pre-LX.4 since
    no Lex declarations exist yet).
  * Exit codes 0 / 1 / 2 per §13.3.

**Acceptance criteria:**

  * `lake build Tools.LexCommon` and `lake build
    Tools.LexLint` succeed.
  * `lake exe lex_lint` exits 0 on a clean checkout.
  * CI integration passes.

**Test files:** `Test/Tools/LexCommon.lean` (new) — 8
cases covering registry parsing (happy path, malformed
line, duplicate index, gap detection, comment handling,
empty file).

### LX.4 — `LegalKernel/DSL/LexLaw.lean` (the `law` macro)

**Files (new):**

  * `LegalKernel/DSL/LexLaw.lean` — the `law` macro
    (parser + per-file elaborator).

**Files modified:**

  * `LegalKernel.lean` — re-export `LegalKernel.DSL.LexLaw`.

**Deliverables:**

  * Lean `syntax` declarations for `law` and its clause
    keywords.
  * `macro_rules` block elaborating `law` to the bundle
    of generated declarations.
  * `LawDecl` Lean-level data type.
  * `parseLawDecl` helper turning the user's Syntax into
    a `LawDecl`.
  * Codegen-input writer (the `IO.FS.writeFile` step).
  * Per-file diagnostic emission (L001 / L002 / L009).

**Acceptance criteria:**

  * `lake build LegalKernel.DSL.LexLaw` succeeds.
  * The macro elaborates a minimal example without
    error (a single-effect law with a `flow` `impl` and a
    one-item `satisfies`).
  * `lake exe count_sorries` and `lake exe tcb_audit`
    pass.

**Test files:** `Test/DSL/LexLaw.lean` (new) — 12 cases:

  * Minimal-law elaboration (positive case).
  * Each missing-required-clause produces the correct
    L-code (L001, L002, L009).
  * Codegen-input file is written with the expected JSON
    structure.
  * Re-elaboration is idempotent (no spurious file
    rewrites on identical input).

### LX.5 — `pre` grammar enforcer + `impl` calculus enforcer

**Files modified:**

  * `LegalKernel/DSL/LexLaw.lean` — add the `parsePreExpr`
    and `parseImplCalculus` walkers; wire into the
    elaboration pipeline.

**Deliverables:**

  * `parsePreExpr : Term → Except (Position × String) PreNode`
    walking the §7.2 grammar.
  * `parseImplCalculus : Syntax → Except (Position × String) (List ImplStmt)`
    walking the §8.1 calculus.
  * The `@[lex_pre]` and `@[lex_impl]` attributes with
    their attach-time decidability checks.
  * Diagnostic emission for L003, L010, L019, L022, L023,
    L027.

**Acceptance criteria:**

  * Grammar tests in `Test/DSL/LexLaw.lean` cover both
    positive (well-formed `pre`/`impl` is accepted) and
    negative (each forbidden shape fires the correct
    L-code).
  * `lex_lint` rejects the same inputs the macro rejects.

**Test files:** `Test/DSL/LexLaw.lean` extended (+~20
cases): each forbidden `pre` shape + each forbidden
`impl` shape, plus positive-case round-trip.

### LX.6 — `signed_by` / `authorized_by` semantics

**Files modified:**

  * `LegalKernel/DSL/LexLaw.lean` — add the `signed_by`
    strengthening and `authorized_by` validation.

**Deliverables:**

  * `signed_by sender` emits an additional propositional
    conjunct `st.signer = sender` to the generated
    `myLaw_apply` shim's hypothesis bundle.
  * `authorized_by self_only` static-analysis check (§9.3).
  * `authorized_by self_only` rejects laws with non-signer-
    keyed mutation (L011).
  * `signed_by` actor name is recorded in the codegen-input
    `signed_by` field for downstream use by the
    `nonce_advances` synthesizer.

**Acceptance criteria:**

  * Generated shim compiles for every kernel-built-in law.
  * `self_only` rejects a law that flows from `other` to
    `sender` with an L011 error.
  * The `nonce_advances [sender]` synthesizer (LX.7)
    succeeds by definition for laws with `signed_by sender`.

**Test files:** `Test/DSL/LexLaw.lean` extended (+~6
cases) covering the `signed_by` / `self_only` semantics.


### LX.7 — Property synthesizer library

**Files (new):**

  * `LegalKernel/DSL/LexProperty.lean` — synthesizer
    library.

**Files modified:**

  * `LegalKernel/DSL/LexLaw.lean` — wire the macro's
    `satisfies` clause emission to the synthesizer
    dispatch.
  * `LegalKernel.lean` — re-export
    `LegalKernel.DSL.LexProperty`.

**Deliverables:**

  * `synth_conservative` synthesizer.
  * `synth_monotonic` synthesizer.
  * `synth_local` synthesizer (parameterised on the
    resource set).
  * `synth_freeze_preserving` synthesizer (parameterised
    on the resource set).
  * `synth_nonce_advances` synthesizer (derived from
    `signed_by`).
  * `synth_registry_preserving` synthesizer.
  * Dispatch table mapping property names to
    synthesizers.
  * Property-claim parser (handles `local [{r₁, r₂}]`,
    `local [{}]`, etc., and rejects `local [*]` with L024
    and `conservative [r]` with L025).
  * `proof <P> := …` override threading: the user's
    tactic block is captured into the codegen-input's
    `proof_overrides` field; if present, it replaces
    the synthesizer's body.

**Acceptance criteria:**

  * Each of the seven synthesizers has at least one
    positive and one negative test in
    `Test/DSL/LexProperty.lean`.
  * `lake build LegalKernel.DSL.LexProperty` succeeds.
  * `#print axioms`-clean.
  * Per-existing-law instance generation produces
    `Transition` instances byte-equivalent to the
    pre-M2 hand-written forms (this is M2's strict-
    equivalence invariant, prepped here so M2 can use
    `rfl` regression `example`s).

**Test files:** `Test/DSL/LexProperty.lean` (new) — ~40
cases: 5 per synthesizer × 7 synthesizers, plus
property-claim parser tests.

### LX.8 — `Tools/LexCodegen.lean` (additive mode)

**Files (new):**

  * `Tools/LexCodegen.lean` — codegen binary.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_codegen`,
    `supportInterpreter := true`.
  * `LegalKernel/Authority/Action.lean` — add the
    `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED`
    fence (no content yet; fence position prepared for
    LX.11's first append).
  * `LegalKernel/Encoding/Action.lean` — add the fence.
  * `LegalKernel/Events/Extract.lean` — add the fence.
  * `LegalKernel/Authority/SignedAction.lean` — add the
    fence.

**Deliverables:**

  * `LexCodegen.lean` exporting:
    – `loadCodegenInputs : System.FilePath → IO (List LawDecl)`;
    – `generateAction`, `generateEncoding`,
       `generateEvents`, `generateSignedAction` —
       string-level renderers;
    – `writeOrCheck : Outputs → CheckMode → List String → IO Unit`;
    – `main : List String → IO UInt32`.
  * The four target files have lex-generated fences.
  * `lake exe lex_codegen` is a no-op on a fresh
    checkout (no Lex declarations yet); `lake exe
    lex_codegen --check` also passes.

**Acceptance criteria:**

  * `lake build Tools.LexCodegen` succeeds.
  * `lake exe lex_codegen` runs without error on a fresh
    checkout.
  * `lake exe lex_codegen --check` passes.
  * The four target files compile after fence insertion
    (the fences are inside Lean comments so the parser
    doesn't see them).

**Test files:** `Test/Tools/LexCodegen.lean` (new) — 10
cases covering the renderers' output stability,
fence-respecting append behaviour, and `--check` mode.

### LX.9 — `events` block elaborator

**Files modified:**

  * `LegalKernel/DSL/LexLaw.lean` — extend the macro to
    handle the `events := do …` clause.

**Deliverables:**

  * `parseEventBlock : Syntax → Except (Position ×
    String) (List EventStmt)` walker.
  * Desugaring of each `EventStmt` into a `List Event`-
    valued expression.
  * Codegen-input emission for the `events` field.
  * Diagnostic emission for L013, L014, L027.
  * The empty-form `events := []` accepted alongside
    `events := do pure ()` and `events := do nothing`.

**Acceptance criteria:**

  * The example minimal-law (LX.4) gains an `events := []`
    clause and elaborates.
  * A more complex law with `if amount > 0 then emit
    balanceChanged …` elaborates correctly.
  * The L013 warning fires when `events` omits a touched
    cell or includes an untouched one.

**Test files:** `Test/DSL/LexLaw.lean` extended (+~10
cases) covering the events block elaboration.

### LX.10 — Lakefile + CI integration

**Files modified:**

  * `lakefile.lean` — confirm all new `lean_exe` and
    `lean_lib` declarations are wired.
  * `.github/workflows/ci.yml` — add `lake exe lex_lint`
    and `lake exe lex_codegen --check` as gating CI
    checks.
  * `CLAUDE.md` — Active Development Status entry
    describing the Lex M1 landing, the new audit
    binaries, and the registry file.

**Deliverables:**

  * CI now runs five Lex-related gates:
    1. `lake build` (already existed; succeeds with new
       modules).
    2. `lake test` (already existed; new test suites
       registered).
    3. `lake exe count_sorries` (already existed).
    4. `lake exe tcb_audit` (already existed; allowlist
       unchanged).
    5. `lake exe stub_audit` (already existed).
    6. **`lake exe lex_lint`** — new.
    7. **`lake exe lex_codegen --check`** — new.

**Acceptance criteria:**

  * All seven gates green on a fresh checkout.
  * The CLAUDE.md "Active development status" section
    names LX as in-progress with M1 landing.

**Test files:** none beyond what LX.1 – LX.9 already
exercise.

### LX.11 — Example Lex-only law + M1 acceptance

**Files (new):**

  * `LegalKernel/Laws/ExampleLex.lean` — a single Lex
    law `example.example_lex_only_law` that exercises
    the macro's full surface (parameters, all clause
    types, a small `satisfies` list, an `events` block).

**Files modified:**

  * `lex_index_registry.txt` — append the example law's
    line at index 17 (or higher if PA has merged).
  * `LegalKernel/Authority/Action.lean` — codegen-
    appended constructor and `compileTransition` branch
    inside the fence.
  * `LegalKernel/Encoding/Action.lean` — codegen-
    appended encoding branches inside the fence.
  * `LegalKernel/Events/Extract.lean` — codegen-
    appended event branch inside the fence.
  * `LegalKernel/Authority/SignedAction.lean` — codegen-
    appended `non_registry_mutating` branch inside the
    fence.

**Deliverables:**

  * The example law elaborates cleanly.
  * `lake exe lex_codegen` regenerates the four target
    files with the new branches inside the fence.
  * `lake build` succeeds with the regenerated content.
  * Every existing test still passes byte-for-byte
    (the new constructor index doesn't conflict with any
    pre-existing test).
  * `lake exe lex_codegen --check` passes (committed
    artefacts match generated).

**Acceptance criteria (M1 milestone):**

  * The seven CI gates from LX.10 all green.
  * The example law's regression `example` (proving its
    `transition_def` matches the synthesizer's output)
    elaborates.
  * `#print axioms LegalKernel.Laws.example_lex_only_law`
    returns the standard three.

**Test files:** `Test/Laws/ExampleLex.lean` (new) — 8
cases: positive elaboration, `IsConservative` instance
resolution, `IsMonotonic` instance resolution, locality,
freeze preservation, registry preservation, signed_by
strengthening, end-to-end value-level acceptance.

### LX.12 — Re-express balance laws (transfer, mint, burn, freezeResource, reward)

**Files modified:**

  * `LegalKernel/Laws/Transfer.lean` — Lex declaration
    replacing the hand-written `Transition`.
  * `LegalKernel/Laws/Mint.lean` — same.
  * `LegalKernel/Laws/Burn.lean` — same.
  * `LegalKernel/Laws/Freeze.lean` — same.
  * `LegalKernel/Laws/Reward.lean` — same.

For each:

  * The Lex declaration follows the design-doc §5.2 –
    §5.4 / §15.1 / §15.2 worked examples.
  * The hand-written `Transition` is removed.
  * A regression `example` is added asserting that the
    Lex-emitted `transition_def` is `rfl`-equal to the
    pre-LX.12 hand-written form.
  * `lex_codegen` regenerates the cross-module artefacts;
    the regenerated content must be byte-equivalent to
    the pre-LX.12 hand-written `Action.lean` etc.

**Deliverables:**

  * 5 Lex declarations.
  * 5 regression `example`s (each `rfl`).
  * 5 entries appended to `LegalKernel/_lex_inputs/`.
  * Cross-module artefacts byte-equivalent to pre-LX.12.

**Acceptance criteria:**

  * `lake build` succeeds.
  * `lake test` succeeds with the *unmodified* test count.
  * Every existing test passes byte-for-byte.
  * `lake exe count_sorries` returns 0.
  * `lake exe tcb_audit` passes.
  * `lake exe lex_codegen --check` passes.
  * `#print axioms` on every theorem returns the
    standard three.
  * The cross-module artefacts are byte-equivalent to
    pre-LX.12 (modulo formatting normalised by
    `lex_format`).

**Rollback path:**  `git revert` the LX.12 commit; the
hand-written forms reappear and the build succeeds.

### LX.13 — Re-express authority laws (replaceKey, registerIdentity, declareLocalPolicy, revokeLocalPolicy)

**Files modified:**

  * `LegalKernel/Authority/Identity.lean` — Lex declarations
    for `replaceKey` and `registerIdentity`.
  * `LegalKernel/Authority/LocalPolicy.lean` — Lex
    declarations for `declareLocalPolicy` and
    `revokeLocalPolicy`.

(Or, equivalently, dedicated `LegalKernel/Laws/<Name>.lean`
files for each, depending on which is cleaner.)

For each:

  * The Lex declaration uses `register_key` / `register_
    identity` / bare-term escape for the `applyActionToLocalPolicies`
    branches.
  * Regression `example`s assert kernel-impl identity-
    equivalence.
  * The codegen-input's `registry_effect` field is set
    to `"replaceKey"` / `"registerIdentity"` / `"none"`
    as appropriate.

**Deliverables:**

  * 4 Lex declarations.
  * 4 regression `example`s.
  * Cross-module artefacts byte-equivalent.  The
    `applyActionToRegistry` branches for `replaceKey` /
    `registerIdentity` remain functionally identical
    (the `registry_effect` codegen-input field extends
    to carry `"replaceKey"` and `"registerIdentity"`
    variants in M1; LX.13 just consumes them).  For
    `declareLocalPolicy` / `revokeLocalPolicy`, which
    target the LP-introduced `applyActionToLocalPolicies`
    helper (post-Workstream-LP, separate from the
    registry mutation), the codegen-input's
    `registry_effect` field gains a `"localPolicy"`
    variant in LX.13; the codegen pass routes this to
    `applyActionToLocalPolicies` rather than
    `applyActionToRegistry`.  No bare-term escape hatch
    is needed — the calculus's existing `register_key`
    primitive plus a parallel `declare_local_policy`
    primitive (added in LX.13) covers both effect
    surfaces.

**Acceptance criteria:**  Same as LX.12.

### LX.14 — Re-express bridge laws (deposit, withdraw)

**Files modified:**

  * `LegalKernel/Laws/Deposit.lean` — Lex declaration.
  * `LegalKernel/Laws/Withdraw.lean` — Lex declaration.

The Lex declarations use `mint`-style `impl` for `deposit`
(crediting the recipient's balance) and `burn`-style for
`withdraw` (debiting the sender's balance).

**Deliverables:**

  * 2 Lex declarations.
  * 2 regression `example`s.
  * Cross-module artefacts byte-equivalent.

**Acceptance criteria:**  Same as LX.12.

### LX.15 — Re-express dispute laws (dispute, disputeWithdraw, verdict, rollback)

**Files modified:**

  * `LegalKernel/Disputes/LawClassification.lean` —
    extend with Lex declarations for each.

(Or, equivalently, new `LegalKernel/Laws/<DisputeName>.lean`
files; the choice matches design doc §15.4.)

For each:

  * The Lex declaration uses `freeze_resource 0` (a
    kernel-level no-op) as the `impl` body, matching the
    existing `Action.dispute` etc.'s
    `compileTransition → Laws.freezeResource 0` design.
  * The `events` block emits `disputeFiled` /
    `disputeWithdrawn` / `verdictApplied` per design doc
    §15.4.

**Deliverables:**

  * 4 Lex declarations.
  * 4 regression `example`s.
  * Cross-module artefacts byte-equivalent.

**Acceptance criteria:**  Same as LX.12.

### LX.16 — Re-express compound laws (distributeOthers, proportionalDilute)

**Files modified:**

  * `LegalKernel/Laws/DistributeOthers.lean` — Lex
    declaration with a `for` loop.
  * `LegalKernel/Laws/ProportionalDilute.lean` — Lex
    declaration with a `for` loop.

These two laws exercise the `for x in <list>:` shape that
the v1 synthesizer cannot handle (per design-doc §6.4.4
and §15.3).  The Lex declarations supply `proof monotonic
:= by exact distributeOthers_isMonotonic …` overrides
referencing the existing kernel theorems.

**Deliverables:**

  * 2 Lex declarations with explicit `proof <P>`
    overrides.
  * 2 regression `example`s.
  * Cross-module artefacts byte-equivalent.

**Acceptance criteria:**  Same as LX.12.  Additionally:

  * The `proof` override mechanism is exercised end-to-
    end (the override's tactic block is spliced into the
    generated instance body verbatim).

### LX.17 — Flip lex_codegen to canonical regeneration; deprecate Phase-4 Law.mk

**Files modified:**

  * `Tools/LexCodegen.lean` — flip default to
    `--canonical` (regenerate full file body, no fences).
  * `LegalKernel/Authority/Action.lean` — full body now
    generated.
  * `LegalKernel/Encoding/Action.lean` — same.
  * `LegalKernel/Events/Extract.lean` — same.
  * `LegalKernel/Authority/SignedAction.lean` — same.
  * `LegalKernel/DSL/Law.lean` (Phase-4 macro) — add a
    deprecation `@[deprecated "Use Lex's `law` macro
    instead."]` attribute on `Law.mk`.

**Deliverables:**

  * The four target files have no `-- BEGIN LEX-
    GENERATED` fences; their entire body is regenerated.
  * Phase-4 `Law.mk` continues to compile (the
    deprecation is a warning, not an error).
  * The Phase-4 `transferDSL` example is preserved as a
    regression test for `Law.mk` until v2 removes it
    entirely.

**Acceptance criteria (M2 milestone):**

  * All seven CI gates green.
  * Test count unchanged.
  * `#print axioms` on every kernel theorem still
    returns the standard three.
  * Diff against pre-M2 main is exactly: removal of
    hand-written cases plus addition of Lex declarations
    plus regenerated artefact files (modulo `lex_format`
    normalisation).


### LX.18 — `LegalKernel/DSL/LexDeployment.lean` (the `deployment` macro)

**Files (new):**

  * `LegalKernel/DSL/LexDeployment.lean` — the
    `deployment` macro elaborator + `Deployment` record.

**Files modified:**

  * `LegalKernel.lean` — re-export
    `LegalKernel.DSL.LexDeployment`.
  * `lakefile.lean` — re-export config unchanged.

**Deliverables:**

  * `Deployment` record (§16.4).
  * Manifest-grammar `syntax` declarations.
  * `macro_rules` block elaborating to:
    – `def deployment_<name> : Deployment`;
    – `def deployment_<name>_id : ByteArray`;
    – `def deployment_<name>_manifest_hash : ByteArray`;
    – `def deployment_<name>_admissible := AdmissibleWith
       Verify <policy> deployment_<name>_id`;
    – per-`invariant_claims` `def`s (LX.19).
  * Diagnostic emission for L018 (32-byte
    `deployment_id`) and L008 (claim synthesis failure).

**Acceptance criteria:**

  * `lake build LegalKernel.DSL.LexDeployment` succeeds.
  * A minimal manifest (one law, one invariant claim,
    32-byte deployment_id) elaborates cleanly.
  * `lex_lint` rejects malformed manifests with the
    appropriate L-codes.

**Test files:** `Test/DSL/LexDeployment.lean` (new) — 14
cases:

  * Minimal-manifest elaboration.
  * Each missing-required-clause produces the correct
    L-code.
  * `deployment_id` length validation (positive +
    negative).
  * Manifest-hash determinism (two builds of the same
    manifest produce equal hashes).
  * Cross-deployment `deployment_id` distinguishability.

### LX.19 — Invariant-claim synthesis

**Files modified:**

  * `LegalKernel/DSL/LexDeployment.lean` — add the
    `invariant_claims` synthesizer.

**Deliverables:**

  * `synth_monotonic_law_set : List Name → Term` —
    builds a `MonotonicLawSet` value.
  * `synth_conservative_law_set : List Name → Term` —
    builds a `ConservativeLawSet` value.
  * `synth_freeze_preserving_law_set : List Name → Term`
    — builds a `FreezePreservingLawSet` value.
  * Per-claim instance look-up: each named law's
    classification instance is consulted via
    `inferInstance`; missing instances fail with L008.

**Acceptance criteria:**

  * The example USD-clearing manifest's
    `monotonic_law_set [Transfer, Mint, Freeze,
    ReplaceKey]` synthesis produces a value whose
    `isMonotonic` field is provable via the
    typeclass instances.
  * Adding `Burn` to the same `monotonic_law_set` fails
    with L008 (since `Burn` lacks `IsMonotonic`).

**Test files:** `Test/DSL/LexDeployment.lean` extended
(+~6 cases): synthesis happy paths, synthesis failure on
incompatible law sets, parameterised-law synthesis (the
manifest claims a *family* of monotonicity per design-doc
§7.3 final paragraph).

### LX.20 — `Tools/LexDiff.lean`

**Files (new):**

  * `Tools/LexDiff.lean` — semantic-diff binary.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_diff`.

**Deliverables:**

  * `LexDiff.lean` exporting `main : List String → IO
    UInt32`.
  * Per-law diff with mechanically-computed version-bump
    classification (patch / minor / major).
  * Per-deployment diff with law-set / authority / claim
    changes.
  * Refinement-proof obligation check (L016).

**Acceptance criteria:**

  * `lake exe lex_diff <ref-a> <ref-b>` produces a
    semantic diff in the §14.1 format.
  * Reformatting-only changes produce empty output.
  * A minor-bump without a refinement proof fails L016.

**Test files:** `Test/Tools/LexDiff.lean` (new) — 10
cases: per-clause diff detection, version-bump
classification correctness, manifest diff coverage.

### LX.21 — `Tools/LexFormat.lean`

**Files (new):**

  * `Tools/LexFormat.lean` — pretty-printer binary.

**Files modified:**

  * `lakefile.lean` — declare `lean_exe lex_format`.

**Deliverables:**

  * `LexFormat.lean` exporting `main : List String → IO
    UInt32`.
  * Idempotent rewriting: format then re-format produces
    no further changes.
  * Comment / docstring preservation.
  * Canonical empty-events spelling (`events := []`).

**Acceptance criteria:**

  * `lake exe lex_format <file>` produces deterministic
    output.
  * Idempotency tested.
  * Comments in original file appear at corresponding
    lines in formatted file.

**Test files:** `Test/Tools/LexFormat.lean` (new) — 8
cases: clause-order canonicalisation, indentation
canonicalisation, empty-events forms, comment
preservation.

### LX.22 — Worked example deployment + amendment workflow walkthrough

**Files (new):**

  * `Deployments/Examples/UsdClearing.lean` — the
    USD-clearing manifest from design-doc §7.2.
  * `docs/lex_amendment_walkthrough.md` — a checked-in
    walkthrough of bumping `legalkernel.transfer` from
    `1.0.0` to `1.1.0` (refinement adding an upper
    bound on `amount`).

**Files modified:**

  * `lex_index_registry.txt` — no changes (the example
    deployment uses kernel-built-in laws only).
  * `CLAUDE.md` — Active Development Status update.

**Deliverables:**

  * The example manifest elaborates cleanly.
  * `lex_diff` exercises the minor-bump path.
  * Documentation walkthrough covers each step:
    – author edits `law transfer`;
    – `lex_lint` runs;
    – `lex_diff <old> <new>` produces semantic diff;
    – author supplies refinement proof;
    – PR review proceeds with semantic diff as primary
      artefact.

**Acceptance criteria:**

  * Documentation builds correctly via `mdBook` /
    `pandoc` (or whatever rendering tool the project
    uses; this is a markdown rendering test, not a
    Lean one).
  * The walkthrough's example commands all produce the
    documented output.

**Test files:** `Test/Deployments/UsdClearing.lean`
(new) — 4 cases: manifest elaboration, deployment_id
constancy, manifest_hash determinism, invariant_claims
synthesis.

### LX.23 — Property-test auto-generation (skeleton)

**Files modified:**

  * `Tools/LexCodegen.lean` — extend to optionally emit
    `LegalKernel/Test/Properties/AutoGen.lean` from
    `satisfies` claims.

**Files (new):**

  * `LegalKernel/Test/Properties/AutoGen.lean` — auto-
    generated property tests; one harness call per
    `(law, property)` pair.

**Deliverables:**

  * Auto-generation logic for `conservative` ⇒ random-
    state property test.
  * Auto-generation logic for `monotonic` ⇒ same shape
    with `≥`.
  * Auto-generation logic for `local [{r₁,…}]` ⇒
    pointwise-unchanged-on-other-resources test.
  * Wired into `Tests.lean` as a registered suite (skip-
    able via `CANON_AUTOGEN_SKIP=1`).

**Acceptance criteria (M3 milestone):**

  * Auto-generated tests compile and run.
  * For each kernel-built-in law's claimed properties,
    the auto-generated test passes.
  * `lake exe lex_codegen --check` does not flag the
    auto-generated file (it's regenerable from the
    declarations).

**Test files:** `Test/Properties/AutoGen.lean` is itself
the generated file; its test count depends on the law set
(roughly 17 laws × ~5 properties × 100 samples = ~8500
property invocations, runnable in seconds via the existing
Audit-3.9 harness).

## §20 Test plan

### 20.1 New test suites

The workstream introduces nine new test suites:

  1. `Test.Tools.LexCommon` — registry parsing, JSON
     schema, source-position threading.  ~8 cases.
  2. `Test.DSL.LexLaw` — macro elaboration, grammar
     enforcement, calculus enforcement, `signed_by` /
     `authorized_by` semantics, events block.  ~50 cases.
  3. `Test.DSL.LexProperty` — synthesizers (positive +
     negative per property).  ~40 cases.
  4. `Test.Tools.LexCodegen` — codegen renderers,
     fence-respecting append, `--check` mode.  ~10 cases.
  5. `Test.Laws.ExampleLex` — the M1 acceptance law's
     properties.  ~8 cases.
  6. `Test.DSL.LexDeployment` — manifest elaboration,
     `deployment_id` validation, manifest-hash
     determinism, invariant-claim synthesis.  ~14 cases.
  7. `Test.Tools.LexDiff` — per-clause / per-manifest
     semantic diff, version-bump classification,
     refinement-proof obligation.  ~10 cases.
  8. `Test.Tools.LexFormat` — pretty-printer
     idempotency, clause-order canonicalisation, comment
     preservation.  ~8 cases.
  9. `Test.Deployments.UsdClearing` — example-manifest
     end-to-end checks.  ~4 cases.

Total new tests: ~152.  Plus per-existing-law
classification-instance tests in the LX.2 extension to
`Test.ConservationTests` (~17 cases).

The post-LX test count is approximately:

  * Pre-LX: 1228 (post-LP).
  * After LX.1 – LX.11 (M1): 1228 + ~120 = ~1348.
  * After LX.12 – LX.17 (M2): unchanged at ~1348 (M2
    re-expression preserves byte-identity).
  * After LX.18 – LX.23 (M3): ~1348 + ~50 = ~1398.

Plus the auto-generated property suite (LX.23) which can
expand the suite count significantly, but is gated
behind a `CANON_AUTOGEN_SKIP` flag for fast CI.

### 20.2 Property-based tests (Audit-3.9 harness)

The `LegalKernel/Test/Property.lean` harness is reused
for the Lex auto-generation work in LX.23.  Three first-
wave properties go in for the LX.23 acceptance:

  * `lex_macro_idempotency_property` — re-elaborating a
    Lex law produces byte-identical codegen-input
    output.
  * `lex_codegen_determinism_property` — running
    `lex_codegen` twice on the same input produces
    byte-identical output.
  * `lex_diff_reformatting_invariance_property` — diff
    of a file against `lex_format <file>` is empty.

Each runs at the default 100-sample iteration count
overrideable via `CANON_PROPERTY_ITERATIONS`.

### 20.3 Integration tests (M2 milestone gate)

LX.17's M2 acceptance is gated on a comprehensive
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

LX.22's M3 acceptance is gated on:

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
remains compiling throughout LX.  In M2 (LX.17), it is
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
*additive* typeclass instances landed in LX.2.  No theorem
signature changes.

In M2, the modules under `LegalKernel/Laws/` lose their
hand-written `Transition` definitions in favour of the Lex
declarations, but every theorem signature is preserved
(the Lex-emitted instances have the same type signatures
as the pre-M2 hand-written instances).  Downstream
consumers see no API drift.

### 21.3 On-disk log format

The frozen action indices 0..16 are unchanged.  Pre-M2 logs
decode unchanged under the post-M2 build.  Post-LX example
laws (LX.11 onward) inhabit fresh indices ≥ 17, so they
don't alias any historical log entry.

### 21.4 ABI stability

The CBE encoder for each existing constructor produces
byte-identical output before and after M2.  This is the
M2 strict-equivalence invariant (§2.5) made
mechanically-checkable.

The runtime `canon` binary's CLI surface is unchanged; the
same subcommands work, the same input formats are
accepted, the same output is produced.

### 21.5 Build-tag bump

`LegalKernel.lean`'s `kernelBuildTag` constant is bumped:

  * After M1 lands: `"canon-lex-m1-additive"`.
  * After M2 lands: `"canon-lex-m2-canonical"`.
  * After M3 lands: `"canon-lex-m3-manifests"`.

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
     §14.5).  V1 uses `CANON_PROPERTY_SEED` env var
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
    JSON file to `LegalKernel/_lex_inputs/`.  At 50+ laws
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
    (gated by `CANON_AUTOGEN_SKIP`); default-on in v2.
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

### 24.1 M1 acceptance (LX.1 – LX.11)

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
      `LegalKernel/Laws/ExampleLex.lean`'s declaration
      compiles, its classification instances resolve, and
      its end-to-end test passes.
  11. **Phase-4 `Law.mk` continues to function** (not yet
      deprecated in M1).
  12. **Documentation updated.**  CLAUDE.md's "Active
      development status" names M1 as complete; the
      source-layout listing reflects the new modules; the
      type-level properties table gains LX entries; the
      `kernelBuildTag` literal is bumped to
      `"canon-lex-m1-additive"`.

### 24.2 M2 acceptance (LX.12 – LX.17)

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
      `"canon-lex-m2-canonical"`.

### 24.3 M3 acceptance (LX.18 – LX.23)

In addition to all M1 + M2 criteria:

  20. **Manifest macro lands.**
      `LegalKernel/DSL/LexDeployment.lean` exports the
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
      `Tools/LexCodegen.lean` can emit
      `LegalKernel/Test/Properties/AutoGen.lean`; the
      generated tests pass when run.
  24. **Amendment workflow walkthrough documented.**
      `docs/lex_amendment_walkthrough.md` is checked in
      and renders correctly.
  25. **Documentation updated.**  CLAUDE.md's "Active
      development status" names M3 as complete; the
      `kernelBuildTag` literal is bumped to
      `"canon-lex-m3-manifests"`.

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

  * **Workstream LP.**  `docs/actor_scoped_policies_plan.md`
    introduces per-actor `LocalPolicy` filters at the
    admissibility layer.  LX does not interact with LP at
    the type level; both compose via the existing
    `AdmissibleWith` predicate.  See §23.9.

  * **Workstream PA.**  `docs/parameterized_laws_plan.md`
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
    `LegalKernel/Test/Property.lean` is reused for LX.23's
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
  * **CBE** — Canon Binary Encoding.  The strictly-
    canonical fixed-width binary form Canon uses for
    on-wire serialisation, deviating from RFC 8949
    canonical CBOR for proof tractability (Phase 4).
  * **Codegen-input file** — `LegalKernel/_lex_inputs/
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
    `LegalKernel/DSL/LexProperty.lean` that takes a
    parsed `impl` calculus and a property name, and
    emits a Lean `instance` body discharging the
    property.
  * **Registry** — `lex_index_registry.txt`, the
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

import LegalKernel.DSL.LexLaw
import LegalKernel.DSL.LexProperty
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


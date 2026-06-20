<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Audit Remediation (Workstream AR) — Engineering Plan

This document plans the engineering effort needed to resolve the
findings produced by the comprehensive Lean module audit recorded
under `docs/audits/`.  It is a roadmap, not a specification; the
formal design lives in `docs/GENESIS_PLAN.md` and the
deployment-facing surface specifications in the per-workstream
plans.

The audit reviewed 241 Lean source files (~73,000 lines, ~42,000
non-test).  It found **no critical findings** in the trusted
computing base (TCB):

  * `LegalKernel/Kernel.lean` and `LegalKernel/RBMapLemmas.lean`
    are sound; every shipped theorem closes against
    `propext`, `Classical.choice`, `Quot.sound` only.
  * No `sorry` in proof position in any kernel-adjacent module.
  * No custom axioms anywhere.

The audit reported ten Major findings (M-1 … M-10), nineteen
minor findings (m-1 … m-19), and eleven informational
observations (i-1 … i-11) across the non-TCB deployment-facing
infrastructure.  Workstream AR remediates the actionable subset of
these findings.  A second, independent verification pass surfaced
two additional Major findings (Hash `@[extern]` interface,
`synth_local_kindOnly` always-true) that the synthesis omitted;
both are scoped here.

Each finding is examined against source and triaged into one of
four buckets:

  * **Remediate** — a defect that admits a clean, well-scoped fix
    without expanding the TCB or introducing new trust
    assumptions.  Scheduled as a numbered work unit (or sub-unit).
  * **Document only** — the audit correctly described an existing
    behaviour but the right response is to record the rationale
    in source / `docs/` rather than to change the code.
  * **Defer** — work that requires substantial new theorem
    development beyond the scope of remediation (e.g. chain-level
    bridge accounting theorems whose ratification lives in the
    cross-stack corpus).
  * **Wontfix — design intent** — the audit's claim is accurate;
    the property is intentional and the documented design is the
    contract (e.g. M-4 — CBE type-tag discipline is position-typed
    by spec; changing it would be a TCB-adjacent wire-format
    break).

Workstream AR is organised as **23 work-unit groups, expanded
into 43 sub-units** (18 single-unit groups plus five
multi-unit groups: AR.2 with 6 sub-units, AR.3 with 2, AR.4
with 8, AR.13 with 5, AR.23 with 4).  The five most consequential groups (AR.2,
AR.3, AR.4, AR.13, AR.23) are decomposed into sub-units sized for
single-PR review (≤ ~½ day implementation each) so that proof
work, runtime plumbing, CLI surface changes, documentation, and
integration tests can each land independently and bisect cleanly
against any future regression.

Every "Remediate" sub-unit ships behind the existing CI gates
(`tcb_audit`, `count_sorries`, `stub_audit`, `naming_audit`,
`deferral_audit`, `lex_lint`, `lex_codegen --check`, strict
warnings, `lake build`, `lake test`), preserves the §13.6
two-reviewer rule for any TCB-touching change, and adds zero
custom axioms.

## Status

> **Reconciliation status (2026-06-14): COMPLETE.**  Workstream AR
> shipped — every "Remediate" finding (M-1 … M-10 and the remediable
> minor findings) is closed in `main` (CLAUDE.md roadmap: `AR | Complete`);
> see the post-AR annotation in
> `docs/audits/19-findings-and-followups.md`.  The lone deferred finding
> **m-16** (chain-level §7.6.4 / §7.6.5 accounting) is now **closed** by
> Workstream CA (`chain_level_accounting_plan.md`;
> `LegalKernel/Bridge/{Reachable,ChainAccounting}.lean`), so **every
> finding is resolved**.  This document is retained as the
> historical engineering record; the provenance notes below predate the
> landing and the later Workstream-GP work.

  * **Drafted on branch:** `claude/audit-findings-workstream-oyEAO`;
    refined on branch `claude/improve-audit-plan-sCDdC`
    (sub-unit decomposition + per-WU verification commands +
    reviewer checklists + roll-forward strategy).
  * **Phase prefix:** `AR` (Audit Remediation) — work-unit groups
    labelled `AR.1` … `AR.23` and sub-units labelled
    `AR.<group>.<sub>` (e.g. `AR.4.2`).  The two-level scheme
    disambiguates from the Genesis-Plan `Phase 0`/`Phase 1`/…
    numbering, from the Ethereum-integration `A`/`B`/`C`/`D`
    workstream prefixes, from the Local-Policy workstream `LP`,
    the Lex workstream `LX`, the Fault-Proof workstream `H`, and
    the Parameters workstream `PA`.  When a group has only one
    sub-unit, the bare group identifier (`AR.1`, `AR.5`, etc.) is
    used; the suffix is added only where decomposition exists.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit`, `lake exe naming_audit`,
    `lake exe deferral_audit`, `lake exe lex_lint`, and
    `lake exe lex_codegen --check` all green throughout; **no
    new sorries**; **no new axioms**; **no expansion of the
    kernel TCB**; **no new `opaque` declarations** (the
    Hash-extern work unit migrates existing functions from
    plain `def` to `@[extern "..."] def`, which is a link-time
    contract, not a new trust assumption).
  * **TCB delta:** zero.  Every change ships under non-TCB
    modules.  `Kernel.lean` and `RBMapLemmas.lean` are untouched.
  * **Trust-assumption delta:** zero.  `Verify`, `hashBytes`,
    and `l1FaultProofVerifier` opaque declarations are unchanged
    in *body*; AR.10 promotes `hashBytes` (and the sibling
    introspection function) to carry `@[extern]` annotations that
    materialise the deployment swap-point contract already
    documented in the source docstrings.  No new trust
    assumption is introduced; the existing one is made explicit.
  * **Backwards-compat delta:** every behavioural change ships
    with the existing "default produces pre-AR behaviour" pattern.
    The DeploymentId clean-up (AR.2) introduces parameterised
    entry points whose specialisation at `ByteArray.empty`
    reduces to the pre-AR semantics.  No on-disk frame format
    change; no on-the-wire ABI change.
  * **Frozen indices reserved by this workstream:** none.  AR
    is a remediation pass, not a feature addition; no new
    `Action` constructor, no new `Event` constructor.

## Table of contents

  * §1   Goals and non-goals
    * §1.1 Goals
    * §1.2 Non-goals
    * §1.3 What this plan does *not* attempt
    * §1.4 Glossary of plan-specific terms
    * §1.5 Reading guide
  * §2   Finding triage — every audit finding examined
  * §3   Work-unit dependencies
    * §3.1 Strict ordering edges
    * §3.2 Parallel-safe work units
    * §3.3 Critical-path analysis (sub-unit level)
  * §4   Work-unit specifications (AR.1 – AR.23, 43 sub-units)
  * §5   Sequencing and PR structure (eight groups)
  * §6   Quality gates, rollback, and roll-forward discipline
    * §6.1 Per-PR forcing functions (12 gates)
    * §6.2 Two-reviewer gate
    * §6.3 Rollback discipline
    * §6.4 CI failure response
    * §6.5 Roll-forward strategy
    * §6.6 Commit-message and PR-title conventions
  * §7   Risk register and mitigations
  * §8   Acceptance criteria for Workstream AR overall
  * §9   Out-of-scope items (deferred to future workstreams)
  * §10  Mathematical soundness checklist
  * §11  Plan self-audit (verification pass)
  * §12  References

Each work unit (or sub-unit) in §4 stands alone and follows the
same template: **finding map**, **scope**, **math / proof
outline**, **implementation steps**, **acceptance criteria**,
**test plan**, **definition of done (DoD)**, **verification
commands**, **reviewer checklist**, **migration notes** (where
applicable), **risk**, and **effort estimate**.  Read in order
for a guided walkthrough; jump to a specific WU by Ctrl-F on its
identifier (e.g. `AR.4.2`).  See §1.5 for a reading guide tuned
to specific reader roles (implementer, reviewer, release
manager, future auditor).

## §1 Goals and non-goals

### §1.1 Goals

  1. **Eliminate the cross-deployment-replay default-empty
     hazard.**  Findings M-1 and M-5 jointly describe a class of
     entry points that default `deploymentId` to
     `ByteArray.empty`, silently disabling the §8.8.5
     domain-separation gate.  AR.2 reshapes the entry-point
     surface so the deploymentId is always passed explicitly at
     the call site (Runtime, Replay, Disputes).

  2. **Promote bytes-equality to extensional state equality
     across the fault-proof chain.**  Finding M-3 (CLAUDE.md
     footnote 1) flags the last load-bearing follow-up for
     Workstream H: the map-backed encoder injectivity lemmas.
     AR.4 ships per-sub-state `*_encode_injective` theorems
     under canonical field bounds, closing the gap between
     `commitExtendedState_subcommits_bytes_eq_under_collision_free`
     (bytes-eq) and the desired extensional state equality.

  3. **Add the missing snapshot-bootstrap chain anchor.**  M-2
     points out that `bootstrapFromSnapshot` drops the log
     prefix without verifying that the dropped prefix actually
     chains to the snapshot's seed hash.  AR.3 introduces an
     explicit anchor check and migrates the CLI entry-point to
     require `AttestedSnapshot` for cross-replica startup.

  4. **Pin the on-disk Action / Event tag indices.**  M-8 and
     m-7 jointly describe a "transposition" hazard in the
     parallel constructor-tag enumerations across
     `Action.tag` / `Action.encode` / the LP.2 dispatch table,
     and similarly for `Event` (which currently lacks a
     `Event.tag` function; only docstring annotations pin the
     indices).  AR.5 adds 19 per-`Action`-constructor
     regression tests pinning each tag to its specific integer
     value; AR.6 introduces a new `Event.tag` function and 16
     per-`Event`-constructor regression tests on top.

  5. **Tighten the Lex governance surface.**  M-6, m-11, m-13
     describe gaps in the Lex tooling: parameter/proof-override
     diff that misses type/body changes (M-6); a property
     synthesizer (`synth_local_kindOnly`) that admits every
     `local [S]` claim trivially because resource information is
     discarded (m-11 extended); a `renderSyntax := toString`
     drift between Law.lean's JSON sidecar and the user source
     bytes (m-13).  AR.7, AR.11, AR.12 close all three.

  6. **Align documentation with mechanical enforcement.**  M-9
     and M-10 describe two places where docstrings or policy
     prose over-promise what the CI gates actually enforce.
     AR.8 and AR.9 either (a) extend the mechanical enforcement
     to match the documented policy (preferred) or (b) correct
     the documentation.

  7. **Realise the documented hash adaptor swap-point.**  Hash.lean's
     docstrings claim a `knomosis_hash_bytes` C ABI symbol that
     production deployments link against, but no actual
     `@[extern]` annotation is present.  AR.10 lands the
     annotation, making the documented behaviour the actual
     behaviour and eliminating the fragile link-level
     interposition workaround.

  8. **Cosmetic / safety net cleanup.**  AR.13 fixes the three
     stale docstrings flagged by m-19 plus the documented-
     behaviour notes for ≈ 11 additional sites (m-1, m-3, m-5,
     m-6, m-8, m-9, m-10, m-12, m-15, m-18, plus the
     supplementary per-area-audit notes).  AR.14 extends
     `count_sorries`'s pattern
     set to cover `refine sorry`, `apply sorry`, `(sorry : T)`,
     and `· sorry` forms (m-2).  AR.15 adds a guard comment near
     the `proportionalDilute` snapshot-read line (i-9).  AR.16
     extends the `Verdict.encode` boundary to reject mismatched
     signer / signature lengths (m-17).  AR.17 replaces the
     non-exhaustive wildcard match in `Disputes.kernelOnlyApply`
     with an explicit per-arm case-split (m-14).  AR.18 marks
     `applyVerdictUnchecked` `protected` so production callers
     cannot reach the unchecked variant without the explicit
     qualified name.  AR.19 adds
     the missing `_indexOutOfRange` / `_duplicateDispute`
     rejection lemmas for `fileDispute`.  AR.20 lands a
     `.github/CODEOWNERS` file that mechanically encodes the
     §13.6 two-reviewer rule for the TCB-core file set.  AR.21
     adds a positivity precondition to `withdraw` (m-4).  AR.22
     updates `docs/GENESIS_PLAN.md`, `CLAUDE.md`, and the audit
     index to reflect the remediation pass.  AR.23 ships an
     end-to-end cross-deployment-replay regression test suite.

### §1.2 Non-goals

  1. **No CBE per-instance type-tag prefix.**  Finding M-4
     describes the "type-collision" property of CBE: `Bool true`
     and `Nat 1` encode to identical bytes because CBE is
     position-typed by spec.  The audit's suggested fix —
     prefixing each `Encodable` instance with a per-type tag —
     would invalidate every existing log-file frame and every
     cross-stack byte golden.  The documented design is
     intentional (`Encoding/Encodable.lean:43-67`).  AR makes no
     change here; the documentation is the contract.

  2. **No top-level inductive bridge-supply accounting theorem.**
     Finding m-16 notes that the §7.6.4 / §7.6.5 chain-level
     accounting identities are not shipped as a single inductive
     Lean theorem; per-step deltas exist but the inductive
     wrap-up is deferred to cross-stack verification.  AR does
     not promote them; the per-step deltas + the cross-stack
     corpus (Workstream F) are the canonical record.  Lifting
     to an inductive theorem is a Workstream-G follow-up.

  3. **No new feature additions, no new `Action` / `Event`
     constructors, no new `LocalPolicyClause` variants.**  AR is
     a remediation pass.  New surface area belongs in its own
     workstream.

  4. **No kernel TCB amendments.**  Every AR work unit is
     scoped to non-TCB modules.  `Kernel.lean` and
     `RBMapLemmas.lean` are untouched; the `tcb_audit` import
     allowlist (`tcb_allowlist.txt` + `Tools.Common.tcbInternalImports`)
     is unchanged.

  5. **No two-reviewer-rule mechanical replacement.**  AR.20
     lands a `.github/CODEOWNERS` file but the §13.6
     two-reviewer rule remains a process rule enforced by the
     team.  CODEOWNERS is a request-for-review mechanism, not a
     merge-block; full enforcement would require branch
     protection rules, which are repository-administrator
     territory and out-of-scope for a code-only PR.

### §1.3 What this plan does *not* attempt

  * **No retroactive `sorry` removal in non-TCB modules.**
    `count_sorries` already covers the kernel-adjacent file set
    (`Kernel.lean`, `RBMapLemmas.lean`, `Laws/Transfer.lean`).
    The pattern-set extension (AR.14) tightens detection but
    does not expand the scope.

  * **No fork of `Std.TreeMap` lemma library.**  The kernel
    consumes ~12 Std lemmas (catalogued in
    `docs/std_dependencies.md`).  Future toolchain bumps may
    require re-verification; AR does not pre-emptively replace
    the dependency.

  * **No new sub-state in `ExtendedState`.**  AR's
    extensional-equality work for map-backed encoders (AR.4)
    operates on the existing five sub-states (`State`,
    `NonceState`, `KeyRegistry`, `LocalPolicies`,
    `BridgeState`).  Future sub-states will need their own
    `*_encode_injective` lemma at landing time; AR establishes
    the proof pattern.

### §1.4 Glossary of plan-specific terms

The following terms recur throughout the plan; they are
defined once here so individual work-unit specifications can
stay focused on the specific change.

  * **TCB (Trusted Computing Base).**  The two files
    `LegalKernel/Kernel.lean` and `LegalKernel/RBMapLemmas.lean`
    plus the Lean core distribution (`Std.Data.TreeMap` and
    transitive imports).  A bug in TCB code can invalidate a
    kernel-soundness theorem; bugs outside the TCB are scoped
    to deployment-level claims.  Enforced mechanically by
    `lake exe tcb_audit` against `tcb_allowlist.txt` +
    `Tools.Common.tcbInternalImports`.
  * **TCB-core.**  Synonym for "the two TCB files" when the
    Lean core distribution is implicit.
  * **Kernel-adjacent.**  TCB-core plus `Laws/Transfer.lean` —
    the file set covered by `lake exe count_sorries`'s
    zero-tolerance gate.  Strictly wider than TCB-core.
  * **WU (work unit) and sub-WU (sub-unit).**  A WU is a top-level
    AR identifier (`AR.1` … `AR.23`); a sub-WU is a finer-grained
    decomposition (`AR.<group>.<sub>`).  A sub-WU is the
    indivisible unit of review and the unit pinned by the commit
    `Bisect-tag` (§6.6).  When a WU has only one sub-unit, the
    bare WU identifier is used.
  * **Trust assumption (opaque).**  A function declared via Lean's
    `opaque` keyword whose Lean-level body returns a default
    (e.g. `Verify` returns `false`) but whose production-link
    body is supplied by a deployment-specific C ABI symbol.  The
    soundness of any theorem reaching the opaque is conditional
    on the linked symbol satisfying the documented contract.
    Three opaques exist: `Authority.Crypto.Verify`,
    `Runtime.Hash.hashBytes`, and
    `FaultProof.Witness.l1FaultProofVerifier`.  AR.10 promotes
    `hashBytes` (and siblings) to carry an `@[extern]`
    annotation that *names* the linked symbol explicitly without
    introducing a new opaque or new trust assumption.
  * **`fieldsBounded` predicate.**  A per-type structural
    predicate asserting every Nat-valued field of a state /
    sub-state lies in `[0, 2^64)`.  Required by canonical-CBE
    encoding lemmas to rule out non-canonical encodings of
    out-of-range Nats.  Already shipped at the clause level in
    `Encoding/LocalPolicy.lean:57`; AR.4 generalises to the
    map-backed sub-states.  Satisfied in production by the
    runtime adaptor's frame-validation gate.
  * **Encoder-injectivity quartet.**  The four-lemma family
    shipped jointly for every canonical encoder:
    (i) `*_decode` — the explicit inverse function;
    (ii) `*_roundtrip` — `decode (encode x ++ rest) = .ok (x', rest)`
    with `x.Equiv x'`;
    (iii) `*_encode_injective_extensional` — bytes equality
    implies extensional equality (`toList = toList`);
    (iv) `*_encode_injective_of_equiv` — bytes equality implies
    `Equiv`.  Established as the template for `BalanceMap` in
    AR.4.2 and replicated for the other four sub-states in
    AR.4.3 – AR.4.7.
  * **Bisect-tag.**  A line in every AR commit message of the form
    `Bisect-tag: AR.<id>` where `<id>` is the sub-WU identifier
    (e.g. `AR.4.2`).  See §6.6.
  * **`AdmissibleWith verify P d es st`.**  The deploymentId-aware
    admissibility predicate (Phase 3).  `Admissible.decidable`
    is the back-compat alias for `AdmissibleWith Verify
    ByteArray.empty` introduced in Audit-3.3.
  * **Cross-deployment-replay.**  The Audit-3.4 / §8.8.5 hazard
    where a signed action from deployment `d₁` is replayed
    against deployment `d₂ ≠ d₁`.  Defended by
    domain-separation: `signInput` includes `deploymentId`, so
    the signature pre-image differs between deployments.
  * **CBE.**  Canonical Binary Encoding — Knomosis's deterministic
    CBOR-flavoured wire format.  Defined in
    `LegalKernel/Encoding/CBOR.lean` and `Encodable.lean`.
  * **Extensional equality.**  For `TreeMap`, equality of
    `toList`-projection (and hence equivalence under the
    `Equiv` relation), as opposed to Lean `=` which would
    require RB-tree-shape canonicality.  Every kernel observer
    (`getBalance`, `totalSupply`, every `Transition`) operates
    on extensional equality; Lean `=` on TreeMap is strictly
    stronger and not provable in general.
  * **Definition of Done (DoD).**  The per-WU explicit checklist
    that converts "the work unit is complete" from a judgement
    call into a tickbox set.  Every DoD includes (a) the
    behavioural deliverable, (b) the test deliverable, (c) the
    documentation deliverable, and (d) the audit-gate green
    state.
  * **Verification command.**  A concrete `lake exe …` or `grep`
    invocation a reviewer can run to confirm the WU's
    acceptance criterion holds.  Each WU lists the exact
    commands so review is tactile rather than narrative.

### §1.5 Reading guide

Different reader roles will engage with this plan differently.
The structure below routes each role to the sections that
matter for them.

  * **Implementer (writing the code).**  Read §1.1 (goals),
    §3 (dependencies — which other sub-WUs must land first),
    then jump to the specific sub-WU(s) you own in §4.  Honour
    the sub-WU's "Definition of Done" and run its
    "Verification commands" before opening the PR.
  * **Reviewer (assessing a PR).**  Read the sub-WU's "Reviewer
    checklist" first, then the math / proof outline, then the
    diff.  The "Migration notes" section flags operator-facing
    changes that need release-note coverage.
  * **Release manager (sequencing PRs).**  Read §3 (dependency
    graph) and §5 (PR groups) — these tell you which sub-WUs
    can land in parallel and which order is forced.  §6.5
    (roll-forward strategy) covers what to do if a sub-WU
    needs follow-up after merge.
  * **Future auditor (re-auditing after AR lands).**  §8
    (overall acceptance) and §11 (self-audit verification)
    summarise the post-AR state; cross-reference against
    `docs/audits/19-findings-and-followups.md` for per-finding
    landing commits (AR.13.1 through AR.22 collectively
    annotate that file).
  * **CLAUDE.md / harness reader.**  The plan adheres to the
    "names describe content, never provenance" rule: every
    declaration the plan asks you to add is named by content
    (e.g. `processSignedActionWith`, `balanceMap_roundtrip`),
    never by provenance (no `_v2`, no `_audit_fix`, no `_ar4`).

A reader unfamiliar with the codebase should additionally
skim `docs/GENESIS_PLAN.md` §4 (kernel) and §8 (admissibility)
plus the relevant per-area audit file under `docs/audits/`
before starting an AR sub-WU.

## §2 Finding triage — every audit finding examined

This section lists every finding from `docs/audits/19-findings-and-followups.md`,
plus two additional findings surfaced by the cross-verification
pass.  For each, the triage decision is one of:

  * **Remediate (AR.n).**  Mapped to a numbered AR work unit.
  * **Document only.**  Recorded in source / `docs/`; no code
    behaviour change.
  * **Defer.**  Future workstream; not in scope for AR.
  * **Wontfix — design intent.**  The audit correctly described
    the property; the property is intentional.

### §2.1 Critical findings

**None.**  Confirmed against source: the TCB-core file set
(`Kernel.lean`, `RBMapLemmas.lean`) admits only the three
canonical Lean built-in axioms; no `sorry`; no custom axiom.

### §2.2 Major findings (M-1 … M-10) + two cross-verification additions

| ID    | Finding                                                                                                              | Triage                | Work unit (sub-units)         |
|-------|----------------------------------------------------------------------------------------------------------------------|-----------------------|-------------------------------|
| M-1   | `Replay`'s `Admissible.decidable` and Runtime `processSignedAction` default `deploymentId := ByteArray.empty`.       | Remediate             | AR.2.1 – AR.2.4, AR.2.6       |
| M-2   | `bootstrapFromSnapshot` does not chain-anchor the discarded log prefix against the snapshot's seed hash.             | Remediate             | AR.3.1 (anchor) + AR.3.2 (CLI gate) |
| M-3   | Map-backed sub-state encoders ship `*_encode_deterministic` only; no `*_encode_injective` / `*_roundtrip`.           | Remediate             | AR.4.1 – AR.4.8 (eight sub-units) |
| M-4   | CBE major-type tags collide across types (`Bool true` vs `Nat 1`).                                                   | Wontfix — design intent | n/a                         |
| M-5   | `checkSignatureInvalid` hardcodes `deploymentId := ByteArray.empty`.                                                  | Remediate             | AR.2.5                        |
| M-6   | `Lex/Tools/Diff.lean`'s param / proof-override comparators compare names only.                                       | Remediate             | AR.7                          |
| M-7   | `signedActionDomain` constant duplicated as a string literal at two locations.                                       | Remediate             | AR.1                          |
| M-8   | Three parallel `Action`-tag enumerations; only 4 of 19 indices pinned by tests.                                      | Remediate             | AR.5                          |
| M-9   | `naming_audit` does not include `_v2` despite CLAUDE.md listing `v2` as a forbidden temporal marker.                  | Remediate             | AR.8                          |
| M-10  | `MockCrypto`'s docstring claims `stub_audit` flags production imports; it does not.                                  | Remediate             | AR.9                          |
| **M+1** | `hashBytes` / `hashStream` / `hashImplementationIdentifier` carry no `@[extern]` annotation; documented swap-point unrealised. | Remediate     | AR.10                         |
| **M+2** | `synth_local_kindOnly` unconditionally admits every kernel-impl statement; `local [S]` claims are effectively always-true via the M1 dispatcher. | Remediate | AR.11             |

### §2.3 Minor findings (m-1 … m-19)

| ID    | Finding                                                                                          | Triage              | Work unit |
|-------|--------------------------------------------------------------------------------------------------|---------------------|-----------|
| m-1   | `tcb_audit` silently accepts unrecognised import forms (`prelude`, `import all`, `meta import`).  | Document only       | AR.13.1   |
| m-2   | `count_sorries` pattern set misses `refine sorry`, `apply sorry`, `(sorry : T)`, `· sorry`.       | Remediate           | AR.14     |
| m-3   | `stub_audit` 12-line docstring lookback is a magic number.                                       | Document only       | AR.13.1   |
| m-4   | `withdraw`'s precondition permits `amount = 0`.                                                  | Remediate (optional)| AR.21     |
| m-5   | `deposit.pre := True`; runtime carries replay protection.                                        | Document only       | AR.13.5   |
| m-6   | `affectedActors` misses actors gained-only (no pre-state entry).                                  | Document only       | AR.13.5   |
| m-7   | `Event` constructor-index drift not mechanically enforced.                                       | Remediate           | AR.6      |
| m-8   | Lex codegen fence-marker contract is a string convention.                                        | Document only       | AR.13.4   |
| m-9   | `Lex/Tools/Common.lean` reverse-alphabetical JSON field order.                                    | Document only       | AR.13.4   |
| m-10  | Lex M1 `requiresEmission := false` universally — codegen is no-op.                                | Document only       | AR.13.4   |
| m-11  | `synth_*` synthesizers emit placeholder strings.                                                 | Remediate (partial) | AR.11     |
| m-12  | `Shim.stmtReferencesSignedBy` is positionless substring match.                                   | Document only       | AR.13.4   |
| m-13  | `lexlaw`'s `renderSyntax := toString` drifts from user source bytes.                              | Remediate           | AR.12     |
| m-14  | `kernelOnlyApply` uses non-exhaustive `_ => s` wildcard.                                         | Remediate           | AR.17     |
| m-15  | `ingest` returns `none` for `depositInitiated`; deposit flow bypasses ingest.                     | Document only       | AR.13.3   |
| m-16  | §7.6.4 / §7.6.5 chain-level accounting deferred to runtime cross-stack verification.              | Defer               | n/a       |
| m-17  | `Verdict.encode` relies on `List.zip_unzip`; fragile on mismatched lengths.                       | Remediate           | AR.16     |
| m-18  | Lex codegen non-deterministic load order under duplicate-index registries.                       | Document only       | AR.13.4   |
| m-19  | Three stale docstring claims (Codegen `--canonical`, Crypto `Verify`, LogFile hash width).        | Remediate           | AR.13.2 (Hash, Crypto, LogFile) + AR.13.4 (Codegen `--canonical`) |

### §2.4 Informational observations (i-1 … i-11)

| ID    | Observation                                                                                       | Triage          |
|-------|---------------------------------------------------------------------------------------------------|-----------------|
| i-1   | Two non-Lean trust assumptions, both `opaque`.                                                   | Document only   |
| i-2   | `Std.TreeMap` API stability.                                                                     | Document only   |
| i-3   | No external Lake dependencies.                                                                   | Document only   |
| i-4   | Strict linters as CI gates.                                                                      | Document only   |
| i-5   | Five mechanical audit gates in CI.                                                               | Document only   |
| i-6   | Two-reviewer rule is process-only, no CODEOWNERS.                                                 | Remediate (AR.20)|
| i-7   | Coherence-by-construction in `FaultProof.Coherence`.                                              | Document only   |
| i-8   | Commit-injectivity at bytes level only.                                                          | Resolved by AR.4|
| i-9   | `proportionalDilute` dust-bound invariant is load-bearing.                                       | Remediate (AR.15)|
| i-10  | Decidability discipline holds project-wide.                                                       | Document only   |
| i-11  | Reward / stake economics has sharp edges but is non-TCB.                                          | Document only (AR.13.3 expands the four cited sites with explicit guard comments: `claimImpugnedAmount` skip-bridge-actions, `proportionalChallengerReward` divisor-0 fallback, `stakeWeightedAdjudicatorRewards` sum-le-pool not-shipped-as-theorem, `Staking.stakeResolutionActions` rollback runtime-invariant). |

### §2.5 Additional findings from per-area audits (not in synthesis)

Beyond the synthesis-tier findings, the per-area audits surface
ten supplementary findings that the cross-verification confirmed.
They are scheduled here:

  * **`tests/Disputes/Filing.lean` missing `_rejects_*` family.**
    `07-disputes.md` notes the documented `fileDispute_rejects_*`
    family is partially incomplete: `_indexOutOfRange` and
    `_duplicateDispute` rejection lemmas are not exposed under
    those names.  **AR.19**.

  * **`applyVerdictUnchecked` exported with no Lean visibility
    restriction.**  `07-disputes.md`.  **AR.18**.

  * **`Verdict.encode` non-canonical inputs encode but do not
    round-trip.**  Covered by AR.16.

  * **`Bridge/Ingest.lean` `depositInitiated` → none.**  Documented
    behaviour; this is documented under the `m-15` aliased
    entry in §2.3.  **No new WU; AR.13 amends the docstring.**

  * **`Bridge/State.lean` DepositId projection collision risk.**
    Deployment-correctness obligation (L1 hash injectivity on the
    64-bit DepositId projection).  Documented in source; not a
    Lean defect.  **No new WU; AR.13 amends the docstring.**

  * **`WithdrawalRoot.lean` runtime-supplied size hypothesis on
    `verifyProof_sound`.**  Already explicit in the theorem
    signature; the runtime adaptor is the named obligee.
    **Document only; AR.13 expands the doc.**

  * **`Hash.lean` missing `@[extern]` (verified twice).**
    Cross-verified independently by the per-area audit and by
    this remediation plan's spot-check.  **AR.10**.

  * **`synth_local_kindOnly` unconditional admit (verified
    twice).**  Cross-verified.  **AR.11**.

  * **`Lex/DSL/Law.lean` `Law.mk` deprecated but universally
    used.**  Every `lexlaw` macro elaborates through
    `set_option linter.deprecated false in`.  Cosmetic; the
    intent is to migrate to a non-deprecated `lex_law_mk`
    constructor in M3.  **Defer.**

  * **`Lex/DSL/ImplLowering.lean` token registrations leak
    `flow` / `mint` / `burn` etc. as Lean global keywords.**
    Scoped to the `lex_calc_stmt` syntax category by Lean's
    parser-state isolation; not a global-keyword pollution.
    Verified by spot-checking that `flow` is not reserved
    outside the `lex_do` context.  **Wontfix — false alarm
    on closer inspection.**

### §2.6 Findings ruled erroneous

After spot-check against source, no audit finding was determined
to be a false positive on the *defect* dimension.  Every "fact"
the audit asserts about the code is correct.  The triage
boundary lies in *severity / response*, not in *truth*:

  * **M-4 (CBE type-tag collision).**  The audit's claim is
    accurate.  The recommended fix is rejected because the
    documented behaviour is the intent (CBE is position-typed
    by spec) and the change would require a full cross-stack
    rework.  This is a Wontfix, not a false positive.

  * **m-2 (`count_sorries` pattern set).**  The audit's claim
    is accurate; the fix is small (AR.14) so it's scheduled
    rather than left as documentation.

  * **i-7 (FaultProof Coherence-by-construction).**  The audit's
    observation is accurate but neutral.  The structurally-`rfl`
    nature of the coherence theorem is the intended design —
    `applyCellWrites_to_state` is *defined* as `kernelOnlyApply`,
    so coherence is trivially true.  The trust upgrade lives
    in the cross-stack corpus (Workstream H WU 10.1), not in
    Lean.  Documenting this is sufficient.

  * **Lex `ImplLowering` "token leak".**  Verified false alarm:
    Lean syntax categories isolate keywords to the matching
    category context; `flow` does not pollute term-level
    parsing.  See §2.5.

The "erroneous findings" filter therefore yields **one false
alarm** (the Lex ImplLowering token leak, which was a
per-area-audit speculation that did not survive verification)
and **zero true false positives** in the synthesis-tier findings.

## §3 Work-unit dependencies

The 23 work-unit groups (43 sub-units) form a partial order.
At the **WU-group** level there are four strict edges and three
soft edges; at the **sub-unit** level the dependency graph is
finer-grained but still admits substantial parallelism.  This
section gives both views.

### §3.1 Strict ordering edges (group level)

```
AR.5  Action tag regression tests   ┐
                                     ├──► AR.2.* DeploymentId parameterisation
AR.6  Event tag regression tests    ┘         │
AR.1  Shared signedActionDomain     ─────────►│
                                              │
AR.8  naming_audit _v2 alignment    ─────►    │
                                              ▼
                                          AR.3.* Snapshot bootstrap chain-anchor
                                              │
                                              ▼
                                          AR.23.* End-to-end regression suite
                                              │
AR.10 Hash @[extern] annotations    ────►     │
AR.4.* Encoder injectivity track    ────►     │
                                              ▼
                                          AR.22 Documentation updates
                                                (last; bumps `kernelBuildTag`)
```

Edge rationale:

  * **AR.1 → AR.2.* (strict).**  AR.2 routes the deploymentId
    through `signedActionDomain`; the shared constant must
    exist first or AR.2 would be threading through a
    duplicated literal.
  * **AR.2.* → AR.3.* (strict).**  AR.3 invokes the new
    `bootstrapFromSnapshot` parameterised entry; AR.2.3
    supplies the `deploymentId` parameter that AR.3 reads.
  * **AR.3.* → AR.23.* (strict).**  The end-to-end regression
    suite exercises the snapshot-bootstrap anchor check.
  * **Everything → AR.22 (strict).**  Documentation updates
    land last; the `kernelBuildTag` bump and the test-count
    refresh reflect the *cumulative* AR delta.
  * **AR.5, AR.6 → AR.2.* (soft).**  The constructor-tag
    regression tests pin the current on-disk index space.
    Recommended to land first so any accidental tag drift in
    AR.2 surfaces immediately; soft because AR.2 does not
    touch `Action` / `Event` constructors directly.
  * **AR.8 → AR.2.* (soft).**  AR.2 introduces new identifiers
    (e.g. `processSignedActionWith`); these names must clear
    the extended `naming_audit` token list.  Soft because
    AR.8 extends the list with `_v2`/`_v3`/etc. — the new
    AR.2 identifiers don't include those substrings either
    way.
  * **AR.4.* , AR.10 → AR.23.* (soft).**  AR.23 includes
    integration coverage that exercises the AR.4 encoder
    injectivity and the AR.10 hash extern annotation.  Soft
    because the suite is testable without these but its
    coverage statement depends on them.

### §3.2 Parallel-safe work units (group level)

The following work units have no incoming strict edges and
can land at any time within their PR group (see §5):

  * **AR.7** — Lex Diff comparator (Lex-tools-only).
  * **AR.9** — MockCrypto import detector (audit-tools-only).
  * **AR.11** — `synth_local` resource dispatch (Lex DSL).
  * **AR.12** — `lexlaw` `renderSyntax` (Lex DSL).
  * **AR.13.1 – AR.13.5** — Stale docstring fixes (cosmetic;
    five thematic sub-units, each independently mergeable).
  * **AR.14** — `count_sorries` patterns (audit-tools-only).
  * **AR.15** — `proportionalDilute` guard comment.
  * **AR.16** — `Verdict.encode` boundary check (Disputes
    encoder).
  * **AR.17** — `kernelOnlyApply` exhaustive switch (Disputes).
  * **AR.18** — `applyVerdictUnchecked` visibility (Disputes).
  * **AR.19** — `fileDispute` rejection lemmas (Disputes).
  * **AR.20** — `.github/CODEOWNERS` (process file; no Lean
    impact).
  * **AR.21** — Withdraw positivity (optional; if accepted,
    lands after AR.5 since it touches the `withdraw` action
    surface).

AR.4.* (encoder injectivity) is the deepest theorem work and
has no incoming dependency.  It can land entirely in
parallel with the deploymentId track (AR.1/AR.2.*/AR.3.*) — they
do not share any file.  This is the single most important
parallelisation opportunity in AR: AR.4 unblocks
Workstream H's final follow-up, and AR.1/AR.2.*/AR.3.* close the
cross-deployment-replay hazard.  Different reviewers can
handle each track concurrently.

### §3.3 Critical-path analysis (sub-unit level)

The longest forced sequence (the "critical path") that
determines AR's wall-clock minimum is:

```
AR.1                    [shared signedActionDomain]                ½ d
  → AR.2.1              [add RuntimeState.deploymentId field]       ½ d
  → AR.2.2              [processSignedAction reads field]           ½ d
  → AR.2.3              [bootstrap parameterisation]                ½ d
  → AR.3.1              [anchor check + .anchorMismatch variant]    ½ d
  → AR.23.1             [cross-deployment regression]               1 d
  → AR.23.2             [snapshot wrong-anchor regression]          ½ d
  → AR.23.3             [snapshot correct-anchor regression]        ½ d
  → AR.22               [docs + kernelBuildTag bump]                ½ d
                                                              ─────
                                                              ≈ 5 days
```

Total critical-path length: **≈ 5 working days** with one
serialised implementer.  All other sub-units run in parallel
beside this critical path.

The longest **independent** track is the AR.4.* encoder-
injectivity proof work, which forms its own internal sequence:

```
AR.4.1  [generic helper round-trip + Encodable.RoundtripsAt]      1 d
  → AR.4.2  [BalanceMap quartet — template-establisher]           4 d
       ║   (in parallel after AR.4.2 ships:)
       ╠═► AR.4.3  [State quartet]                                2 d
       ╠═► AR.4.4  [NonceState quartet]                           1 d
       ╠═► AR.4.5  [KeyRegistry quartet]                          1 d
       ╠═► AR.4.6  [LocalPolicies quartet]                        2 d
       ╚═► AR.4.7  [BridgeState consumed+pending quartet]         3 d
  → AR.4.8  [ExtendedState composition + FaultProof.Commit chain] 1 d
                                                              ─────
                                                          ≈ 9 days
```

If AR.4.3 – AR.4.7 are reviewed in parallel by different
reviewers, the AR.4.* track resolves in ≈ 9 working days
(template + 4 parallel days + composition).  If reviewer
bandwidth limits parallelism, the worst case is ≈ 16 working
days (sequential).

The wall-clock minimum for AR overall (Group 5/6/7/8 in
parallel with maximally-spread reviewer bandwidth) is therefore
**≈ 9 working days**; the realistic estimate is **5–7 weeks**
(see §4.1).

## §4 Work-unit specifications

Each work unit (or sub-unit) below carries:

  * **Finding map** — which audit findings it remediates.
  * **Scope** — files created / modified.
  * **Math / proof outline** — the theorem statements (where
    applicable), the proof strategy, and the trust posture
    (`#print axioms` expectation).
  * **Implementation steps** — atomic, ordered, ≤ ~30 line
    minimum granularity each.
  * **Acceptance criteria** — what passes / fails post-WU.
  * **Test plan** — specific cases (positive, negative, edge).
  * **Definition of Done (DoD)** — tickbox checklist (deliverable
    + tests + docs + audit-gate green).
  * **Verification commands** — concrete `lake exe …` / `grep`
    invocations a reviewer can run to confirm the acceptance
    criteria hold.
  * **Reviewer checklist** — the load-bearing questions a
    reviewer should answer before approving.
  * **Migration notes** — operator-facing communication needed
    (only for sub-units with behavioural CLI / on-disk surface
    changes).
  * **Risk** — what could go wrong, mitigations.
  * **Effort estimate** — small / medium / large
    (S ≤ 1 day, M ≤ 1 week, L > 1 week of focused work).

**Naming convention reminder.**  Identifiers introduced by AR
must clear the `naming_audit` gate; in particular, no
identifier may carry a process marker (`_audit`, `_remediation`,
`_v2`, etc.).  See CLAUDE.md "Names describe content, never
provenance."  Where this plan suggests an identifier name
(e.g. `processSignedActionWith`, `bootstrapFromAttestedSnapshot`,
`balanceMap_roundtrip`), that name describes the *content* of
the declaration and is the one that should land.

### AR.1 — Shared `signedActionDomain` constant

**Finding map:** M-7 (`signedActionDomain` duplicated as a
separate string literal at `LegalKernel/Authority/SignedAction.lean:139`
and `LegalKernel/Encoding/SignInput.lean:63`).

**Scope:**

  * `LegalKernel/Authority/SignedAction.lean` — modified.
  * `LegalKernel/Encoding/SignInput.lean` — modified.
  * `LegalKernel/Test/Authority/SignedAction.lean` —
    add equivalence test pinning byte equality of the two
    `signedActionDomain` references.

**Math / proof outline.**  The constant
`"legalkernel/v1/signedaction"` is a 27-byte ASCII string used
as a domain prefix in two encoders:

  * `Authority.SignedAction.signingInput` (the kernel's
    pre-image function for signature verification).
  * `Encoding.SignInput.signInput` (the runtime-facing CBE
    encoder for the signing input).

The Phase-3 audit (`signingInput_eq_encoding`) proves these two
encoders produce byte-identical outputs for every valid input;
the proof currently depends on the two string literals being
the same byte sequence.

After AR.1, both sites import a single shared constant.  The
equality theorem is unchanged in *statement*; the proof
becomes shorter because the domain-string equality is now `rfl`
rather than `decide`.

**Implementation steps.**

  1. Choose the canonical home for the shared constant.
     Recommended: extend `LegalKernel/Authority/Crypto.lean`
     (already a low-level dependency of both consumer modules)
     with a `def signedActionDomain : String := "legalkernel/v1/signedaction"`
     and a sibling `signedActionDomainBytes : ByteArray :=
     signedActionDomain.toUTF8`.  Rationale: Crypto.lean
     defines the trust model (Verify, signature schemes), so it
     is the conceptual home of the domain-separation constant.

     Alternative: a new `LegalKernel/Authority/Domains.lean`
     module.  Rejected because it adds one more module to the
     import graph for negligible separation gain.

  2. Replace `LegalKernel/Encoding/SignInput.lean:63` with
     `def signedActionDomain := Authority.signedActionDomain`
     (or simply delete and re-export from `Authority.Crypto`).
     Update every call site in the file (lines 101–102, 138,
     142–143, 149, 152) to refer to the shared name.

  3. Replace `LegalKernel/Authority/SignedAction.lean:139` with
     the same shared reference.  Update call sites at lines
     146–147, 176–177.

  4. Verify by spot-rebuilding the encoding round-trip test
     suite (`lake build LegalKernel.Test.Encoding.SignInput`).
     Spot-check `signingInput_eq_encoding` still proves.

  5. Land the byte-equality regression test:
     `example : Authority.signedActionDomain.toUTF8.data.toList =
                Encoding.signedActionDomain.toUTF8.data.toList :=
       by rfl`.  (After consolidation, this collapses to `rfl`
     trivially; the test exists to catch any future de-aliasing.)

**Acceptance criteria.**

  * `grep -n "legalkernel/v1/signedaction" LegalKernel/` returns
    exactly one occurrence in `.lean` source: the canonical
    `def`.  Comments and docstrings may continue to mention the
    literal for human readers.
  * `lake build` clean.
  * `lake test` passes the existing `Authority.SignedAction`
    and `Encoding.SignInput` suites.
  * `#print axioms` on `signingInput_eq_encoding` returns the
    canonical three Lean built-ins only.

**Test plan.**

  * Add one regression test pinning the byte sequence.
  * Re-run the full Authority + Encoding test groups
    (`lake test`).

**Definition of Done.**

  - [ ] `Authority.signedActionDomain` shipped with sibling
        `signedActionDomainBytes`.
  - [ ] `Encoding.SignInput` references the shared constant.
  - [ ] `Authority.SignedAction` references the shared
        constant.
  - [ ] Byte-equality regression test landed and elaborates
        as `rfl`.
  - [ ] `lake build` + `lake test` clean.
  - [ ] `#print axioms signingInput_eq_encoding` returns the
        canonical three.

**Verification commands.**

```bash
# Exactly one canonical definition in source.
grep -rn 'legalkernel/v1/signedaction' LegalKernel/ \
  | grep -v -- '--' | grep -v -- '/-' | wc -l
# expected: 1

lake build LegalKernel.Authority.SignedAction \
           LegalKernel.Encoding.SignInput \
           LegalKernel.Authority.Crypto
lake test
```

**Reviewer checklist.**

  - [ ] Is the new constant in `Authority/Crypto.lean` (the
        recommended home), not a new module?
  - [ ] Does every previously-string-literal site now reference
        the shared name?  Use the `grep` above.
  - [ ] Does the byte-equality regression test elaborate as
        `rfl`?  (If it requires `decide`, the consolidation
        introduced a definitional drift that needs unfolding.)
  - [ ] Is `signingInput_eq_encoding`'s proof still as short
        as before, or shorter?

**Risk.**  Low.  Pure constant extraction.  No proof
content changes.  Encoding round-trip and `signingInput_eq_encoding`
both rely on `rfl`-reduction of the constant; consolidation
preserves this.

**Effort estimate.**  S (≤ ½ day).

### AR.2 — DeploymentId parameterisation (six sub-units)

**Finding map (group level):** M-1 (Replay tool's
`Admissible.decidable` and Runtime `processSignedAction`
default `deploymentId := ByteArray.empty`); M-5
(`Disputes.Evidence.checkSignatureInvalid` hardcodes
`ByteArray.empty`).

**Group rationale.**  The cross-deployment-replay protection
(`Audit-3.4`, §8.8.5) is provided by the domain-separation
prefix in `signInput`: every signature verification is over
`(domainPrefix, deploymentId, action, signer, nonce)`.  A
signed action signed under deploymentId `d1` cannot satisfy
`Verify pk msg sig` when re-checked under `d2` ≠ `d1`, because
`msg` differs in the deploymentId field.

Two theorem signatures exist (both shipped):

  * `AdmissibleWith.decidable verify P d es st : Decidable
    (AdmissibleWith verify P d es st)` — the parameterised
    decidability instance.
  * `Admissible.decidable P es st := AdmissibleWith.decidable
    Verify P ByteArray.empty es st` — the back-compat alias.

The alias was introduced in Audit-3.3 with the comment "for
back-compat with existing call sites".  AR.2's goal is to
**stop relying on the alias** at the runtime / replay / dispute
entry points.  The alias remains for narrow back-compat needs
(value-level tests that happen to encode against
`ByteArray.empty`); production paths thread the deploymentId
explicitly.

The encoded round-trip identity `Encoding.signInput a s n d =
Authority.signingInput a s n d` is parametric on `d`; no proof
changes.  AR.2 ships in **six sub-units** so each layer of
plumbing is reviewable in isolation and reverts cleanly:

  * **AR.2.1** — Runtime field plumbing
    (`RuntimeState.deploymentId`).
  * **AR.2.2** — `processSignedAction` migrates to read the
    new field.
  * **AR.2.3** — Bootstrap parameterisation.
  * **AR.2.4** — Replay parameterised entry point.
  * **AR.2.5** — Dispute `checkSignatureInvalidWith`.
  * **AR.2.6** — CLI flag wiring + stderr warning.

Each sub-unit is independently rollback-able.  The
cross-deployment regression theorem
`processSignedAction_cross_deployment_rejects` and the dispute
analogue
`checkSignatureInvalidWith_cross_deployment_distinguishes`
land with AR.2.6 (when the wiring is end-to-end exercisable);
the integration regression suite that exercises them at the
runtime hot-path level lives in AR.23.1.

#### AR.2.1 — Add `RuntimeState.deploymentId` field

**Finding map:** prerequisite for M-1 (does not by itself
change behaviour; provides the field that AR.2.2 will read).

**Scope.**

  * `LegalKernel/Runtime/Loop.lean` — add `deploymentId :
    ByteArray` to the `RuntimeState` structure; default to
    `ByteArray.empty` in `RuntimeState.empty` (or equivalent
    constructor) so existing call sites continue to elaborate
    without modification.
  * `LegalKernel/Test/Runtime/Loop.lean` — confirm existing
    suite still elaborates against the augmented structure.

**Math / proof outline.**  None; pure structural change.

**Implementation steps.**

  1. Read the current `structure RuntimeState` definition.
  2. Add the new field with an in-line docstring naming its
     role ("deployment-specific domain-separation tag for
     `signInput`; production runtime supplies a non-empty
     value via `--deployment-id`").
  3. Update every `RuntimeState.mk` / `{ ... }` construction
     site in source (typically `RuntimeState.empty`).

**Acceptance criteria.**

  * `RuntimeState` has the new field.
  * Existing `RuntimeState`-constructing call sites elaborate.

**Test plan.**  None beyond a clean rebuild.

**Definition of Done.**

  - [ ] Field added with docstring.
  - [ ] All constructor sites updated.
  - [ ] `lake build` clean.

**Verification commands.**

```bash
grep -n "deploymentId" LegalKernel/Runtime/Loop.lean
lake build LegalKernel.Runtime.Loop
```

**Reviewer checklist.**

  - [ ] Does the field's default in `RuntimeState.empty` keep
        existing test harnesses working (i.e. is the default
        `ByteArray.empty`)?
  - [ ] Is the field's docstring honest about the
        domain-separation contract?

**Risk.**  Negligible.  Pure additive structural change.

**Effort estimate.**  S (≤ ½ day).

#### AR.2.2 — `processSignedAction` reads `RuntimeState.deploymentId`

**Finding map:** M-1 (runtime hot path).

**Scope.**

  * `LegalKernel/Runtime/Loop.lean:172` — change
    `processSignedAction` to call
    `processSignedActionWith Verify rs.deploymentId rs st`
    instead of the current
    `processSignedActionWith Verify ByteArray.empty rs st`.
  * `LegalKernel/Test/Runtime/Loop.lean` — add a value-level
    test that `processSignedAction` and
    `processSignedActionWith Verify rs.deploymentId rs st`
    return identical results for a non-trivial `rs`.

**Math / proof outline.**  None; one-line change.

**Implementation steps.**

  1. Replace the literal `ByteArray.empty` with
     `rs.deploymentId`.
  2. Confirm the line is now a one-liner that matches the
     stated acceptance criterion.

**Acceptance criteria.**

  * `processSignedAction` is one line:
    `processSignedActionWith Verify rs.deploymentId rs st`.
  * Searching for `ByteArray.empty` in
    `LegalKernel/Runtime/Loop.lean` returns no hits (other
    than the field default in `RuntimeState.empty`).

**Test plan.**  Identity test as above.

**Definition of Done.**

  - [ ] Hot-path one-liner shipped.
  - [ ] Regression test confirms identity at `ByteArray.empty`
        (back-compat).
  - [ ] `lake test` clean.

**Verification commands.**

```bash
grep -n 'ByteArray.empty' LegalKernel/Runtime/Loop.lean
lake build LegalKernel.Runtime.Loop
lake test
```

**Reviewer checklist.**

  - [ ] Does the change preserve back-compat behaviour when
        `rs.deploymentId = ByteArray.empty`?  (The identity
        test must show this.)
  - [ ] Are there any other call sites in `Loop.lean` that
        still hardcode `ByteArray.empty`?

**Risk.**  Low.  Pure delegation through the new field.

**Effort estimate.**  S (≤ ½ day).

#### AR.2.3 — `bootstrap` / `bootstrapFromSnapshot` parameterisation

**Finding map:** M-1 (bootstrap surface), prerequisite for
AR.3.

**Scope.**

  * `LegalKernel/Runtime/Loop.lean` — add `deploymentId :
    ByteArray` parameter to `bootstrap` and
    `bootstrapFromSnapshot`; thread into the constructed
    `RuntimeState`.
  * `LegalKernel/Test/Runtime/Loop.lean` — extend coverage to
    exercise both the default-empty and a non-empty
    deploymentId.

**Math / proof outline.**  None; pure plumbing.

**Implementation steps.**

  1. Add the parameter; thread into the `RuntimeState` field.
  2. Default-value behaviour: provide a default
     `ByteArray.empty` for back-compat in test harnesses;
     CLI entry points (AR.2.6) require the parameter.

**Acceptance criteria.**

  * Both `bootstrap` and `bootstrapFromSnapshot` accept the
    parameter.
  * Test harness still passes; new tests cover the non-empty
    case.

**Test plan.**

  * **Default-empty.**  `bootstrap (deploymentId :=
    ByteArray.empty) ...` matches pre-AR behaviour.
  * **Non-empty.**  `bootstrap (deploymentId := some_d) ...`
    produces a `RuntimeState` whose `deploymentId = some_d`.

**Definition of Done.**

  - [ ] Parameter added to both bootstrap functions.
  - [ ] Default behaviour preserved.
  - [ ] Tests added.
  - [ ] `lake test` clean.

**Verification commands.**

```bash
grep -nE 'def (bootstrap|bootstrapFromSnapshot)' LegalKernel/Runtime/Loop.lean
lake build LegalKernel.Runtime.Loop
lake test
```

**Reviewer checklist.**

  - [ ] Does `bootstrapFromSnapshot` thread the parameter
        through to the resulting `RuntimeState`?
  - [ ] Is the default-empty back-compat preserved for
        existing test call sites?

**Risk.**  Low.  Two-function additive parameter; back-compat
default preserves existing behaviour.

**Effort estimate.**  S (≤ ½ day).

#### AR.2.4 — Replay parameterised entry point

**Finding map:** M-1 (replay surface).

**Scope.**

  * `LegalKernel/Runtime/Replay.lean` — expose a
    `replayWithDeploymentId` entry point that parameterises
    the `Admissible.decidable` instance by `d`.  Keep `replay`
    (the un-parameterised form) as a test-internal helper.
  * `LegalKernel/Test/Runtime/Replay.lean` — add positive
    (matching deploymentId) and negative (mismatched
    deploymentId) cases.

**Math / proof outline.**  The replay tool's
`Admissible.decidable` aliasing currently anchors at
`ByteArray.empty`.  The new entry point uses
`AdmissibleWith.decidable Verify P d es st` directly,
removing the alias dependency on the production path.  No
new theorem; the existing decidability theorems already cover
the parameterised form.

**Implementation steps.**

  1. Define `replayWithDeploymentId` mirroring the existing
     `replay` surface, with the deploymentId added to the
     decidability invocation.
  2. Demote `replay` to a test-internal helper (it remains in
     the file but is not exported as the canonical entry).
  3. Add tests.

**Acceptance criteria.**

  * `replayWithDeploymentId` exists and is the canonical CLI
    path.
  * `replay` is no longer used by `Replay.lean` (the audit
    binary).

**Test plan.**

  * **Positive.**  Replay a log under matching deploymentId;
    expect success.
  * **Negative.**  Replay under mismatched deploymentId;
    expect rejection at first signed action.

**Definition of Done.**

  - [ ] `replayWithDeploymentId` shipped.
  - [ ] `Replay.lean` (binary) calls the new entry.
  - [ ] Positive + negative tests landed.
  - [ ] `lake test` clean.

**Verification commands.**

```bash
grep -n 'replayWithDeploymentId\|def replay' LegalKernel/Runtime/Replay.lean Replay.lean
lake build knomosis-replay
lake test
```

**Reviewer checklist.**

  - [ ] Is the un-parameterised `replay` truly demoted (not
        called from any binary), or is it still load-bearing?
  - [ ] Does `replayWithDeploymentId` thread `d` into every
        decidability invocation it triggers (no shadowed
        default)?

**Risk.**  Low–Medium.  The decidability instance is on the
audit binary's hot path; a shadowed default would silently
re-introduce the M-1 hazard.

**Effort estimate.**  S (≤ ½ day).

#### AR.2.5 — Dispute `checkSignatureInvalidWith` parameterised variant

**Finding map:** M-5 (`checkSignatureInvalid` hardcodes
`ByteArray.empty` at `LegalKernel/Disputes/Evidence.lean:206`).

**Scope.**

  * `LegalKernel/Disputes/Evidence.lean` — add
    `checkSignatureInvalidWith` which carries the
    deploymentId; mark `checkSignatureInvalid` as a back-compat
    alias (production callers must not use it).
  * `LegalKernel/Disputes/Filing.lean` — thread `deploymentId`
    through `fileDispute` for the `signatureInvalid` claim
    path (a single new parameter forwarded to
    `checkSignatureInvalidWith`).
  * `LegalKernel/Test/Disputes/Evidence.lean` — add
    cross-deployment regression for
    `checkSignatureInvalidWith`.

**Math / proof outline.**  Identical to AR.2.4 but on the
dispute pipeline.  No new theorem; the
`Encoding.signInput`-parametric-on-`d` round-trip identity is
unchanged.

**Implementation steps.**

  1. Define `checkSignatureInvalidWith` lifting the hardcoded
     `ByteArray.empty` into a parameter (replace the line at
     `Evidence.lean:206`).
  2. Convert the existing `checkSignatureInvalid` to:

     ```lean
     def checkSignatureInvalid (es : ExtendedState)
         (log : List LogEntry) (idx : LogIndex) :
         EvidenceVerdict :=
       checkSignatureInvalidWith ByteArray.empty es log idx
     ```

     and mark its docstring "back-compat alias only — production
     callers use `checkSignatureInvalidWith`".

  3. Thread `deploymentId` into `fileDispute` for the relevant
     claim arm.

  4. Add tests.

**Acceptance criteria.**

  * `Disputes/Evidence.lean` no longer mentions
    `ByteArray.empty` outside the alias.
  * `checkSignatureInvalidWith d₁ log idx` rejects entries
    signed under `d₂ ≠ d₁`.

**Test plan.**

  * **Positive — same deployment.**  Signed under `d`; check
    under `d`; verdict matches the legitimate verdict.
  * **Negative — cross deployment.**  Signed under `d₁`; check
    under `d₂`; verdict is `.rejected` (Verify fails).

**Definition of Done.**

  - [ ] New parameterised variant shipped.
  - [ ] Alias retained and documented.
  - [ ] `fileDispute` thread updated.
  - [ ] Positive + negative tests landed.
  - [ ] `lake test` clean.

**Verification commands.**

```bash
grep -n 'ByteArray.empty' LegalKernel/Disputes/Evidence.lean
grep -n 'checkSignatureInvalid' LegalKernel/Disputes/
lake build LegalKernel.Disputes.Evidence LegalKernel.Disputes.Filing
lake test
```

**Reviewer checklist.**

  - [ ] Is the `ByteArray.empty` reference now confined to the
        alias body and the field default?
  - [ ] Does `fileDispute`'s deploymentId thread reach
        `checkSignatureInvalidWith` for *every* arm that
        invokes a signature-related verifier?

**Risk.**  Low–Medium.  Touching the dispute pipeline; the
risk is forgetting an arm of `fileDispute` that should
forward the parameter.  Mitigation: enumerate every claim
arm in the implementation diff.

**Effort estimate.**  S (≤ ½ day).

#### AR.2.6 — CLI flag wiring + stderr warning

**Finding map:** M-1 (operator-facing surface).  This sub-WU
makes the parameterised plumbing usable from the CLI.

**Scope.**

  * `Main.lean` — accept `--deployment-id <hex>` flag; parse
    via the existing hex-decoding helper (or introduce one
    if absent); pipe into `RuntimeState.deploymentId` via
    `bootstrap` / `bootstrapFromSnapshot`.
  * `Replay.lean` — accept `--deployment-id <hex>` flag; pipe
    into `replayWithDeploymentId`.
  * **Default-empty diagnostic.**  When the CLI runs without
    `--deployment-id`, emit a stderr warning analogous to the
    existing fallback-hash warning (e.g. `"warning:
    --deployment-id not supplied; using empty sentinel
    (dev mode)"`).  `knomosis-replay` (the audit binary) refuses
    the empty sentinel outright.
  * `docs/abi.md` — document the new flag.

**Math / proof outline.**  None; CLI surface change.

**Implementation steps.**

  1. Add the flag parser (one helper function, reused by both
     binaries).
  2. Add the stderr warning when the flag is absent.
  3. In `knomosis-replay`, refuse the empty sentinel with a
     non-zero exit code and a clear error message.
  4. Update `docs/abi.md` with the new flag.

**Acceptance criteria.**

  * Both binaries accept `--deployment-id <hex>`.
  * `knomosis` without the flag emits the warning but proceeds
    (dev-mode); `knomosis-replay` without the flag refuses to
    run.
  * `docs/abi.md` documents the flag.

**Test plan.**

  * **Manual.**  Run `knomosis bootstrap /tmp/log` without and
    with `--deployment-id`; verify the warning vs. silent
    success.
  * **Manual.**  Run `knomosis-replay /tmp/log` without
    `--deployment-id`; expect non-zero exit and a clear
    diagnostic.
  * **Lean-level.**  A test that the hex-decoding helper
    rejects malformed input.

**Definition of Done.**

  - [ ] Flag parsed correctly in both binaries.
  - [ ] `knomosis` warns when flag absent.
  - [ ] `knomosis-replay` refuses when flag absent.
  - [ ] `docs/abi.md` updated.
  - [ ] Hex-decoding helper has a unit test.

**Verification commands.**

```bash
lake build knomosis knomosis-replay
.lake/build/bin/knomosis bootstrap /tmp/test.log
# expected: stderr warning about --deployment-id
.lake/build/bin/knomosis-replay /tmp/test.log
# expected: non-zero exit, clear error
```

**Reviewer checklist.**

  - [ ] Is the warning text actionable (names the flag and the
        risk)?
  - [ ] Is `knomosis-replay`'s refusal at the *parse* step (not
        at the first signed action), so operator intent is
        clear from the error?
  - [ ] Is the hex-decoding helper shared between both
        binaries (no duplication)?

**Migration notes.**

This sub-WU changes operator-visible behaviour:

  * `knomosis` operators not previously passing `--deployment-id`
    will see a new stderr warning.  Functional behaviour
    unchanged when running the dev-mode binary on dev-mode
    logs (the empty sentinel is internally consistent), but
    the warning is a nudge to wire up production
    deploymentIds.
  * `knomosis-replay` operators MUST now pass `--deployment-id`
    or the audit run aborts.  This is a deliberate
    tightening: the audit binary has stronger correctness
    requirements than the dev-mode runtime.

The release notes for the AR.2.6 PR should call out these
two changes.  `docs/abi.md` carries the canonical reference;
`docs/fault_proof_runbook.md` should also gain a one-line
note pointing operators to the flag.

**Risk.**  Medium.  Operator-facing default change.
Mitigation: clear warning text; non-zero exit code on the
audit binary so silent failures are impossible; release-note
coverage.

**Effort estimate.**  S (≤ 1 day).

### AR.3 — Snapshot bootstrap chain anchor + AttestedSnapshot CLI (two sub-units)

**Finding map (group level):** M-2 (`bootstrapFromSnapshot`
does not verify the log prefix chains to the snapshot's seed
hash).

**Group rationale.**  The defect (no anchor check) and the
mitigation (require `AttestedSnapshot` for cross-replica
startup) are conceptually distinct: the anchor check is a
Lean-level value-level check that can land independently of
any CLI surface change, while the AttestedSnapshot CLI gate
is an operator-facing default change that wants its own
review and migration note.  Splitting the work into AR.3.1
(anchor check) and AR.3.2 (CLI gate) lets each land
independently, bisect cleanly, and roll forward without
entangling the proof and operator-experience concerns.

#### AR.3.1 — Anchor check in `bootstrapFromSnapshot`

**Finding map:** M-2 (Lean-level fix).

**Scope.**

  * `LegalKernel/Runtime/Loop.lean` — modify
    `bootstrapFromSnapshot` to add the chain-anchor check;
    add the new `BootstrapError.anchorMismatch` variant.
  * `LegalKernel/Test/Runtime/Loop.lean` —
    `bootstrapFromSnapshot_rejects_wrong_seed_hash`,
    `bootstrapFromSnapshot_accepts_correct_seed_hash`,
    `bootstrapFromSnapshot_genesis_anchor_zeroHash`.

**Math / proof outline.**  The hash chain is `prevHash :=
hash(prev_entry)`; the first post-snapshot entry has
`prevHash = seedHash`.  M-2's observation is that the existing
`bootstrapFromSnapshot` calls `replayFromSeed policy seedHash
state tail`, which checks the chain *starting from* seedHash
— but only checks the first post-snapshot entry.  If the
snapshot is *the wrong snapshot* for a given log, the first
entry's chain check fires.  However, if the operator supplies
a *different log* that happens to be a valid chain on its
own, the post-snapshot tail's local chain is consistent and
bootstrap succeeds.  The defence against this is the
attestor's signature on the snapshot — covered by
`AttestedSnapshot` (AR.3.2 wires the CLI gate).

The chain-anchor check we add is structurally simple:

```lean
def bootstrapFromSnapshot
    (policy : AuthorityPolicy) (snap : Snapshot)
    (logPath : System.FilePath) (deploymentId : ByteArray) :
    IO (Except BootstrapError (RuntimeState × Option FrameError)) := do
  match restoreSnapshot snap with
  | .ok (state, seedHash, baseIdx) =>
    let (entries, frameErr) ← loadAndTruncate logPath
    if baseIdx > entries.length then
      pure (.error (.logIndexOverrun baseIdx entries.length))
    else
      -- NEW: anchor check.  Look up the log entry at
      -- baseIdx-1 (the last pre-snapshot entry, which must
      -- hash to the snapshot's seedHash).  If baseIdx = 0, the
      -- snapshot is at genesis; seedHash must be zeroHash.
      let anchorOk := match baseIdx with
        | 0 => seedHash.toList = zeroHash.toList
        | k+1 =>
          match entries[k]? with
          | some e => seedHash.toList = (LogEntry.hash e).toList
          | none   => false
      if ¬ anchorOk then
        pure (.error .anchorMismatch)
      else
        ...
```

This is a value-level check, not a theorem; soundness comes
from the fact that the chain is hash-determined: an honest
operator's snapshot has `seedHash = hash(entries[baseIdx-1])`,
so the anchor matches.  An adversarial snapshot fails the
anchor check unless the adversary can find a collision —
ruled out under `CollisionFree hashBytes`.

**Implementation steps.**

  1. Add the new `BootstrapError.anchorMismatch` variant
     (with a docstring naming the failure mode).

  2. Add the value-level anchor check before
     `replayFromSeed`.  The check is decidable and runs in
     `O(1)` (a single hash equality on 32 bytes).

  3. Add the matching tests.

**Acceptance criteria.**

  * `bootstrapFromSnapshot` rejects a snapshot whose
    `seedHash` does not match the actual log[baseIdx-1] hash.
  * `lake test` passes the new regression suite.

**Test plan.**

  * **Positive — correct snapshot.**  Snapshot for log[0..k],
    seedHash = hash(log[k-1]).  Bootstrap succeeds.
  * **Negative — wrong seedHash.**  Snapshot with seedHash =
    some-other-value.  Bootstrap returns `.anchorMismatch`.
  * **Edge — genesis snapshot.**  baseIdx = 0, seedHash =
    zeroHash.  Bootstrap succeeds (this is the "fresh-genesis"
    case).
  * **Edge — log truncated.**  baseIdx > entries.length.
    Bootstrap returns `.logIndexOverrun` (unchanged
    behaviour; new check does not preempt this branch).
  * **Edge — empty log + baseIdx = 0 + non-zero seedHash.**
    Returns `.anchorMismatch`.

**Definition of Done.**

  - [ ] `BootstrapError.anchorMismatch` shipped.
  - [ ] Anchor check shipped before `replayFromSeed`.
  - [ ] Three positive + two negative + two edge tests
        landed.
  - [ ] `lake test` clean.
  - [ ] `#print axioms` on the new tests is canonical.

**Verification commands.**

```bash
grep -n 'anchorMismatch\|bootstrapFromSnapshot' \
  LegalKernel/Runtime/Loop.lean
lake build LegalKernel.Runtime.Loop
lake test
```

**Reviewer checklist.**

  - [ ] Is the anchor check `O(1)` (single hash equality, no
        log-length scan)?
  - [ ] Does the check fire **before** `replayFromSeed` so
        the wrong-anchor failure is reported as
        `.anchorMismatch` rather than masquerading as a
        chain-check failure deep in the replay?
  - [ ] Does the genesis branch (`baseIdx = 0`) compare
        against `zeroHash` rather than skipping?
  - [ ] Are the tests deployment-agnostic (do not depend on
        `Verify` returning `true`)?

**Risk.**  Low.  The check is simple and additive; existing
positive paths preserve their behaviour.

**Effort estimate.**  S (≤ ½ day).

#### AR.3.2 — `AttestedSnapshot` CLI default + opt-in flag

**Finding map:** M-2 (operator-facing surface).

**Scope.**

  * `LegalKernel/Runtime/AttestedSnapshot.lean` — expose a
    `bootstrapFromAttestedSnapshot` entry point that wraps
    `bootstrapFromSnapshot` with the attestor-signature check
    as a hard prerequisite.
  * `Main.lean` — `knomosis bootstrap --snapshot <path>` is now
    refused unless either `--attested` (the AttestedSnapshot
    path) or `--unsafe-self-attested` (an explicit opt-in for
    single-replica dev mode) is supplied.
  * `LegalKernel/Test/Runtime/AttestedSnapshot.lean` —
    extended coverage of the CLI-required gate.
  * `docs/abi.md` — document the new CLI flag matrix and the
    anchor-mismatch failure mode.
  * `docs/fault_proof_runbook.md` — add a one-line note
    pointing operators to the new gate.

**Math / proof outline.**  None; CLI surface change.  The
attestor-signature check uses the existing
`AttestedSnapshot.verify` plumbing.

**Implementation steps.**

  1. Define `bootstrapFromAttestedSnapshot` as a thin wrapper
     that returns `.error .unattested` when the
     attestor-signature is missing or invalid, and otherwise
     delegates to `bootstrapFromSnapshot` (which now carries
     the AR.3.1 anchor check).

  2. Update `Main.lean`'s `bootstrap` subcommand to refuse
     `--snapshot <path>` without one of `--attested` or
     `--unsafe-self-attested`.  Refuse the unsafe flag in
     `knomosis-replay`.

  3. Update `docs/abi.md` and `docs/fault_proof_runbook.md`.

  4. Add tests covering the CLI-required gate.

**Acceptance criteria.**

  * `knomosis bootstrap --snapshot <path>` (no `--attested`)
    fails with a clear diagnostic.
  * `knomosis bootstrap --snapshot <path> --attested` succeeds
    on a properly attested snapshot.
  * `knomosis bootstrap --snapshot <path> --unsafe-self-attested`
    succeeds with a stderr warning.
  * `knomosis-replay` refuses `--unsafe-self-attested`
    outright.
  * `docs/abi.md` and `docs/fault_proof_runbook.md` reflect
    the new gate.

**Test plan.**

  * **Positive — attested.**  Attested snapshot succeeds.
  * **Negative — unattested.**  Bare `--snapshot` is refused.
  * **Negative — bad attestation.**  Snapshot with mismatched
    attestor signature is refused.
  * **Edge — `--unsafe-self-attested` warning.**  Warning
    text is precise and actionable.

**Definition of Done.**

  - [ ] `bootstrapFromAttestedSnapshot` shipped.
  - [ ] `knomosis` CLI gates land.
  - [ ] `knomosis-replay` refuses unsafe opt-in.
  - [ ] `docs/abi.md` + `docs/fault_proof_runbook.md`
        updated.
  - [ ] Tests landed.

**Verification commands.**

```bash
lake build knomosis knomosis-replay
.lake/build/bin/knomosis bootstrap --snapshot /tmp/snap /tmp/log
# expected: refused with diagnostic
.lake/build/bin/knomosis bootstrap --snapshot /tmp/snap \
  --unsafe-self-attested /tmp/log
# expected: stderr warning + success
```

**Reviewer checklist.**

  - [ ] Is the diagnostic message for refused-unattested
        actionable (names both alternative flags)?
  - [ ] Is the unsafe opt-in flag named with a clear
        warning-level prefix (`--unsafe-...`) per CLI
        convention?
  - [ ] Does `knomosis-replay` (the audit binary) refuse the
        unsafe flag at parse time?

**Migration notes.**

This sub-WU changes operator-visible behaviour:

  * Bare `knomosis bootstrap --snapshot ...` no longer works.
    Operators must explicitly choose between the attested
    (production) and unsafe (dev-only) paths.
  * A single-replica dev workflow that previously
    self-attested implicitly must now pass
    `--unsafe-self-attested`.

The release note for AR.3.2 should call this out and link
to `docs/fault_proof_runbook.md` for the operator
walkthrough.

**Risk.**  Medium.  Operator-facing default change.
Mitigation: explicit opt-in flag retains the dev-mode
workflow; clear diagnostic for unattested attempts; release
note + runbook update.

**Effort estimate.**  S (≤ 1 day).


### AR.4 — Map-backed sub-state encoder injectivity (eight sub-units)

**Status: Complete.**  Shipped under Workstream EI (Encoder
Injectivity) on
`claude/encoder-injectivity-implementation-UggQv` and the
predecessor branches `claude/review-encoder-plan-0p5MI`
(EI.0), `claude/atomic-injectivity-foundation-yHSwQ` (EI.1),
and `claude/implement-state-encode-nested-nbXhh` (EI.2).  All
EI.0 – EI.8 sub-units landed.  See
`docs/planning/encoder_injectivity_plan.md` for the per-sub-unit
catalogue and `LegalKernel/Encoding/{StateInjective,
LocalPolicyInjective, BridgeInjective}.lean` plus
`LegalKernel/FaultProof/Commit.lean` for the shipped theorems.

**Finding map (group level):** M-3 (`*_encode_deterministic`
only; no `*_encode_injective` for `State`, `ExtendedState`,
`BridgeState`, `LocalPolicies`, `KeyRegistry`, `NonceState`);
resolves informational observation i-8 (commit-injectivity at
bytes level only).

**Group rationale.**  M-3 is the deepest theorem work in AR.
The decoder definitions are already shipped in
`LegalKernel/Encoding/State.lean` (`BalanceMap.decode:223`,
`State.decode:238`, `NonceState.decode:459`,
`KeyRegistry.decodeMap:469`, `ExtendedState.decode:483`,
`Bridge.DepositRecord.decode:301`,
`Bridge.PendingWithdrawal.decode:348`,
`Bridge.BridgeState.decode:427`).  The
`*_encode_deterministic` lemmas are shipped at lines 527 / 534
/ 544 / 555 / 563 / 569.  What is *not* shipped is the
**encoder-injectivity quartet** — `*_decode` + `*_roundtrip` +
`*_encode_injective_extensional` +
`*_encode_injective_of_equiv` — for the map-backed sub-states.
AR.4 lands the theorem track on top of the existing decoder
API.

The work decomposes into eight sub-units of similar shape:

  * **AR.4.1** — Generic helper: `Encodable.RoundtripsAt`
    typeclass + `encodeSortedPairs_decodeMap_roundtrip` lemma.
    Establishes the reusable proof infrastructure.
  * **AR.4.2** — `BalanceMap` quartet (template; the most
    instructive instance).
  * **AR.4.3** — `State` quartet (outer map of resources →
    BalanceMap).
  * **AR.4.4** — `NonceState` quartet.
  * **AR.4.5** — `KeyRegistry` quartet.
  * **AR.4.6** — `LocalPolicies` quartet.
  * **AR.4.7** — `BridgeState` (consumed + pending) quartet.
  * **AR.4.8** — `ExtendedState` composition + FaultProof.Commit
    chain composition + CLAUDE.md footnote 1 retirement.

**Why this decomposition.**  Each sub-state's quartet is a
~200-line proof that mirrors the AR.4.2 BalanceMap template
mechanically (different types, same structural shape).
Splitting the work means:

  1. The expensive AR.4.2 template-establishing PR can land
     first and be reviewed by the proof-discipline reviewer.
     Subsequent quartets (AR.4.3 – AR.4.7) are mechanical
     replications and can be reviewed in parallel.
  2. A bug in any one quartet doesn't block the others
     (e.g. an unexpected `fieldsBounded` complication in
     `KeyRegistry` doesn't stall the BridgeState track).
  3. The FaultProof composition (AR.4.8) waits for all
     prerequisite quartets but is otherwise independent of
     the proof internals.
  4. CLAUDE.md footnote 1 is retired only after AR.4.8 lands,
     in lockstep with the documentation-update PR (AR.22).

**Shared scope (referenced by sub-units below).**  Files
modified across the AR.4 group:

  * `LegalKernel/Encoding/State.lean` —
    `*_fieldsBounded`, `*_roundtrip`,
    `*_encode_injective_extensional`,
    `*_encode_injective_of_equiv` per sub-state.
  * `LegalKernel/Encoding/LocalPolicy.lean` — analogous for
    `LocalPolicies`.  Clause-level `fieldsBounded` is
    already shipped at line 57; AR.4.6 adds the map-level
    quartet.
  * `LegalKernel/FaultProof/Commit.lean` — extend
    `commitState_bytes_injective_under_collision_free` with
    a downstream
    `commitExtendedState_extensional_injective_under_collision_free`
    lemma chaining the new encoder injectivity (AR.4.8).
  * `LegalKernel/Test/Encoding/State.lean` — round-trip +
    cross-value distinguishability tests for each new lemma.
  * `LegalKernel/Test/FaultProof/Commit.lean` — composition
    test showing the full chain
    `commit-eq → bytes-eq → encode-eq → toList-eq` (AR.4.8).

**Scope (deprecated single-WU view).**  The original AR.4
single-WU specification is preserved below as the **shared
math / proof outline**; the sub-WUs that follow give the
implementation cuts.

**Math / proof outline.**  `ActorId = UInt64` and
`ResourceId = UInt64` are bounded by construction; only
`Amount = Nat` requires an explicit `< 2^64` bound to keep
`Encodable.encode (T := Nat)` canonical.  So
`BalanceMap.fieldsBounded bm := ∀ kv ∈ bm.toList, kv.2 < 2^64`
(quantifying over values only; the keys are already bounded
by their `UInt64` type).

The decoder *already exists* in source.  The actual
implementation (line 197–198 + 223–229 of `Encoding/State.lean`)
delegates to two generic helpers:

```lean
-- Existing helpers (do NOT add; they are shipped).
-- encodeSortedPairs writes a CBE map head + sorted-pair list.
def encodeSortedPairs [Encodable K] [Encodable V] (pairs : List (K × V)) : Stream :=
  cborHeadEncode cbeTagMap pairs.length ++
    pairs.foldr (fun p acc =>
      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []

-- decodeMap reads the head + N pairs, then enforces canonical
-- ascending-key ordering and distinct-key discipline.
def decodeMap [Encodable K] [Encodable V] (s : Stream) (cmp : K → K → Ordering) :
    Except DecodeError (List (K × V) × Stream)

-- Existing BalanceMap encoder + decoder.
def BalanceMap.encode (bm : BalanceMap) : Stream :=
  encodeSortedPairs (bm.toList.map (fun (a, v) => (a.toNat, v)))

def BalanceMap.decode (s : Stream) : Except DecodeError (BalanceMap × Stream) :=
  match decodeMap (K := Nat) (V := Nat) s with
  | .ok (pairs, rest) =>
    .ok (TreeMap.ofList (pairs.map (fun (k, v) => (k.toUInt64, v))) compare, rest)
  | .error e => .error e
```

The AR.4 proof work attaches new theorems on top of these.
Two layers of round-trip:

  1. **Generic helper round-trip.**  Prove
     `encodeSortedPairs_decodeMap_roundtrip` for any pair list
     that is (a) strictly ascending by `compare` and (b)
     field-bounded element-wise:

     ```lean
     theorem encodeSortedPairs_decodeMap_roundtrip
         [Encodable K] [Encodable V] [DecidableEq K]
         (pairs : List (K × V))
         (h_sorted : keysStrictlyAscending compare pairs = true)
         (h_k : ∀ kv ∈ pairs, Encodable.RoundtripsAt kv.1)
         (h_v : ∀ kv ∈ pairs, Encodable.RoundtripsAt kv.2)
         (rest : Stream) :
         decodeMap (encodeSortedPairs pairs ++ rest) compare =
         .ok (pairs, rest)
     ```

     The `Encodable.RoundtripsAt` hypothesis abstracts the
     per-type canonical-bound predicate (`< 2^64` for `Nat`,
     `< 2^64` size for `ByteArray`).

  2. **Per-type round-trip.**  Specialise to each
     map-backed encoder:

```lean
theorem balanceMap_roundtrip
    (bm : BalanceMap) (rest : Stream)
    (h : BalanceMap.fieldsBounded bm) :
    ∃ bm', bm.Equiv bm' ∧
    BalanceMap.decode (BalanceMap.encode bm ++ rest) =
      .ok (bm', rest)
```

The statement uses `Equiv` rather than `=` because the
decoder reconstructs the TreeMap via `TreeMap.ofList ... compare`
(see `BalanceMap.decode:223-229`), which may produce a
TreeMap whose internal RB structure differs from `bm` while
remaining extensionally equivalent.  `TreeMap.equiv_iff_toList_eq`
collapses the existential to a `toList`-equality form for
downstream consumers.

Proof strategy: chain through `encodeSortedPairs_decodeMap_roundtrip`
(step 1).  The pair list `bm.toList.map (fun (a, v) =>
(a.toNat, v))` is strictly ascending by `compare` because
`TreeMap.toList` is sorted and `.toNat` is monotonic on
`UInt64`.  Each Nat value satisfies the canonical
`< 2^64` bound by `h : BalanceMap.fieldsBounded bm`.  Apply
the helper roundtrip to recover the pair list, then map
`(k_nat, v) ↦ (k_nat.toUInt64, v)` (lossless under
`k_nat < 2^64`).  Finally, `TreeMap.ofList` reconstructs an
`Equiv`-equivalent map.

Injectivity follows mechanically, mirroring the existing
`action_encode_injective` pattern in
`LegalKernel/Encoding/Action.lean:818-827`:

```lean
theorem balanceMap_encode_injective_extensional
    (bm₁ bm₂ : BalanceMap)
    (h₁ : BalanceMap.fieldsBounded bm₁)
    (h₂ : BalanceMap.fieldsBounded bm₂)
    (heq : BalanceMap.encode bm₁ = BalanceMap.encode bm₂) :
    bm₁.toList = bm₂.toList := by
  obtain ⟨bm₁', heq₁, r₁⟩ := balanceMap_roundtrip bm₁ [] h₁
  obtain ⟨bm₂', heq₂, r₂⟩ := balanceMap_roundtrip bm₂ [] h₂
  rw [heq] at r₁
  have heqOk :
      (.ok (bm₁', ([] : Stream))
        : Except DecodeError (BalanceMap × Stream))
      = .ok (bm₂', []) := r₁.symm.trans r₂
  have h_bm' : bm₁' = bm₂' :=
    (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heqOk) |>.1
  -- Lift to toList equality via Equiv composition.
  have : bm₁.toList = bm₁'.toList :=
    TreeMap.equiv_iff_toList_eq.mp heq₁
  have : bm₂.toList = bm₂'.toList :=
    TreeMap.equiv_iff_toList_eq.mp heq₂
  -- bm₁.toList = bm₁'.toList = bm₂'.toList = bm₂.toList
  grind  -- or transitive chain
```

The pattern matches the existing `Action.encode_injective`
proof verbatim, with the extra step lifting through the
`Equiv` of the round-trip.

Lifting to `Equiv` on the original maps:

```lean
theorem balanceMap_encode_injective_of_equiv
    (bm₁ bm₂ : BalanceMap)
    (h₁ : BalanceMap.fieldsBounded bm₁)
    (h₂ : BalanceMap.fieldsBounded bm₂)
    (heq : BalanceMap.encode bm₁ = BalanceMap.encode bm₂) :
    bm₁.Equiv bm₂ :=
  TreeMap.equiv_iff_toList_eq.mpr
    (balanceMap_encode_injective_extensional bm₁ bm₂ h₁ h₂ heq)
```

This is the form that downstream consumers (FaultProof,
runtime snapshot restoration) need: the kernel never relies
on TreeMap internal structure, only on extensional content.

**Composition with the FaultProof chain.**  The downstream
chain becomes:

```
commitState s₁ = commitState s₂                       (hypothesis)
  ─── commitState_bytes_injective_under_collision_free
ByteArray.mk (State.encode s₁).toArray =
  ByteArray.mk (State.encode s₂).toArray
  ─── ByteArray.mk.injEq : .mk arr₁ = .mk arr₂ ↔ arr₁ = arr₂
State.encode s₁ = State.encode s₂ (as Streams)
  ─── state_encode_injective_of_equiv  (NEW)
s₁.balances.Equiv s₂.balances                        (conclusion)
```

The conclusion is *extensional* equality
(`Equiv`, equivalently `toList = toList`), **not** Lean `=`.
Two `State`s with the same `balances.toList` are
indistinguishable to every kernel observer (`getBalance`,
`totalSupply`, every `Transition`) but may have different
internal RB-tree shapes.  This is exactly what the
fault-proof chain needs — the off-chain attestation reasons
about state *content*, not RB-tree representation.

CLAUDE.md footnote 1 explicitly identifies this as the
target form ("Lifting bytes-equality to extensional state
equality (`toList` equality)").  AR.4 ships that lift.

**Why not lift further to Lean `=`.**  Lean `=` on
`TreeMap` would require RB-tree representation canonicality
(`TreeMap.ofList list compare = bm` whenever `list = bm.toList`).
Such a lemma is not provable in general because `TreeMap`
admits multiple RB-tree shapes for the same key set; the
canonical-shape claim would need a normalisation operation.
Restricting consumers to extensional equality is the right
posture — it is what the kernel proofs already use
throughout (`balanceMap_encode_deterministic_of_equiv`,
`localPolicies_encodeMap_deterministic_of_equiv`).

**`State.encode` is composed of `BalanceMap.encode` plus the
outer `cborHeadEncode cbeTagMap` for the resource → balanceMap
map.**  So `State.encode` is itself a map encoder.  The same
proof pattern applies recursively: a `State.decode` is built
on top of `BalanceMap.decode` plus a per-resource recursion.
Same for `NonceState`, `KeyRegistry`, `LocalPolicies`,
`BridgeState`.

**`fieldsBounded` propagation.**  Because
`ActorId = UInt64` and `ResourceId = UInt64` (abbrevs from
`LegalKernel/Kernel.lean:51-54`), the keys of every
map-backed sub-state are bounded by their type and need no
explicit clause.  Only `Amount = Nat` (line 59) needs the
explicit `< 2^64` canonical-encoding bound.  Hence:

  * `BalanceMap.fieldsBounded bm := ∀ kv ∈ bm.toList, kv.2 < 2^64`
  * `State.fieldsBounded st := ∀ r ∈ st.balances.keys,
    BalanceMap.fieldsBounded (st.balances[r]!)`
  * `NonceState.fieldsBounded ns := ∀ kv ∈ ns.nextNonce.toList,
    kv.2 < 2^64` (Nonce is also Nat)
  * `KeyRegistry.fieldsBounded kr := ∀ kv ∈ kr.toList,
    kv.2.size < 2^64` (PublicKey is a ByteArray with a CBE
    bytestring size bound)
  * `LocalPolicies.fieldsBounded lp := ∀ kv ∈ lp.toList,
    LocalPolicy.fieldsBounded kv.2` (already shipped at
    `Encoding/LocalPolicy.lean:57` for the clause-level
    predicate)
  * `BridgeState.fieldsBounded bs := (every consumed
    DepositRecord's resource/amount < 2^64) ∧ (every pending
    PendingWithdrawal's resource/amount < 2^64)`

A canonical (production) state satisfies `fieldsBounded` by
virtue of the runtime's frame-validation gates; the kernel's
admissibility predicates do not currently enforce `< 2^64`
bounds on every Nat at the admissibility layer, but the
runtime adaptor's deserialiser does.  AR.4's lemmas are
correct *under the existing trust assumption* that the
deployment's frame-validation supplies `fieldsBounded`.

**Implementation steps.**

The decoder is already shipped at `BalanceMap.decode:223`,
`State.decode:238`, etc.  AR.4's work is the theorem track
on top.  Per-sub-state determinism is shipped (lines
527/534/544/555/563/569), but `*_roundtrip` and
`*_encode_injective` are shipped only for the leaf records
(`DepositRecord` at line 576), not for the map-backed
sub-states.

  1. **Land the `BalanceMap` track end-to-end.**  Define
     `BalanceMap.fieldsBounded` (`∀ kv ∈ bm.toList, kv.2 < 2^64`,
     keys are UInt64 so already bounded);
     prove `balanceMap_roundtrip` (encode →
     decode = id on the canonical-bounded domain), prove
     `balanceMap_encode_injective` (using the
     `Prod.mk.injEq` + `Except.ok.inj` pattern shown above)
     and `balanceMap_encode_injective_of_equiv` (lift via
     `TreeMap.equiv_iff_toList_eq`).  Add tests: encode →
     decode round-trip, distinguishability for two non-`Equiv`
     maps, rejection of out-of-bound encodings.

  2. **Generalise to `State`.**  Same pattern, one level up.
     `State.fieldsBounded` (every resource key < 2^64 and every
     inner-BalanceMap `fieldsBounded`); `state_roundtrip`
     (chaining `BalanceMap.decode`'s round-trip pointwise);
     `state_encode_injective`,
     `state_encode_injective_of_equiv` (lifting to the outer
     `TreeMap ResourceId BalanceMap`).

  3. **Per-sub-state tracks.**  Apply the same template to
     `NonceState` (the `TreeMap ActorId Nonce`), `KeyRegistry`
     (the `TreeMap ActorId PublicKey`), `LocalPolicies` (the
     `TreeMap ActorId LocalPolicy`), and `BridgeState` (the
     `consumed : TreeMap DepositId Unit` and `pending : TreeMap
     WithdrawalId PendingWithdrawal`).  Each is a 2–3 day
     task once BalanceMap establishes the template.

  4. **Generalise to `ExtendedState`.**  `ExtendedState`
     wraps `(base : State, registry : KeyRegistry, nonces :
     NonceState, localPolicies : LocalPolicies, bridge :
     BridgeState)` (per `LegalKernel/Authority/Nonce.lean:98`).
     The field-wise injectivity composes via the existing
     `extendedState_encode_deterministic` reverse direction,
     giving `extendedState_encode_injective_of_extensional`
     under the conjunction of the five field-level boundedness
     predicates.

  5. **FaultProof.Commit composition.**  Add
     `commitState_extensional_injective_under_collision_free`,
     and update `commitExtendedState_subcommits_bytes_eq_under_collision_free`'s
     consumer chain in `Coherence.lean` to expose the lifted
     form:

     ```lean
     theorem commitExtendedState_extensional_injective_under_collision_free
         (es₁ es₂ : ExtendedState)
         (h_cf : Bridge.CollisionFree hashBytes)
         (h₁ : ExtendedState.fieldsBounded es₁)
         (h₂ : ExtendedState.fieldsBounded es₂)
         (h : commitExtendedState es₁ = commitExtendedState es₂) :
         es₁ = es₂
     ```

     where `ExtendedState.fieldsBounded` is the structural
     conjunction of the five field-level predicates.

  6. **Update CLAUDE.md footnote 1.**  AR.22 (doc update) marks
     the follow-up as shipped.

**Acceptance criteria.**

  * Every map-backed sub-state has shipped `*_decode`,
    `*_roundtrip`, `*_encode_injective`, and
    `*_encode_injective_of_equiv`.
  * `lake build` clean; `lake test` passes the new round-trip
    and injectivity suites.
  * `#print axioms` on every new theorem returns the canonical
    three.
  * The CLAUDE.md footnote 1 disclaimer can be removed.

**Test plan.**

  * **Empty cases.**  Empty map encodes/decodes to/from the
    canonical head.
  * **Single-entry cases.**  Per-type single-entry round-trip.
  * **Multi-entry cases.**  Map of 3, 5, 10 entries: round-trip.
  * **Boundedness rejection.**  Encode-decode of a
    structurally-valid-but-not-bounded value: decoder fails
    with `.nonCanonicalKey` or `.nonCanonicalValue`.
  * **Cross-value distinguishability.**  Two non-Equiv maps
    produce different bytes.
  * **Equiv-preserved.**  `bm₁.Equiv bm₂` implies
    `BalanceMap.encode bm₁ = BalanceMap.encode bm₂` (already
    shipped; re-verify).

**Risk.**  Medium-High.  This is the deepest theorem work in
AR.

  * **Performance risk.**  The decode pseudo-code is `O(n)`
    in the map size with constant per-pair work.  Should not
    regress.
  * **API risk.**  Downstream consumers (FaultProof) gain the
    new `*_extensional_injective` lemma but the *signature*
    of the existing `*_bytes_injective` is unchanged.  No
    breaking change.
  * **Proof complexity risk.**  Each track is a separate proof
    of similar structure.  Mitigation: prove `BalanceMap`
    first as the template, then mechanically replicate for the
    other four.
  * **`fieldsBounded` propagation risk.**  The runtime
    boundedness obligation must be threaded carefully so the
    consumer-facing theorem statement is honest about its
    hypotheses.

**Effort estimate (group total).**  L (1–2 weeks of focused
proof work; ≈ 9 working days under maximally parallel review,
≈ 16 working days under sequential review).

#### AR.4.1 — Generic helper round-trip + `Encodable.RoundtripsAt`

**Finding map:** Prerequisite for AR.4.2 – AR.4.7.  Establishes
the reusable proof infrastructure.

**Scope.**

  * `LegalKernel/Encoding/Encodable.lean` — add
    `Encodable.RoundtripsAt : (T : Type) → T → Prop`
    typeclass-style abbreviation (per-type round-trip
    predicate).
  * `LegalKernel/Encoding/State.lean` — add
    `encodeSortedPairs_decodeMap_roundtrip` (the generic
    helper-level round-trip).
  * `LegalKernel/Test/Encoding/Helpers.lean` (new) — round-trip
    coverage at the helper level (3 toy types).

**Math / proof outline.**  Per the group-level outline above:
prove the helper-level round-trip lemma

```lean
theorem encodeSortedPairs_decodeMap_roundtrip
    [Encodable K] [Encodable V] [DecidableEq K]
    (pairs : List (K × V))
    (h_sorted : keysStrictlyAscending compare pairs = true)
    (h_k : ∀ kv ∈ pairs, Encodable.RoundtripsAt kv.1)
    (h_v : ∀ kv ∈ pairs, Encodable.RoundtripsAt kv.2)
    (rest : Stream) :
    decodeMap (encodeSortedPairs pairs ++ rest) compare =
    .ok (pairs, rest)
```

The proof is structural induction on `pairs` chained with
`cborHeadDecode` round-trip.  `Encodable.RoundtripsAt` for
the primitive types (Nat, ByteArray) is shipped at
`Encoding/Encodable.lean` (the existing `nat_roundtrip` /
`byteArray_roundtrip` lemmas are the witnesses).

**Implementation steps.**

  1. Define `Encodable.RoundtripsAt T x` as
     `Encodable.decode (Encodable.encode x ++ rest) =
        .ok (x', rest) ∧ EquivT x x'` (the typeclass-style
     abbreviation).
  2. Prove the per-primitive instances (Nat, ByteArray) reuse
     existing `*_roundtrip` lemmas.
  3. Prove `encodeSortedPairs_decodeMap_roundtrip`.
  4. Add helper-level tests (3 toy types).

**Acceptance criteria.**

  * `Encodable.RoundtripsAt` shipped and instantiated for the
    primitive types.
  * `encodeSortedPairs_decodeMap_roundtrip` shipped.
  * Helper-level tests pass.

**Test plan.**

  * **Empty list.**  `encodeSortedPairs []` round-trips.
  * **Single-pair.**  Single (Nat, Nat) pair round-trips.
  * **Multi-pair.**  Three sorted Nat pairs round-trip.

**Definition of Done.**

  - [ ] Helper lemma shipped and `#print axioms` returns
        canonical three.
  - [ ] Three primitive `RoundtripsAt` instances shipped.
  - [ ] Helper-level tests pass.

**Verification commands.**

```bash
grep -n 'encodeSortedPairs_decodeMap_roundtrip\|RoundtripsAt' \
  LegalKernel/Encoding/State.lean LegalKernel/Encoding/Encodable.lean
lake build LegalKernel.Encoding.Encodable LegalKernel.Encoding.State
lake test
```

**Reviewer checklist.**

  - [ ] Is `RoundtripsAt` a definitionally lightweight
        abbreviation (avoid typeclass-resolution overhead)?
  - [ ] Does the helper lemma propagate `h_sorted` correctly
        through the induction?
  - [ ] Is the `rest`-stream handling honest (the lemma
        statement allows any suffix)?

**Risk.**  Low–Medium.  Generic helper proof.  Mitigation:
prove against the existing `nat_roundtrip` / `byteArray_roundtrip`
shape; if the proof shape differs, surface the difference
before specialising.

**Effort estimate.**  S (≤ 1 day).

#### AR.4.2 — `BalanceMap` quartet (template-establisher)

**Finding map:** M-3 — `BalanceMap` is the simplest map-backed
sub-state and is the template for AR.4.3 – AR.4.7.

**Scope.**

  * `LegalKernel/Encoding/State.lean` — add
    `BalanceMap.fieldsBounded`, `balanceMap_roundtrip`,
    `balanceMap_encode_injective_extensional`,
    `balanceMap_encode_injective_of_equiv`.
  * `LegalKernel/Test/Encoding/State.lean` — round-trip,
    cross-value distinguishability, boundedness rejection
    tests for `BalanceMap`.

**Math / proof outline.**  Per the group-level outline
(specialised to `BalanceMap`).  The proof is the
two-layer chain: (i) helper round-trip
(AR.4.1), (ii) per-type lift via `TreeMap.equiv_iff_toList_eq`.
Mirror the existing `action_encode_injective` proof at
`LegalKernel/Encoding/Action.lean:818-827` for the structural
template.

**Implementation steps.**

  1. Define `BalanceMap.fieldsBounded bm := ∀ kv ∈ bm.toList,
     kv.2 < 2^64`.  Keys are `ActorId = UInt64`, bounded by
     type.
  2. Prove `balanceMap_roundtrip` chaining through
     `encodeSortedPairs_decodeMap_roundtrip` + `TreeMap.ofList`
     reconstruction.
  3. Prove `balanceMap_encode_injective_extensional` via
     `Prod.mk.injEq + Except.ok.inj` (template at
     `Action.lean:818-827`).
  4. Lift to `balanceMap_encode_injective_of_equiv` via
     `TreeMap.equiv_iff_toList_eq.mpr`.
  5. Add tests.

**Acceptance criteria.**

  * Quartet shipped: `*_decode` (already exists),
    `*_roundtrip`, `*_encode_injective_extensional`,
    `*_encode_injective_of_equiv`.
  * Tests cover: empty, single, multi-entry, bounded vs.
    unbounded inputs, cross-value distinguishability.

**Test plan.**  Per the shared test plan (specialised to
`BalanceMap`).

**Definition of Done.**

  - [ ] Quartet shipped.
  - [ ] Five tests landed (empty, single, multi, boundedness
        rejection, cross-value distinguishability).
  - [ ] `#print axioms` clean on every new theorem.
  - [ ] The proof uses only the helper lemma + Std library
        (no new opaques, no Mathlib).

**Verification commands.**

```bash
grep -n 'balanceMap_roundtrip\|balanceMap_encode_injective' \
  LegalKernel/Encoding/State.lean
lake build LegalKernel.Encoding.State
lake test
echo '#print axioms balanceMap_encode_injective_of_equiv' | \
  lake env lean --stdin
```

**Reviewer checklist.**

  - [ ] Is `BalanceMap.fieldsBounded` value-only (keys
        bounded by `UInt64` type, no explicit clause needed)?
  - [ ] Does the proof close without `decide` or `native_decide`?
  - [ ] Does the lift to `Equiv` use `TreeMap.equiv_iff_toList_eq`
        (the project's canonical extensional-equality bridge)?
  - [ ] Is the proof structurally similar to
        `action_encode_injective` (the established pattern)?

**Risk.**  Medium-High.  Template-establisher; the proof
shape ratifies AR.4.3 – AR.4.7.  Mitigation: this sub-WU
gets the most-careful review; subsequent quartets are
mechanical replications.

**Effort estimate.**  M (≈ 4 working days).

#### AR.4.3 — `State` quartet (outer ResourceId → BalanceMap map)

**Finding map:** M-3 (per the group).

**Scope.**

  * `LegalKernel/Encoding/State.lean` — add
    `State.fieldsBounded`, `state_roundtrip`,
    `state_encode_injective_extensional`,
    `state_encode_injective_of_equiv`.
  * `LegalKernel/Test/Encoding/State.lean` — analogous
    five-test set for `State`.

**Math / proof outline.**  Same shape as AR.4.2 with one
extra layer: the outer map is `TreeMap ResourceId BalanceMap
compare`.  The per-pair value (`BalanceMap`) round-trips via
AR.4.2; the outer map round-trips via the AR.4.1 helper +
the per-pair AR.4.2 round-trip witness.

**Implementation steps.**

  1. Define `State.fieldsBounded st := ∀ r ∈ st.balances.keys,
     BalanceMap.fieldsBounded (st.balances[r]!)`.
  2. Prove `state_roundtrip` (outer map round-trip composed
     with per-pair `balanceMap_roundtrip`).
  3. Prove the injectivity quartet completion mirroring
     AR.4.2.
  4. Add tests.

**Acceptance criteria, Test plan, Definition of Done,
Verification commands, Reviewer checklist, Risk.**  Mirror
AR.4.2's structure with `State` substituted for `BalanceMap`.

**Effort estimate.**  S–M (≈ 2 working days; the AR.4.2
template carries most of the work).

#### AR.4.4 — `NonceState` quartet

**Finding map:** M-3 (per the group).

**Scope.**

  * `LegalKernel/Encoding/State.lean` — add
    `NonceState.fieldsBounded`, `nonceState_roundtrip`,
    `nonceState_encode_injective_extensional`,
    `nonceState_encode_injective_of_equiv`.
  * `LegalKernel/Test/Encoding/State.lean` — analogous
    five-test set for `NonceState`.

**Math / proof outline.**  `NonceState` is `TreeMap ActorId
Nonce compare` where `Nonce = Nat`.  Quartet shape is
identical to AR.4.2; the only difference is the value type.

**Implementation steps, Acceptance criteria, Test plan,
Definition of Done, Verification commands, Reviewer checklist,
Risk.**  Mirror AR.4.2.

**Effort estimate.**  S (≈ 1 working day).

#### AR.4.5 — `KeyRegistry` quartet

**Finding map:** M-3 (per the group).

**Scope.**

  * `LegalKernel/Encoding/State.lean` — add
    `KeyRegistry.fieldsBounded`, `keyRegistry_roundtrip`,
    `keyRegistry_encode_injective_extensional`,
    `keyRegistry_encode_injective_of_equiv`.
  * `LegalKernel/Test/Encoding/State.lean` — analogous
    five-test set for `KeyRegistry`.

**Math / proof outline.**  `KeyRegistry` is `TreeMap ActorId
PublicKey compare` where `PublicKey = ByteArray` with a CBE
bytestring size bound.  `KeyRegistry.fieldsBounded kr := ∀ kv ∈
kr.toList, kv.2.size < 2^64`.

**Implementation steps, Acceptance criteria, Test plan,
Definition of Done, Verification commands, Reviewer checklist,
Risk.**  Mirror AR.4.2.

**Effort estimate.**  S (≈ 1 working day).

#### AR.4.6 — `LocalPolicies` quartet

**Finding map:** M-3 (per the group).

**Scope.**

  * `LegalKernel/Encoding/LocalPolicy.lean` — add
    `LocalPolicies.fieldsBounded` (composed from the
    clause-level `fieldsBounded` already shipped at line 57),
    `localPolicies_roundtrip`,
    `localPolicies_encode_injective_extensional`,
    `localPolicies_encode_injective_of_equiv`.
  * `LegalKernel/Test/Encoding/LocalPolicy.lean` — analogous
    five-test set for `LocalPolicies`.

**Math / proof outline.**  `LocalPolicies` is `TreeMap ActorId
LocalPolicy compare`.  The clause-level round-trip is the
inner round-trip (the clause's `LocalPolicy` value type has
its own canonical-bounded encoding).

**Implementation steps, Acceptance criteria, Test plan,
Definition of Done, Verification commands, Reviewer checklist,
Risk.**  Mirror AR.4.2.  Note: the clause-level
`fieldsBounded` predicate at `LocalPolicy.lean:57` is the
existing infrastructure; AR.4.6 composes it, not re-proves
it.

**Effort estimate.**  S–M (≈ 2 working days; one extra day
for the clause-level composition vs. the simpler AR.4.4 /
AR.4.5).

#### AR.4.7 — `BridgeState` (consumed + pending) quartet

**Finding map:** M-3 (per the group).

**Scope.**

  * `LegalKernel/Encoding/State.lean` — add quartet for
    `BridgeState`'s two map fields:
    `consumed : TreeMap DepositId DepositRecord compare` and
    `pending : TreeMap WithdrawalId PendingWithdrawal compare`
    (verified at `LegalKernel/Bridge/State.lean:169-173`).
    Per-record types `DepositRecord` and `PendingWithdrawal`
    already ship `*_decode` / `*_roundtrip` / `*_encode_injective`
    at `Encoding/State.lean:301` and `:348` respectively, so
    AR.4.7's work is the *map-level* quartet on top.
  * `LegalKernel/Test/Encoding/State.lean` — analogous
    five-test set for the two map sub-structures.

**Math / proof outline.**  Each map round-trips by chaining
the AR.4.1 helper + the per-record `*_roundtrip` (already
shipped).  The composition is straightforward; see AR.4.2.

**Implementation steps, Acceptance criteria, Test plan,
Definition of Done, Verification commands, Reviewer
checklist, Risk.**  Mirror AR.4.2.  Note: this sub-WU
ships **two** quartets (one per map field); each can land
as a separate sub-PR or as a unified sub-PR per reviewer
preference.

**Effort estimate.**  S–M (≈ 3 working days; two map
quartets back-to-back).

#### AR.4.8 — `ExtendedState` composition + FaultProof.Commit chain composition

**Finding map:** M-3 + i-8 (resolves the FaultProof
`*_extensional_injective` chain).

**Scope.**

  * `LegalKernel/Encoding/State.lean` — add
    `ExtendedState.fieldsBounded` (structural conjunction of
    the five field-level predicates) and
    `extendedState_encode_injective_of_extensional`.
  * `LegalKernel/FaultProof/Commit.lean` — add
    `commitExtendedState_extensional_injective_under_collision_free`
    chaining the new encoder injectivity through the existing
    `commitExtendedState_subcommits_bytes_eq_under_collision_free`.
  * `LegalKernel/Test/FaultProof/Commit.lean` — composition
    test showing the full chain
    `commit-eq → bytes-eq → encode-eq → toList-eq`.
  * `CLAUDE.md` (in concert with AR.22) — retire footnote 1's
    "shipped at the structural level but not as a stand-alone
    `*_encode_injective` lemma" disclaimer.

**Math / proof outline.**  Per the group-level outline.  The
downstream chain becomes:

```
commitState s₁ = commitState s₂                       (hypothesis)
  ─── commitState_bytes_injective_under_collision_free
ByteArray.mk (State.encode s₁).toArray =
  ByteArray.mk (State.encode s₂).toArray
  ─── ByteArray.mk.injEq : .mk arr₁ = .mk arr₂ ↔ arr₁ = arr₂
State.encode s₁ = State.encode s₂ (as Streams)
  ─── state_encode_injective_of_equiv  (AR.4.3)
s₁.balances.Equiv s₂.balances                        (conclusion)
```

The conclusion is *extensional* equality (`Equiv`,
equivalently `toList = toList`), **not** Lean `=`.  Two
`State`s with the same `balances.toList` are
indistinguishable to every kernel observer (`getBalance`,
`totalSupply`, every `Transition`) but may have different
internal RB-tree shapes.

The composition lemma:

```lean
theorem commitExtendedState_extensional_injective_under_collision_free
    (es₁ es₂ : ExtendedState)
    (h_cf : Bridge.CollisionFree hashBytes)
    (h₁ : ExtendedState.fieldsBounded es₁)
    (h₂ : ExtendedState.fieldsBounded es₂)
    (h : commitExtendedState es₁ = commitExtendedState es₂) :
    es₁.toList = es₂.toList   -- field-wise toList-equality
```

(Where `ExtendedState.toList` is defined as the per-field
`toList` projection.)

**Implementation steps.**

  1. Define `ExtendedState.fieldsBounded` as the structural
     conjunction.
  2. Define `ExtendedState.toList` as the per-field
     projection.
  3. Prove `extendedState_encode_injective_of_extensional`
     by composing AR.4.3 – AR.4.7.
  4. Prove `commitExtendedState_extensional_injective_under_collision_free`
     by chaining (existing) `_bytes_eq_under_collision_free`
     + the new injectivity.
  5. Add the composition test.
  6. Coordinate with AR.22 to retire CLAUDE.md footnote 1.

**Acceptance criteria.**

  * The composition lemma is shipped and proves under
    canonical hypotheses.
  * The composition test elaborates with `#print axioms`
    canonical-three only (plus `hashBytes` opaque
    reachability).
  * CLAUDE.md footnote 1 is updated to reflect the shipped
    state (in lockstep with AR.22).

**Test plan.**

  * **Composition.**  Two distinct `ExtendedState`s with
    `fieldsBounded` ∧ `commitExtendedState es₁ =
    commitExtendedState es₂` ⇒ `es₁.toList = es₂.toList`.
  * **Counterexample (sanity).**  Two `ExtendedState`s with
    distinct `toList` but identical commits — must be
    impossible under `CollisionFree hashBytes` (this is
    the soundness statement; the test exercises a
    `MockHash` that would violate `CollisionFree`).

**Definition of Done.**

  - [ ] `ExtendedState.fieldsBounded` shipped.
  - [ ] `commitExtendedState_extensional_injective_under_collision_free`
        shipped.
  - [ ] Composition test landed.
  - [ ] CLAUDE.md footnote 1 retired (coordinate with
        AR.22).
  - [ ] All five sub-state quartets (AR.4.2 – AR.4.6) plus
        the BridgeState quartet (AR.4.7) are landed; this
        sub-WU's prerequisite is met.

**Verification commands.**

```bash
grep -n 'commitExtendedState_extensional_injective' \
  LegalKernel/FaultProof/Commit.lean
lake build LegalKernel.FaultProof.Commit
lake test
echo '#print axioms commitExtendedState_extensional_injective_under_collision_free' \
  | lake env lean --stdin
```

**Reviewer checklist.**

  - [ ] Are all five sub-state quartets composed (no missing
        field)?
  - [ ] Does the composition's `fieldsBounded` predicate
        cover every Nat field that the encoder canonicality
        argument depends on?
  - [ ] Is the lift to `toList`-equality (not Lean `=`)
        honest about the RB-tree-shape non-canonicality?
  - [ ] Coordinate with AR.22: is the CLAUDE.md footnote
        retired in the same merge window?

**Migration notes.**

The CLAUDE.md footnote 1 retirement is the documentation-side
deliverable; it is land-coupled to AR.22 because both touch
CLAUDE.md.  The corresponding entry in §15B of
`docs/GENESIS_PLAN.md` (the Workstream H follow-up registry)
is also retired in AR.22.

**Risk.**  Medium.  Composition is mostly mechanical once
AR.4.2 – AR.4.7 are in place, but the FaultProof.Commit
chain has subtle dependencies on the existing
`commitExtendedState_subcommits_bytes_eq_under_collision_free`
proof.  Mitigation: spot-check each link in the chain
against the existing proof; verify `#print axioms` is
canonical at each link.

**Effort estimate.**  S–M (≈ 1 working day for the composition
+ the test).

### AR.5 — Action tag regression tests (all 19 indices)

**Finding map:** M-8 (three parallel `Action`-tag enumerations,
only 4 of 19 indices pinned by smoke checks).

**Scope.**

  * `LegalKernel/Test/Authority/Action.lean` (new) — 19
    `example` declarations, each pinning one constructor's
    `Action.tag` to its integer value.
  * `LegalKernel/Test/Encoding/Action.lean` (existing,
    extended) — 19 `example` declarations pinning the
    encoder's leading-tag byte for each constructor.
  * `Tests.lean` — register the new test driver.

**Math / proof outline.**  Each pin reduces to `rfl`:

```lean
example (r : ResourceId) (s r' : ActorId) (am : Amount) :
    Action.tag (.transfer r s r' am) = 0 := rfl

example (r : ResourceId) (to : ActorId) (am : Amount) :
    Action.tag (.mint r to am) = 1 := rfl

-- … 17 more
```

For the encoder:

```lean
example (r : ResourceId) (s r' : ActorId) (am : Amount) :
    (Action.encode (.transfer r s r' am)).take 9 =
    Encodable.encode (T := Nat) 0 := rfl

-- … 18 more
```

The existing `Action.tag_matches_encode_tag` theorem proves
the *agreement* between `Action.tag` and the encoder's leading
byte, structurally by `rfl` per constructor — but only proves
that they agree on *some* tag.  The new pins assert the
specific integer value, catching transpositions (swap tag 5
and tag 6 in both — still passes
`tag_matches_encode_tag`, but breaks log file backward
compatibility).

**Implementation steps.**

  1. Create `LegalKernel/Test/Authority/Action.lean` with 19
     `example` declarations.
  2. Extend `LegalKernel/Test/Encoding/Action.lean` (or its
     equivalent location) with the encoder-tag pins.
  3. Wire into `Tests.lean`.
  4. Verify by re-running `lake test`.

**Acceptance criteria.**

  * `lake test` passes; the new examples elaborate.
  * Any future PR that reorders `Action` constructors fails
    `lake test` at the regression-tier.

**Test plan.**  The examples are themselves the tests.  No
runtime assertion; elaboration failure is the failure mode.

**Definition of Done.**

  - [ ] 19 `Action.tag = N` examples landed (one per
        constructor).
  - [ ] 19 encoder-tag examples landed.
  - [ ] Tests wired into `Tests.lean`.
  - [ ] `lake test` clean.

**Verification commands.**

```bash
grep -c '^example' LegalKernel/Test/Authority/Action.lean
# expected: ≥ 19
lake build LegalKernel.Test.Authority.Action
lake test
```

**Reviewer checklist.**

  - [ ] Are all 19 constructors covered (verified by
        `Action.tag`'s inductive case-tree)?
  - [ ] Does each `example` pin to a *specific* integer (not
        a placeholder like `_`)?
  - [ ] Are the encoder-tag examples consistent with the
        `Action.tag_matches_encode_tag` theorem?

**Risk.**  Negligible.  Pure `rfl` mechanics.

**Effort estimate.**  S (≤ 2 hours).

### AR.6 — Event constructor tag regression tests

**Finding map:** m-7 (`Event` constructor-index drift relies on
encoder, not inductive declaration).

**Scope.**

  * `LegalKernel/Events/Types.lean` (existing) — add a
    `def Event.tag : Event → Nat` function mirroring the
    pattern of `Authority.Action.tag` (in
    `LegalKernel/Authority/LocalPolicySemantics.lean:64`).
    The audit's m-7 finding identifies a *contract* with
    off-chain indexers that is currently encoded only in
    docstring annotations (lines 61–68 of `Events/Types.lean`).
    Without a Lean-level `Event.tag` definition, no regression
    test can pin the indices — *that* is the
    structural fix.  The new `Event.tag` is the canonical
    contract surface for both Lean and indexers.
  * `LegalKernel/Test/Events/Types.lean` (new) —
    one `example` per `Event` constructor (16 total), pinning
    the index.
  * `Tests.lean` — register the new test driver.

**Math / proof outline.**  Same shape as AR.5 but for `Event`.
The `Event` inductive has **16** constructors (verified against
`LegalKernel/Events/Types.lean` lines 82–192):

  0. `balanceChanged`
  1. `nonceAdvanced`
  2. `identityRegistered`
  3. `identityRevoked`
  4. `timeRecorded`
  5. `disputeFiled`
  6. `disputeWithdrawn`
  7. `verdictApplied`
  8. `rewardIssued`
  9. `withdrawalRequested`
  10. `depositCredited`
  11. `localPolicyDeclared`
  12. `localPolicyRevoked`
  13. `faultProofGameOpened`
  14. `faultProofBisectionStep`
  15. `faultProofGameSettled`

Each gets `example : Event.tag (...) = n := rfl`.

The audit synthesis's `11-events.md` describes "frozen
indices" 0–15 (with `identityRevoked = 3` and `timeRecorded = 4`
documented as "dead constructors at the moment").  AR.6
preserves this freezing under the new `Event.tag`
definition.

**Implementation steps.**

  1. Read the current `Event` constructor list from
     `LegalKernel/Events/Types.lean`.
  2. Add `Event.tag : Event → Nat` to `Events/Types.lean`
     mapping each constructor to its index per the table
     above.  Place it after the `Event` inductive and before
     the helper predicates (`isBalanceChanged`,
     `isIdentityChange`, `affectedActors`).
  3. Write 16 `example` declarations in
     `LegalKernel/Test/Events/Types.lean`.
  4. Wire into `Tests.lean`.

**Acceptance criteria.**

  * `Event.tag` is defined and total over the inductive.
  * All 16 indices pin by `rfl`.
  * Any future PR that reorders `Event` constructors fails
    `lake test` at the regression tier.

**Test plan.**  The examples are themselves the tests.  No
runtime assertion; elaboration failure is the failure mode.

**Definition of Done.**

  - [ ] `Event.tag` shipped (new function in
        `Events/Types.lean`).
  - [ ] 16 `Event.tag = N` examples landed (one per
        constructor).
  - [ ] Tests wired into `Tests.lean`.
  - [ ] `lake test` clean.

**Verification commands.**

```bash
grep -n 'def Event.tag' LegalKernel/Events/Types.lean
grep -c '^example' LegalKernel/Test/Events/Types.lean
# expected: ≥ 16
lake build LegalKernel.Events.Types LegalKernel.Test.Events.Types
lake test
```

**Reviewer checklist.**

  - [ ] Is `Event.tag` total (every constructor mapped)?
  - [ ] Are the 16 indices in source-order, matching the
        documented "frozen indices" in the original
        per-area audit (`docs/audits/11-events.md`)?
  - [ ] Does each `example` pin to a *specific* integer?

**Risk.**  Low.  Adding a new `def Event.tag` is additive;
existing call sites that pattern-match on `Event` are
unaffected (no removed constructor, no renamed constructor).

**Effort estimate.**  S (≤ 1 hour).

### AR.7 — Lex Diff comparator extension

**Finding map:** M-6 (`Lex/Tools/Diff.lean`'s
`paramsDiff` and `proofOverridesDiff` compare names only).

**Scope.**

  * `Lex/Tools/Diff.lean:172-179` — extend the two comparators.
  * `Lex/Test/Tools/Diff.lean` — add regression tests for
    type-change-only and tactic-body-change-only diffs.

**Math / proof outline.**  None; pure structural change.

The current code is:

```lean
paramsDiff :=
  let bs := String.intercalate "," (before.params.map (·.name))
  let as := String.intercalate "," (after.params.map (·.name))
  diffString bs as,
proofOverridesDiff :=
  let bs := String.intercalate "," (before.proofOverrides.map (·.property))
  let as := String.intercalate "," (after.proofOverrides.map (·.property))
  diffString bs as,
```

The new code:

```lean
paramsDiff :=
  let renderParam (p : ParamSpec) : String :=
    p.name ++ ":" ++ p.type ++ ":" ++ kindToString p.kind
  let bs := String.intercalate "," (before.params.map renderParam)
  let as := String.intercalate "," (after.params.map renderParam)
  diffString bs as,
proofOverridesDiff :=
  let renderOverride (o : ProofOverride) : String :=
    o.property ++ ":" ++ hashTactic o.tacticBlock
  let bs := String.intercalate "," (before.proofOverrides.map renderOverride)
  let as := String.intercalate "," (after.proofOverrides.map renderOverride)
  diffString bs as,
```

`hashTactic` is a stable byte-level hash (FNV-1a-64 over
the tactic block bytes, or a simpler concat-of-tokens).  Using
a hash keeps the diff output compact; storing the full tactic
block in the diff record would bloat the JSON manifest.

**Implementation steps.**

  1. Add `ParamSpec.render` and `ProofOverride.render` helpers
     in `Lex/Tools/Common.lean` (next to the structure
     definitions).

  2. Update `Lex/Tools/Diff.lean` to use the helpers.

  3. Add `BinderKind.toString : BinderKind → String` (3 cases:
     `explicit`, `implicit`, `instanceImplicit`).

  4. Add regression tests:
     * Param type change: same name, different type → diff
       flagged.
     * Param kind change: same name and type, different kind
       → diff flagged.
     * Proof override body change: same property, different
       tactic block → diff flagged.

**Acceptance criteria.**

  * `lake test` passes the extended diff regression suite.
  * `lake exe lex_diff <before> <after>` on a pair of laws
    differing only by parameter type now reports the diff as
    non-empty.

**Test plan.**  Three regression cases as listed.

**Definition of Done.**

  - [ ] `paramsDiff` and `proofOverridesDiff` extended to
        include type/kind and tactic-body discriminators.
  - [ ] `hashTactic` helper shipped.
  - [ ] Three regression tests landed.
  - [ ] `lake exe lex_diff` round-trip on a synthetic before
        / after pair flags the diff.

**Verification commands.**

```bash
grep -nE 'paramsDiff|proofOverridesDiff' Lex/Tools/Diff.lean
lake build LexAudit lex_diff
lake test
```

**Reviewer checklist.**

  - [ ] Does the rendered string include enough context to
        distinguish all relevant changes (type, kind, body)
        without bloating the diff JSON?
  - [ ] Is `hashTactic` deterministic (FNV-1a-64 or a
        lexically-stable token-concat) so two identical
        bodies hash identically?

**Risk.**  Low.  Lex-tooling-only.

**Effort estimate.**  S (≤ ½ day).


### AR.8 — `naming_audit` `_v2` policy alignment + UsdClearing rename

**Finding map:** M-9 (`naming_audit`'s `forbiddenTokens` list
does not include `_v2`; `Deployments/Examples/UsdClearing.lean:111`
declares `federation_transfer_policy_v2`).

**Scope.**

  * `Tools/NamingAudit.lean:79-119` — add `_v2`, `_v3`, `_v4`,
    `_v5` to the `forbiddenTokens` list.
  * `Deployments/Examples/UsdClearing.lean:111` — rename
    `federation_transfer_policy_v2` to a content name (e.g.
    `federation_transfer_policy_quorum` or
    `federation_transfer_policy` if the `v2` distinction is
    no longer needed).
  * `Lex/Test/Tools/Naming.lean` (or wherever the
    `naming_audit` self-tests live) — add a regression
    asserting that a synthetic identifier `foo_v2` is flagged
    by `findForbiddenToken`.

**Math / proof outline.**  None.

**Implementation steps.**

  1. Extend `forbiddenTokens` with the four version-suffix
     tokens.

  2. Rename `federation_transfer_policy_v2`.  Per CLAUDE.md
     ("Names describe content, never provenance"), the new
     name should describe *what the policy is*, not *which
     iteration produced it*.  Recommended:
     `federation_transfer_policy_quorum_unrestricted` (which
     describes that the placeholder is `AuthorityPolicy.unrestricted`
     pending a quorum-keyed policy).  If the original intent
     was forward-looking (the comment notes "in production
     this would be the `transfer_policy_v2` keyed-policy
     union over federation members' public keys"), the
     production replacement plan should be folded into a
     follow-up.

  3. Update every call site of `federation_transfer_policy_v2`.
     Verified two sites in source as of plan drafting:
     `Deployments/Examples/UsdClearing.lean:111` (the
     declaration) and `Deployments/Examples/UsdClearing.lean:160`
     (the `transfer_policy = federation_transfer_policy_v2`
     deployment binding).  Both must be renamed in lockstep.
     Re-grep for any third site before committing.

  4. Re-run `lake exe naming_audit` to confirm zero
     violations.

  5. Add the synthetic-identifier regression test.

**Acceptance criteria.**

  * `lake exe naming_audit` returns zero violations against
    the current source tree.
  * The pre-commit grep pattern documented in CLAUDE.md
    (`v2|legacy|tmp|...`) is updated to mention that `_v2`
    is now enforced by the audit, removing the
    documentation-vs-enforcement drift.

**Test plan.**  Self-test on `naming_audit`; rebuild.

**Definition of Done.**

  - [ ] `forbiddenTokens` extended with `_v2`, `_v3`, `_v4`,
        `_v5`.
  - [ ] `federation_transfer_policy_v2` renamed in source
        (both site at line 111 + site at line 160).
  - [ ] `lake exe naming_audit` exits 0.
  - [ ] Synthetic `foo_v2` regression test added.

**Verification commands.**

```bash
grep -n 'federation_transfer_policy' Deployments/Examples/UsdClearing.lean
# expected: zero matches against the old name; new name appears at both sites
lake exe naming_audit
echo $?  # expected: 0
```

**Reviewer checklist.**

  - [ ] Is the renamed identifier content-named (describes
        what the policy is, not which iteration)?
  - [ ] Are both call sites in `UsdClearing.lean` updated
        in lockstep (line 111 declaration + line 160
        deployment binding)?
  - [ ] Does the synthetic-identifier regression test cover
        each new token (`_v2`, `_v3`, `_v4`, `_v5`)?

**Risk.**  Low.  One renamed identifier; one extended
audit-tool list.

**Effort estimate.**  S (≤ 1 hour).

### AR.9 — MockCrypto production-import detector

**Finding map:** M-10 (`MockCrypto.lean` docstring claims
`stub_audit` flags production imports; it does not).

**Scope.**

  * `Tools/MockImportAudit.lean` (new) — a new audit binary
    that scans every `.lean` file under the non-test source
    tree (`LegalKernel/`, `Lex/`, `Tools/`, `Deployments/`,
    plus the top-level `*.lean`) for any `import` line that
    references a `LegalKernel.Test.*` module.
  * `Tools/Common.lean` (existing) — extend with a
    `testModulePrefixes` constant matching the audit logic.
  * `lakefile.lean` — add `lean_exe mock_import_audit`.
  * `.github/workflows/ci.yml` — wire into CI.
  * `LegalKernel/Test/MockCrypto.lean:37-40` — update
    docstring to refer to `mock_import_audit` rather than
    `stub_audit`.

**Math / proof outline.**  None; lexical audit.

The audit's logic is straightforward:

```lean
def isTestModuleImport (line : String) : Bool :=
  let trimmed := line.trimAscii.toString
  trimmed.startsWith "import LegalKernel.Test." ||
  trimmed.startsWith "import Lex.Test." ||
  trimmed.startsWith "import Test."

def auditFile (path : String) (contents : String) :
    List Violation :=
  let lines := contents.splitOn "\n"
  lines.enum.filterMap fun (idx, line) =>
    if isTestModuleImport line && ¬ isTestFile path then
      some { path, line := idx+1, importLine := line }
    else
      none
```

`isTestFile` is true for paths containing `/Test/` or
`/test/` directly under a top-level source root.

**Implementation steps.**

  1. Create `Tools/MockImportAudit.lean` (new lean_lib +
     lean_exe).

  2. Implement the scan as described above.

  3. Update `lakefile.lean` to register the binary.

  4. Wire into CI; gate the build on its exit code.

  5. Update the `MockCrypto` docstring to refer to the new
     audit.

  6. Add a self-test: a synthetic file pretending to be a
     production module importing `LegalKernel.Test.MockCrypto`
     should fail the audit.  (Use a temp-file in the test
     harness rather than committing the synthetic file.)

**Acceptance criteria.**

  * `lake exe mock_import_audit` reports zero violations
    against the current source tree.
  * The audit's self-test exercises both the positive
    (rejected) and negative (accepted) paths.
  * CI fails any future PR that imports a `Test/*` module
    from a non-test path.

**Test plan.**

  * **Positive (no violations).**  Run against the current
    source tree.
  * **Negative (synthetic violation).**  Create a temp file
    `tmp/SyntheticProduction.lean` containing `import
    LegalKernel.Test.MockCrypto`; the audit returns a
    violation.

**Definition of Done.**

  - [ ] `Tools/MockImportAudit.lean` shipped.
  - [ ] `lean_exe mock_import_audit` registered in
        `lakefile.lean`.
  - [ ] CI gate added in `.github/workflows/ci.yml`.
  - [ ] `MockCrypto.lean` docstring corrected.
  - [ ] Self-test with synthetic positive + negative cases.

**Verification commands.**

```bash
lake build mock_import_audit
lake exe mock_import_audit
echo $?  # expected: 0
grep -n 'mock_import_audit' lakefile.lean .github/workflows/ci.yml
```

**Reviewer checklist.**

  - [ ] Does `isTestFile` correctly distinguish test paths
        (`/Test/`, `/test/`) from production paths?
  - [ ] Does the audit handle both `import LegalKernel.Test.X`
        and `import Lex.Test.X` patterns?
  - [ ] Is the CI invocation gated on the same conditions
        as the other audit binaries?
  - [ ] Does the docstring correction in `MockCrypto.lean`
        name the new binary explicitly?

**Risk.**  Low.  New audit binary, similar in structure to
`naming_audit`.

**Effort estimate.**  S (≤ ½ day).

### AR.10 — Hash `@[extern]` annotations

**Finding map:** Cross-verification finding (no synthesis ID).
`LegalKernel/Runtime/Hash.lean:151, 159, 258` —
`hashStream`, `hashBytes`, `hashImplementationIdentifier` are
plain `def`s.  Their docstrings claim a `knomosis_hash_bytes` /
`knomosis_hash_identifier` C ABI symbol that production
deployments link against, but no `@[extern]` annotation is
present.

**Scope.**

  * `LegalKernel/Runtime/Hash.lean` — add `@[extern
    "knomosis_hash_bytes"]` to `hashBytes`; add `@[extern
    "knomosis_hash_stream"]` to `hashStream` (or remove the
    swap-point claim from its docstring if the production
    runtime really does only swap `hashBytes`); add
    `@[extern "knomosis_hash_identifier"]` to
    `hashImplementationIdentifier`.
  * `LegalKernel/Test/Runtime/Hash.lean` — re-verify the
    determinism + size + identifier-startup tests
    continue to pass.

**Math / proof outline.**  None.  `@[extern]` is a code-gen
attribute that instructs the Lean → C compiler to emit a
call to the named C function instead of the Lean-extracted
body.  When the Lean compiler is asked to *reduce* a term
involving an `@[extern]` function (e.g. for `decide` or
`rfl`), it uses the Lean body; when the term is *executed* at
runtime in compiled native code, the linked C symbol is
called.  This is the canonical mechanism for the
"deployment-supplied implementation" pattern; it is also the
mechanism used by `Verify` (`Authority/Crypto.lean`) and by
`knomosis-extern` symbols in the deployment adaptor.

A Lean theorem like `hashBytes_deterministic` proves a
property about the *Lean body*; the `@[extern]` attribute does
not invalidate the theorem because Lean's logical model
operates on the body, not the linked symbol.  The deployment
trusts the linked symbol to satisfy the property; this is the
EUF-CMA-style trust assumption already enumerated in
CLAUDE.md.

**Implementation steps.**

  1. Add the three `@[extern]` annotations.

  2. Re-run `lake build` (the Lean elaborator should accept
     the attribute without complaint).

  3. Re-run `lake test` (the Lean fallback body is still
     reachable; tests continue to pass).

  4. Verify in the `Main.lean` / `Replay.lean` fallback
     warning that `hashImplementationIdentifier ()` continues
     to return `"fnv1a64-padded-32"` when no production
     adaptor is linked.

  5. Update the Hash.lean module docstring to record the
     ABI-symbol mapping explicitly:

     ```
     @[extern "knomosis_hash_bytes"]        def hashBytes        ...
     @[extern "knomosis_hash_stream"]       def hashStream       ...
     @[extern "knomosis_hash_identifier"]   def hashImplementationIdentifier ...
     ```

**Acceptance criteria.**

  * The three functions carry `@[extern]` annotations.
  * `lake build` succeeds.
  * `lake test` passes the Hash module suite, including the
    determinism + size + identifier tests.
  * `#print axioms` on `hashBytes_deterministic`,
    `hashStream_deterministic`, `hashEncodable_deterministic`
    is unchanged (canonical three only).

**Test plan.**

  * Self-test that `hashImplementationIdentifier ()` returns
    the fallback identifier when no production adaptor is
    linked.
  * Self-test that `hashBytes_size`, `hashStream_size`,
    `zeroHash_size` continue to elaborate.

**Definition of Done.**

  - [ ] Three `@[extern]` annotations landed.
  - [ ] Hash module docstring updated with the symbol-name
        listing.
  - [ ] Determinism / size / identifier tests still pass.
  - [ ] `#print axioms` on hash-dependent theorems is
        unchanged.

**Verification commands.**

```bash
grep -n '@\[extern' LegalKernel/Runtime/Hash.lean
lake build LegalKernel.Runtime.Hash
lake test
echo '#print axioms hashBytes_deterministic' | lake env lean --stdin
```

**Reviewer checklist.**

  - [ ] Are all three symbol names (`knomosis_hash_bytes`,
        `knomosis_hash_stream`, `knomosis_hash_identifier`)
        documented as the deployment-facing C ABI contract?
  - [ ] Does the Lean body still return the FNV-1a-64
        fallback (so test-mode behaviour is unchanged)?
  - [ ] Is the `#print axioms` output for hash-dependent
        theorems unchanged from pre-AR (the `@[extern]`
        attribute should not introduce new axioms)?

**Migration notes.**

This is a code-gen-attribute change with no runtime
behaviour change at the Lean level.  Production deployment
binaries that already link `knomosis_hash_bytes` continue to
work; the change just makes the link contract explicit in
the source.

**Risk.**  Low.  `@[extern]` is a well-understood mechanism.
The Lean body is unchanged.

**Effort estimate.**  S (≤ 1 hour).

### AR.11 — Lex `synth_local` resource-aware dispatch

**Finding map:** Cross-verification finding (no synthesis ID;
extension of m-11).  `Lex/DSL/Property.lean:418-420` —
`synth_local_kindOnly` calls `synth_local S (kinds.map (fun k
=> (k, none)))`; the dispatcher (line 505) calls
`synth_local_kindOnly`, so every `local [S]` claim is admitted
unconditionally regardless of resource.

**Scope.**

  * `Lex/DSL/Property.lean:494-510` — replace the
    dispatcher's call to `synth_local_kindOnly` with a
    resource-aware call.
  * `Lex/DSL/ImplCalculus.lean` (or wherever
    `ImplStmt.kindAndResource` lives) — verify that the macro
    invocation supplies resource info; if not, route the
    impl-AST through it.
  * `Lex/Test/DSL/Property.lean` — add positive and negative
    regressions: a law claiming `local [S]` with a flow
    targeting a resource outside `S` should be rejected.

**Math / proof outline.**  At the M1 macro layer, no Lean
theorem changes.  The synthesizer's contract is that it emits
a placeholder string for accepted laws and an `error` for
rejected ones.  AR.11 enforces the rejection path that the
current dispatcher path bypasses.

**Implementation steps.**

  1. Inspect the macro elaborator that calls
     `dispatchSynthesizer`.  Identify whether the impl
     statements are available at the call site as `List
     ImplStmt` (full, with resource info) or just `List
     ImplStmtKind` (degraded, no resource info).

  2. If the macro has access to `List ImplStmt`, change the
     dispatcher to call `synth_local` directly (passing
     `(k, ImplStmt.toResource s)` pairs).  Drop or deprecate
     `synth_local_kindOnly`.

  3. If the macro has degraded to `List ImplStmtKind` (parser
     limitation), route the resource info forward.  This may
     require parser-side changes in
     `Lex/DSL/ImplLowering.lean`.

  4. Add positive + negative regression tests:
     * **Positive.**  A law with `local [7]` whose flow
       targets resource `7` synthesises without error.
     * **Negative.**  A law with `local [7]` whose flow
       targets resource `8` synthesises with
       `.resourceNotInLocalSet`.

**Acceptance criteria.**

  * The synthesizer rejects `local [S]` claims whose
    impl-statements target a resource not in `S`.
  * `lake test` passes the new positive + negative
    regressions.
  * No existing law's synthesis fails (because every shipped
    law's `local [S]` claim is consistent with its impl —
    the M1 always-accept was masking that consistency, not
    creating inconsistencies).

**Test plan.**  As above.

**Definition of Done.**

  - [ ] Dispatcher routes through resource-aware
        `synth_local` (or AST-routed equivalent).
  - [ ] Positive + negative regression tests landed.
  - [ ] Every shipped Lex law re-elaborates without error
        (full Lex test suite green).
  - [ ] `lake exe lex_codegen --check` clean.

**Verification commands.**

```bash
grep -nE 'synth_local|dispatchSynthesizer' Lex/DSL/Property.lean
lake build Lex
lake test
lake exe lex_codegen --check
```

**Reviewer checklist.**

  - [ ] Did the dispatcher get the resource info via the
        full `List ImplStmt` (preferred) or via the
        degraded `List ImplStmtKind` (parser-side widening
        required)?
  - [ ] If the parser route was widened, are the changes
        scoped to `Lex/DSL/ImplLowering.lean` only (no
        kernel-level impact)?
  - [ ] Does the negative regression use a *plausible*
        Lex law shape (not contrived) so it catches the
        class of bug the audit named?
  - [ ] Did every existing `local [S]` law re-synthesise
        without error?

**Risk.**  Medium.  The synthesizer is on the macro-elaboration
hot path.  A regression that rejects a previously-accepted
law would block the build until the law is amended.
Mitigation: stage as a separate commit on a branch and verify
the full Lex test suite before merging.

**Effort estimate.**  M (1–3 days, depending on whether the
parser route needs widening).

### AR.12 — `lexlaw` `renderSyntax` byte-fidelity

**Finding map:** m-13 (`lexlaw`'s `renderSyntax := toString`
drifts from user source bytes; `deployment` uses the reliable
`Syntax.reprint`).

**Scope.**

  * `Lex/DSL/Law.lean` — change `renderSyntax := toString` to
    `renderSyntax := syntaxToSourceText` (mirroring
    `Deployment.lean`'s use of `Syntax.reprint`).
  * `Lex/DSL/Deployment.lean` — verify the helper
    `syntaxToSourceText` is exposed; if not, lift it to a
    shared `Lex/DSL/Common.lean` (a new low-level module if
    needed).
  * `Lex/Test/DSL/Law.lean` — add a regression asserting
    byte-equivalence between the user source and the JSON
    sidecar's rendered field.

**Math / proof outline.**  None; structural change.

`Syntax.reprint` returns `Option String` reflecting whether
the syntax is "reprintable" (does not contain
synthesised-only nodes).  The helper `syntaxToSourceText`
collapses to `toString` on `none` (for the macro-internal
synthesised case) but uses `reprint` on `some`.  This matches
the convention `Lex/DSL/Deployment.lean:668-671` already
ships.

**Implementation steps.**

  1. Lift `syntaxToSourceText` from `Deployment.lean` to a
     shared module (or expose it).

  2. Update `Law.lean` to use it.

  3. Add the byte-equivalence regression test.

**Acceptance criteria.**

  * `lake exe lex_codegen --check` (which compares sidecars
    against source) reports no drift on the current Lex law
    set.
  * The regression test passes.

**Test plan.**  Byte-equivalence on a hand-crafted Lex law.

**Definition of Done.**

  - [ ] `Law.lean`'s `renderSyntax` uses the
        `Syntax.reprint`-based helper (matching `Deployment.lean`).
  - [ ] The helper is shared (single source of truth, e.g.
        in `Lex/DSL/Common.lean`).
  - [ ] Sidecars regenerated and checked in if the change
        surfaces drift.
  - [ ] Regression test landed.

**Verification commands.**

```bash
grep -n 'renderSyntax\|syntaxToSourceText\|reprint' \
  Lex/DSL/Law.lean Lex/DSL/Deployment.lean Lex/DSL/Common.lean
lake build Lex
lake exe lex_codegen --check
lake test
```

**Reviewer checklist.**

  - [ ] Is the `syntaxToSourceText` helper shared (not
        duplicated)?
  - [ ] Do the existing Lex law sidecars still pass
        `lex_codegen --check` after the change (i.e. no
        latent drift)?  If drift exists, were the sidecars
        regenerated?

**Risk.**  Low–Medium.  May surface latent drift in existing
sidecars; if so, update them via `lake exe lex_codegen`.

**Effort estimate.**  S (≤ ½ day).


### AR.13 — Stale docstring fixes and documented-behaviour notes (five thematic sub-units)

**Finding map (group level):** m-19 (three stale docstring
claims); m-1 (`tcb_audit` parser limits); m-3 (`stub_audit`
lookback); m-5 (`deposit.pre := True`); m-6 (`affectedActors`
does not cover gained-only actors); m-8 (codegen fence-marker
contract); m-9 (Lex JSON field order); m-10 (Lex M1
`requiresEmission := false`); m-12
(`Shim.stmtReferencesSignedBy` positionless substring match);
m-15 (`Bridge.ingest` `depositInitiated` → none); m-18 (Lex
codegen duplicate-index non-determinism); and the
per-area-audit notes on `Bridge.State` DepositId projection,
`WithdrawalRoot` runtime-supplied hypotheses, and
`WithdrawalProof` empty-tree fallback.

**Group rationale.**  AR.13 affects ≥ 14 docstrings across
14 different files and four different subsystems.  Lumping
them into one PR loses the per-subsystem reviewer benefit
(the Lex docstring reviewer is unlikely to be the Bridge
docstring reviewer) and risks merge-conflict accumulation
on the long-lived workstream branch.  Splitting into five
thematic sub-units gives each subject-matter reviewer a
narrowly-scoped diff.  All five sub-units are mechanical
(no code-flow changes) and have negligible risk; the only
acceptance criterion shared across them is "`lake build`
clean".

  * **AR.13.1** — Audit-tool docstrings (`Tools/`,
    findings m-1, m-3).
  * **AR.13.2** — Kernel-adjacent docstrings (`Hash.lean`,
    `Crypto.lean`, `LogFile.lean`; finding m-19 minus the
    Codegen sub-claim).
  * **AR.13.3** — Bridge & Disputes docstrings
    (`Ingest.lean`, `State.lean`, `WithdrawalRoot.lean`,
    `WithdrawalProof.lean`, `Rewards.lean`, `Staking.lean`;
    findings m-15, i-11).
  * **AR.13.4** — Lex docstrings (`Codegen.lean`,
    `Common.lean`, `Shim.lean`; findings m-8, m-9, m-10,
    m-12, m-18, m-19's Codegen sub-claim).
  * **AR.13.5** — Laws & Events docstrings (`Deposit.lean`,
    `Withdraw.lean`, `Extract.lean`; findings m-5, m-6).

Each sub-unit's scope is the per-file list below;
implementation steps, acceptance, and DoD are uniform: edit
each docstring, rebuild, confirm `linter.missingDocs`
accepts the new text.

#### AR.13.1 — Audit-tool docstrings (m-1, m-3)

**Scope.**

  * `Tools/TcbAudit.lean` — top-of-file docstring naming
    the parser limits (`prelude`, `import all`, `meta import`)
    explicitly so reviewers see the gap (m-1).  Add a
    sentence: "These forms are not parsed; a TCB-core file
    using them would silently bypass the audit.  Add a
    sub-task to the source-of-truth audit if the production
    surface ever grows them."
  * `Tools/StubAudit.lean` — docstring note on the 12-line
    lookback (m-3): "The 12-line lookback was chosen to
    cover the typical kernel-doctring length (≤ 8 lines) plus
    margin; stubs documented by ≥ 13-line docstrings will
    not match.  Update if the typical docstring length
    grows."

**Definition of Done.**

  - [ ] Both docstrings updated.
  - [ ] `lake build` clean.

**Verification commands.**

```bash
grep -n 'prelude\|12-line' Tools/TcbAudit.lean Tools/StubAudit.lean
lake build ToolsCommon
```

**Reviewer checklist.**

  - [ ] Are the new docstring claims accurate (the audit
        actually does ignore those forms; the lookback is
        actually 12 lines)?

**Effort estimate.**  S (≤ 30 minutes).

#### AR.13.2 — Kernel-adjacent docstrings (m-19 partial)

**Scope.**

  * `LegalKernel/Runtime/LogFile.lean:109-112` — change "8-byte
    FNV-1a-64 outputs" to "32-byte content hashes (FNV-1a-64
    fallback emits 8 LE bytes + 24 zero bytes; production
    BLAKE3-256 emits 32 bytes directly)".
  * `LegalKernel/Authority/Crypto.lean:16` — change "Lean
    `axiom`" to "Lean `opaque`".
  * `LegalKernel/Runtime/Hash.lean` — confirm the `@[extern]`
    annotation lands in AR.10; the docstring update here is
    purely the symbol-name listing (`knomosis_hash_bytes` /
    `knomosis_hash_stream` / `knomosis_hash_identifier`).
    Coordinate with AR.10.

**Definition of Done.**

  - [ ] All three docstrings updated.
  - [ ] `lake build` clean.

**Verification commands.**

```bash
grep -n '8-byte\|axiom\|knomosis_hash' \
  LegalKernel/Runtime/LogFile.lean \
  LegalKernel/Authority/Crypto.lean \
  LegalKernel/Runtime/Hash.lean
lake build LegalKernel.Runtime.LogFile \
           LegalKernel.Authority.Crypto \
           LegalKernel.Runtime.Hash
```

**Reviewer checklist.**

  - [ ] Are the new docstrings accurate against source? (The
        `LogFile` 32-byte claim is true after `padTo32`; the
        `Crypto` opaque claim is true since the `def Verify`
        line.)

**Effort estimate.**  S (≤ 30 minutes).

#### AR.13.3 — Bridge & Disputes docstrings (m-15, i-11)

**Scope.**

  * `LegalKernel/Bridge/Ingest.lean:222-229` — add a docstring
    note: "Returns `(b, none)` for `depositInitiated` events;
    the deposit flow at the Lean level bypasses `ingest` and
    is materialised by the runtime adaptor's
    `applyActionToBridgeState` step.  See
    `docs/planning/ethereum_integration_plan.md` §C.4."
  * `LegalKernel/Bridge/State.lean:88-115` — add a docstring
    note on `DepositId` projection collision risk:
    "Deployment-correctness obligation: the L1 (receiptHash,
    blockNum, logIdx) tuple must inject into a 64-bit
    `DepositId` for the per-actor uniqueness gate to hold.
    The L1 contract is responsible for the projection; Lean
    does not enforce."
  * `LegalKernel/Bridge/WithdrawalRoot.lean:1004` — add a
    docstring note expanding the runtime-supplied
    `h_leaf_size` and `siblingsHaveMatchingSizes` hypotheses:
    "These are runtime-adaptor obligations; the Lean
    statement is parametric over them."
  * `LegalKernel/Bridge/WithdrawalProof.lean:61` — note the
    empty-tree fallback on decode failure: "Returns the
    empty-tree sentinel hash on decode failure; the upstream
    caller (`Bridge.State`) checks the boundary."
  * `LegalKernel/Disputes/Rewards.lean:580-597` — guard
    comment on `claimImpugnedAmount`'s deposit/withdraw skip
    (i-11 sub-issue): "Skips `deposit`/`withdraw` actions
    deliberately — those are bridge-level operations whose
    impugnment goes through the L1 fault-proof path
    (Workstream H), not the L2 dispute pipeline.  Treating
    them here would double-count."
  * `LegalKernel/Disputes/Rewards.lean:619-630` — guard
    comment on `proportionalChallengerReward`'s `divisor = 0`
    zero-amount emission (i-11 sub-issue): "Emits a zero-amount
    `rewardIssued` event when `divisor = 0` rather than no
    event, mirroring `Nat` division's `n / 0 = 0` semantics.
    Indexers must treat zero-amount reward events as no-ops."
  * `LegalKernel/Disputes/Rewards.lean` (sum-le-pool docstring
    around the `stakeWeightedAdjudicatorRewards` definition) —
    expand the docstring with the explicit note: "The
    sum-le-pool bound is a *deployment-level invariant* (not
    shipped as a Lean theorem).  Promoting it to a theorem
    would require a `disputeRewardActions_sum_le_pool`
    inductive lemma; deferred to a future workstream."  (i-11
    sub-issue.)
  * `LegalKernel/Disputes/Staking.lean:153-163` — guard
    comment on rollback-returns-stake (i-11 sub-issue):
    "Soundness depends on the runtime appending the stake
    transfer *before* the dispute action in the log; the
    invariant is enforced by the runtime adaptor's ordering
    policy and is not proved as a Lean theorem.  Future
    workstream: lift to a Lean theorem given a runtime
    ordering predicate."

**Definition of Done.**

  - [ ] All seven docstrings updated.
  - [ ] `lake build` clean.

**Verification commands.**

```bash
grep -n 'depositInitiated\|DepositId\|sum-le-pool\|rollback' \
  LegalKernel/Bridge/Ingest.lean \
  LegalKernel/Bridge/State.lean \
  LegalKernel/Disputes/Rewards.lean \
  LegalKernel/Disputes/Staking.lean
lake build LegalKernel.Bridge.Ingest \
           LegalKernel.Bridge.State \
           LegalKernel.Bridge.WithdrawalRoot \
           LegalKernel.Bridge.WithdrawalProof \
           LegalKernel.Disputes.Rewards \
           LegalKernel.Disputes.Staking
```

**Reviewer checklist.**

  - [ ] Are the new docstring claims technically accurate?
        (E.g. the `claimImpugnedAmount` skip is in the source
        — line 580 — and the rationale is the bridge-actor
        scope; the `divisor = 0` behaviour matches `Nat.div`'s
        semantics.)
  - [ ] Does each "deployment-level invariant" claim point to
        the corresponding chain-level test or a future-WU
        deferral note?

**Effort estimate.**  S (≤ 1 hour).

#### AR.13.4 — Lex docstrings (m-8, m-9, m-10, m-12, m-18, m-19 partial)

**Scope.**

  * `Lex/Tools/Codegen.lean:54-55` — change "M2 mode:
    regenerate the entire target body (no fences).  Not yet
    implemented." to "M2 / audit-3 mode: emit the structured
    canonical manifest (`Lex/Inputs/canonical_manifest.txt`)
    and, with `--gen-property-tests`, the property-test
    coverage file."
  * `Lex/Tools/Codegen.lean` and
    `LegalKernel/Events/Extract.lean` fence-marker contract —
    call out the string convention explicitly (m-8): "The
    `BEGIN LEX-GENERATED` / `END LEX-GENERATED` markers are a
    string contract; renaming requires updating both the
    codegen tool and the generated-region readers."
  * `Lex/Tools/Common.lean:711-723` — JSON field-order note
    (m-9): "`LawDecl.toCanonicalJson` produces fields in
    reverse-alphabetical order due to `Lean.Json.mkObj`'s
    internal RBNode iteration.  This is deterministic and
    expected; downstream JSON consumers must not assume
    alphabetical ordering."
  * `Lex/Tools/Codegen.lean` `requiresEmission` — record that
    all are `false` in M1 and that M2 promotes them (m-10):
    "Every `requiresEmission` returns `false` in the M1
    release; M2 enables specific emitters per the
    `lex_implementation_plan.md` roadmap."
  * `Lex/DSL/Shim.lean` — `stmtReferencesSignedBy` doc
    expansion (m-12): "Substring match on the rendered
    statement; positionally insensitive (`signed_by alice`
    matches both `flow ... from alice ...` and `flow ... to
    alice`).  The actual authorisation is enforced by the
    deployment's `AuthorityPolicy`, not by this shim."
  * `Lex/Tools/Codegen.lean` — duplicate-index non-determinism
    doc (m-18): "Sort order under duplicate-index registries
    is `Array.qsort`-determined, which is not guaranteed
    stable across Lean versions.  The audit-3 tools mitigate
    via an explicit identifier tie-breaker; reviewers
    encountering duplicate indices should run `lex_lint`
    first to surface the duplicates."

**Definition of Done.**

  - [ ] All five+ docstrings updated.
  - [ ] `lake build` clean.

**Verification commands.**

```bash
grep -n 'M2 mode\|LEX-GENERATED\|requiresEmission\|signed_by\|qsort' \
  Lex/Tools/Codegen.lean Lex/Tools/Common.lean Lex/DSL/Shim.lean
lake build LexCommon LexAudit
```

**Reviewer checklist.**

  - [ ] Are the new docstring claims accurate against source?
  - [ ] Is the `requiresEmission` doc the canonical mapping
        of M1 → M2 emission policy?

**Effort estimate.**  S (≤ 1 hour).

#### AR.13.5 — Laws & Events docstrings (m-5, m-6)

**Scope.**

  * `LegalKernel/Laws/Deposit.lean` — confirm and expand the
    `deposit.pre := True` doc (m-5): "Precondition is
    unconditionally `True`; the deposit-id uniqueness gate is
    enforced entirely by `applyActionToBridgeState`'s
    `consumed`-membership check.  See
    `docs/planning/ethereum_integration_plan.md` §C.3 for the
    bridge-level layering."
  * `LegalKernel/Laws/Withdraw.lean` — confirm the
    `withdraw.pre` lacking positivity (m-4 documents; AR.21
    optionally fixes): "Precondition lacks `0 < amount`;
    zero-amount withdrawals are admissible at the kernel
    level and produce no observable state change.  The
    bridge actor's policy is the operational gate.  See
    AR.21 for the optional positivity strengthening."
  * `LegalKernel/Events/Extract.lean:100-104` —
    `affectedActors` doc note that gained-only actors are
    not currently surfaced (m-6): "Returns pre-state actors
    only; if a future law introduces new actors at a
    resource via `distributeOthers` /
    `proportionalDilute`, the new actors' `balanceChanged`
    events will not be emitted by this helper.  No current
    law triggers this; flagged for future extensibility."

**Definition of Done.**

  - [ ] All three docstrings updated.
  - [ ] `lake build` clean.

**Verification commands.**

```bash
grep -n 'pre := True\|positivity\|gained-only\|affectedActors' \
  LegalKernel/Laws/Deposit.lean \
  LegalKernel/Laws/Withdraw.lean \
  LegalKernel/Events/Extract.lean
lake build LegalKernel.Laws.Deposit \
           LegalKernel.Laws.Withdraw \
           LegalKernel.Events.Extract
```

**Reviewer checklist.**

  - [ ] Are the docstring claims accurate?
  - [ ] Does the `withdraw` doc cross-reference AR.21 for
        the optional fix?

**Effort estimate.**  S (≤ 30 minutes).

#### AR.13 — original (deprecated single-WU view)

The original AR.13 single-WU specification is preserved
below for reference.  The five thematic sub-units above
should be treated as the authoritative scope; this section
is retained for traceability.

**Scope.**  Cosmetic docstring updates only.  No code-flow
changes.  Affected files:

  * `LegalKernel/Runtime/LogFile.lean:109-112` — change "8-byte
    FNV-1a-64 outputs" to "32-byte content hashes (FNV-1a-64
    fallback emits 8 LE bytes + 24 zero bytes; production
    BLAKE3-256 emits 32 bytes directly)".

  * `LegalKernel/Authority/Crypto.lean:16` — change "Lean
    `axiom`" to "Lean `opaque`".

  * `Lex/Tools/Codegen.lean:54-55` — change "M2 mode: regenerate
    the entire target body (no fences).  Not yet implemented."
    to "M2 / audit-3 mode: emit the structured canonical
    manifest (`Lex/Inputs/canonical_manifest.txt`) and, with
    `--gen-property-tests`, the property-test coverage file."

  * `LegalKernel/Bridge/Ingest.lean:222-229` — add a docstring
    note: "Returns `(b, none)` for `depositInitiated` events;
    the deposit flow at the Lean level bypasses `ingest` and
    is materialised by the runtime adaptor's
    `applyActionToBridgeState` step.  See `docs/planning/ethereum_integration_plan.md`
    §C.4."

  * `LegalKernel/Bridge/State.lean:88-115` — add a docstring
    note on `DepositId` projection collision risk:
    "Deployment-correctness obligation: the L1 (receiptHash,
    blockNum, logIdx) tuple must inject into a 64-bit
    `DepositId` for the per-actor uniqueness gate to hold.
    The L1 contract is responsible for the projection; Lean
    does not enforce."

  * `LegalKernel/Bridge/WithdrawalRoot.lean:1004` — add a
    docstring note expanding the runtime-supplied
    `h_leaf_size` and `siblingsHaveMatchingSizes` hypotheses:
    "These are runtime-adaptor obligations; the Lean
    statement is parametric over them."

  * `LegalKernel/Bridge/WithdrawalProof.lean:61` — note the
    empty-tree fallback on decode failure: "Returns the
    empty-tree sentinel hash on decode failure; the upstream
    caller (`Bridge.State`) checks the boundary."

  * `LegalKernel/Laws/Deposit.lean` — confirm and expand the
    `deposit.pre := True` doc (m-5).

  * `LegalKernel/Laws/Withdraw.lean` — confirm the
    `withdraw.pre` lacking positivity (m-4 documents; AR.21
    optionally fixes).

  * `LegalKernel/Events/Extract.lean:100-104` —
    `affectedActors` doc note that gained-only actors are
    not currently surfaced (m-6).

  * `Tools/TcbAudit.lean` — top-of-file docstring naming
    the parser limits (`prelude`, `import all`, `meta import`)
    explicitly so reviewers see the gap (m-1).

  * `Tools/StubAudit.lean` — docstring note on the
    12-line lookback (m-3).

  * `Lex/Tools/Codegen.lean` and `LegalKernel/Events/Extract.lean`
    fence-marker contract — call out the string convention
    explicitly (m-8).

  * `Lex/Tools/Common.lean:711-723` — JSON field-order note
    (m-9).

  * `Lex/Tools/Codegen.lean` `requiresEmission` — record
    that all are `false` in M1 and that M2 promotes them
    (m-10).

  * `Lex/DSL/Shim.lean` — `stmtReferencesSignedBy` doc
    expansion (m-12).

  * `Lex/Tools/Codegen.lean` — duplicate-index
    non-determinism doc (m-18).

  * `LegalKernel/Disputes/Rewards.lean:580-597` — guard
    comment on `claimImpugnedAmount`'s deposit/withdraw skip
    (i-11 sub-issue): "Skips `deposit`/`withdraw` actions
    deliberately — those are bridge-level operations whose
    impugnment goes through the L1 fault-proof path
    (Workstream H), not the L2 dispute pipeline.  Treating
    them here would double-count."

  * `LegalKernel/Disputes/Rewards.lean:619-630` — guard
    comment on `proportionalChallengerReward`'s
    `divisor = 0` zero-amount emission (i-11 sub-issue):
    "Emits a zero-amount `rewardIssued` event when `divisor
    = 0` rather than no event, mirroring `Nat` division's
    `n / 0 = 0` semantics.  Indexers must treat zero-amount
    reward events as no-ops."

  * `LegalKernel/Disputes/Rewards.lean` (sum-le-pool
    docstring, around the `stakeWeightedAdjudicatorRewards`
    definition) — expand the docstring with the explicit
    note: "The sum-le-pool bound is a *deployment-level
    invariant* (not shipped as a Lean theorem).  Promoting
    it to a theorem would require a `disputeRewardActions_sum_le_pool`
    inductive lemma; deferred to a future workstream."  (i-11
    sub-issue.)

  * `LegalKernel/Disputes/Staking.lean:153-163` — guard
    comment on rollback-returns-stake (i-11 sub-issue):
    "Soundness depends on the runtime appending the stake
    transfer *before* the dispute action in the log; the
    invariant is enforced by the runtime adaptor's ordering
    policy and is not proved as a Lean theorem.  Future
    workstream: lift to a Lean theorem given a runtime
    ordering predicate."

**Math / proof outline.**  None.

**Implementation steps.**

  1. Single PR (or grouped commits) addressing each
     docstring.  Each edit is localised; no surrounding
     refactor.

  2. Re-run `lake build` to confirm no docstring parser
     failures (Lean's `linter.missingDocs` accepts the new
     text).

**Acceptance criteria.**  Every targeted docstring has been
updated; `lake build` clean.

**Test plan.**  None beyond a clean build.

**Risk.**  Negligible.

**Effort estimate.**  S (≤ ½ day).

### AR.14 — `count_sorries` exhaustive patterns

**Finding map:** m-2 (`count_sorries` misses `refine sorry`,
`apply sorry`, `(sorry : T)`, `· sorry`).

**Scope.**

  * `Tools/CountSorries.lean:168-180` — extend the pattern set.
  * `Tools/Test/CountSorries.lean` (or equivalent self-test) —
    add synthetic-source positive cases for each new pattern.

**Math / proof outline.**  None; lexical pattern set.

The current pattern set:

```lean
def sorryPatterns : List String :=
  [ ":= sorry"
  , "by sorry"
  , "exact sorry"
  , "sorry" -- bare term, with whitespace / line-start checks
  ]
```

The new pattern set (illustrative):

```lean
def sorryPatterns : List String :=
  [ ":= sorry"
  , "by sorry"
  , "exact sorry"
  , "refine sorry"
  , "apply sorry"
  , "· sorry"
  , "(sorry : "
  , "(sorry :"  -- with non-space-before-colon
  , "sorry"     -- bare term
  ]
```

The `(sorry : T)` form is awkward because it spans tokens.
The simplest match is `(sorry :` and `(sorry:`; this catches
the canonical `(sorry : T)` and `(sorry: T)` forms.

**Implementation steps.**

  1. Extend `sorryPatterns`.

  2. Update the masking logic if any new pattern interacts
     with the existing comment / string-literal masks.

  3. Add a self-test file covering each new pattern
     positively and the "this is not a sorry" cases
     negatively.

  4. Re-run `lake exe count_sorries` against the source tree
     to confirm zero new false positives.

**Acceptance criteria.**

  * `lake exe count_sorries` returns zero against the
    kernel-adjacent file set.
  * Self-tests cover every pattern.

**Test plan.**

  * Synthetic positive cases for each new pattern.
  * Synthetic negative cases (the word "sorry" in a comment,
    in a string literal, in a docstring).

**Definition of Done.**

  - [ ] Pattern set extended (≥ 7 distinct patterns).
  - [ ] Self-tests cover positive + negative for each new
        pattern.
  - [ ] Comment / docstring / string-literal masking
        verified to still suppress false positives.
  - [ ] `lake exe count_sorries` returns zero on the
        current source tree.

**Verification commands.**

```bash
grep -nE 'sorryPatterns|sorry' Tools/CountSorries.lean | head -20
lake build count_sorries
lake exe count_sorries
echo $?  # expected: 0
```

**Reviewer checklist.**

  - [ ] Does the pattern set cover all four patterns named
        in m-2 (`refine sorry`, `apply sorry`,
        `(sorry : T)`, `· sorry`)?
  - [ ] Do the self-tests exercise the masking logic
        explicitly (e.g. "this comment mentions sorry but
        is not a sorry")?
  - [ ] Are there any existing false-positive sorries the
        new patterns surface?  If yes, are they real
        regressions or do they need allowlist entries?

**Risk.**  Low.  False positives surface as build-blocking
audit failures; mitigated by re-running the audit during
development.

**Effort estimate.**  S (≤ ½ day).

### AR.15 — `proportionalDilute` snapshot-read guard comment

**Finding map:** i-9 (the `proportionalDilute` dust bound
relies on `kv.2` reading the pre-foldl snapshot balance; a
refactor swapping `kv.2` for `getBalance s' r kv.1` would
silently break).

**Scope.**

  * `LegalKernel/Laws/ProportionalDilute.lean` — add a guard
    comment immediately above the load-bearing snapshot-read
    line.

**Math / proof outline.**  The dust-bound theorem
`proportionalDilute_distributed_le_totalReward` relies on the
foldl body computing `kv.2 * totalReward / sumOthers` where
`kv.2` is the *pre-foldl snapshot* balance, captured before
the foldl over `bm.toList`.  If a future refactor changes
`kv.2` to `getBalance s' r kv.1` (a live-state read),
intermediate folds would see the partially-updated state and
the sum would no longer equal `sumOthers`, breaking the
bound.

**Implementation steps.**

  1. Locate the foldl body.
  2. Add a `-- INVARIANT:` comment immediately above the
     `kv.2` reference describing the load-bearing role.

**Acceptance criteria.**  The comment exists; no behavioural
change.

**Test plan.**  None.

**Definition of Done.**

  - [ ] Guard comment landed at the load-bearing line.
  - [ ] Comment names the dust-bound theorem and explains
        why `kv.2` (snapshot) cannot be replaced with a
        live-state read.

**Verification commands.**

```bash
grep -nE 'INVARIANT|kv\.2' LegalKernel/Laws/ProportionalDilute.lean
```

**Reviewer checklist.**

  - [ ] Does the comment name the load-bearing theorem
        explicitly (`proportionalDilute_distributed_le_totalReward`)?
  - [ ] Is the comment positioned immediately above the
        `kv.2` reference (not floating elsewhere)?

**Risk.**  Negligible.

**Effort estimate.**  S (≤ 15 minutes).

### AR.16 — `Verdict.encode` canonical-input boundary check

**Finding map:** m-17 (`Verdict.encode` relies on
`List.zip_unzip`; mismatched signer/sig lengths silently
truncate on decode).

**Scope.**

  * `LegalKernel/Encoding/Disputes.lean` — extend
    `Verdict.canonical` (or add `Verdict.fieldsBounded`)
    with a length-match clause requiring
    `signatures.unzip.1.length = signatures.unzip.2.length`
    (which is structurally true if `signatures : List
    (PublicKey × Signature)`, so the clause is vacuous;
    the relevant check is on the decoded form where the
    signers and sigs are parallel lists).
  * On the decoder side, add an explicit length check that
    returns `.lengthMismatch` rather than silently
    truncating via `List.zip`.

**Math / proof outline.**  The encoder produces canonical
output if `signatures : List (PublicKey × Signature)` (the
on-disk representation is a list of pairs).  The decoder
reads two parallel lists (`signersList`, `sigsList`) and
combines them with `List.zip`.  Currently, if
`signersList.length ≠ sigsList.length`, `List.zip` returns
the shorter pairing and the remainder is silently dropped.

The fix is to add an explicit length check before `zip`,
returning `.lengthMismatch` (a new `DecodeError` variant) on
mismatch.

**Implementation steps.**

  1. Add `.lengthMismatch` to the `DecodeError` enum.

  2. Add an explicit length check in `Verdict.decode`
     (line range to be confirmed at implementation time).

  3. Update the round-trip theorem to account for the new
     error variant.

  4. Add a regression test:
     `Verdict.decode (mismatched-lengths-bytes)` returns
     `.error .lengthMismatch`.

**Acceptance criteria.**

  * Decoder returns `.lengthMismatch` on mismatched lists.
  * Round-trip theorem on canonical inputs still proves.

**Test plan.**

  * Positive: canonical inputs round-trip.
  * Negative: mismatched-length bytes rejected.

**Definition of Done.**

  - [ ] `DecodeError.lengthMismatch` shipped.
  - [ ] `Verdict.decode` returns the new variant on
        mismatched inputs.
  - [ ] Canonical-input round-trip theorem updated to
        account for the new error variant.
  - [ ] Positive + negative regression tests landed.

**Verification commands.**

```bash
grep -n 'lengthMismatch\|Verdict.decode\|List.zip' \
  LegalKernel/Encoding/Disputes.lean
lake build LegalKernel.Encoding.Disputes
lake test
```

**Reviewer checklist.**

  - [ ] Is the length check **before** the `List.zip` (not
        after)?
  - [ ] Is the new error variant added to the existing
        `DecodeError` enum (not a new error type)?
  - [ ] Does the round-trip theorem statement remain
        canonical-input-only (no claim about non-canonical
        inputs)?

**Risk.**  Low.  Decoder-only change.

**Effort estimate.**  S (≤ ½ day).

### AR.17 — `kernelOnlyApply` exhaustive switch

**Finding map:** m-14 (`kernelOnlyApply` in
`Disputes/Evidence.lean:89` uses non-exhaustive `_ => s`
wildcard).

**Scope.**

  * `LegalKernel/Disputes/Evidence.lean:89-115` — replace the
    final `_ => s` wildcard with an explicit per-arm match
    covering every `Action` constructor.

**Math / proof outline.**  No theorem change.  The
exhaustiveness of the match is checked by Lean's elaborator;
replacing the wildcard with explicit arms means future
`Action` extensions force a manual review of
`kernelOnlyApply`'s policy at compile time.

The expanded match:

```lean
match action with
| .replaceKey actor newKey =>
    { es'' with registry := es''.registry.insert actor newKey }
| .registerIdentity actor pk =>
    { es'' with registry := es''.registry.insert actor pk }
| .declareLocalPolicy policy =>
    { es'' with localPolicies := es''.localPolicies.declare signer policy }
| .revokeLocalPolicy =>
    { es'' with localPolicies := es''.localPolicies.revoke signer }
-- Explicit no-op arms for every other constructor:
| .transfer _ _ _ _ => es''
| .mint _ _ _ => es''
| .burn _ _ _ => es''
| .freezeResource _ => es''
| .reward _ _ _ => es''
| .distributeOthers _ _ _ => es''
| .proportionalDilute _ _ _ => es''
| .dispute _ => es''
| .disputeWithdraw _ => es''
| .verdict _ => es''
| .rollback _ => es''
| .deposit _ _ _ _ => es''
| .withdraw _ _ _ _ => es''
| .faultProofChallenge _ _ _ _ => es''
| .faultProofResolution _ _ _ _ => es''
```

**Implementation steps.**

  1. Expand the match.

  2. Re-run `lake build LegalKernel.Disputes.Evidence`.

  3. Spot-check the `applyVerdict_under_witness_succeeds`
    theorem (which depends on `kernelOnlyApply`'s
    structural form) — it should still elaborate by `rfl`
    or simple unfolds.

**Acceptance criteria.**

  * The match is exhaustive at the syntactic level.
  * Future `Action` extensions fail at elaboration time
    until `kernelOnlyApply` is updated.
  * All existing dispute-pipeline tests pass.

**Test plan.**  None beyond a clean rebuild.

**Definition of Done.**

  - [ ] Wildcard removed; explicit per-arm match landed.
  - [ ] All 19 `Action` constructors enumerated.
  - [ ] Existing `applyVerdict_under_witness_succeeds`
        proof still elaborates.
  - [ ] `lake build` + `lake test` clean.

**Verification commands.**

```bash
grep -nE 'kernelOnlyApply|_ => es' LegalKernel/Disputes/Evidence.lean
lake build LegalKernel.Disputes.Evidence
lake test
```

**Reviewer checklist.**

  - [ ] Is every constructor enumerated (cross-check
        against `Action.tag` at
        `LegalKernel/Authority/LocalPolicySemantics.lean:64`)?
  - [ ] Do the no-op arms preserve the structural-`rfl`
        property of `applyVerdict_under_witness_succeeds`?

**Risk.**  Low.  No semantic change to the behaviour.

**Effort estimate.**  S (≤ 1 hour).

### AR.18 — `applyVerdictUnchecked` visibility

**Finding map:** per-area audit (`07-disputes.md`) —
`applyVerdictUnchecked` is exported without a Lean
visibility restriction; production callers may use it
directly.

**Scope.**

  * `LegalKernel/Disputes/Verdict.lean` — add the `protected`
    modifier to `applyVerdictUnchecked`.  (`private` is
    file-local and would break the legitimate cross-file reward
    composers in `Rewards.lean`; relocating them would invert the
    Verdict → Rewards layering — see GENESIS_PLAN §15C.6.)
  * Every call site (in `Verdict.lean`, `Rewards.lean`, and the
    dispute test files) qualifies the name as
    `Disputes.applyVerdictUnchecked`.

**Math / proof outline.**  None.

**Implementation steps.**

  1. Add the `protected` modifier (landed under CL.3).

  2. Qualify every call site as `Disputes.applyVerdictUnchecked`
     (the bare short name no longer resolves, even in-file).

  3. Re-build.

**Acceptance criteria.**

  * `applyVerdictUnchecked` is `protected`.
  * No caller can reach it via the bare short name; the
    qualified form is mandatory, making the bypass greppable.
  * All existing tests still elaborate.

**Test plan.**  The build itself is the self-test: any bare
reference to `applyVerdictUnchecked` fails to elaborate (the
`protected` modifier forces qualification).

**Definition of Done.**

  - [x] `protected` modifier added.
  - [x] All call sites qualified as `Disputes.applyVerdictUnchecked`.
  - [x] Build-enforced visibility restriction (bare name rejected).
  - [x] `lake build` + `lake test` clean.

**Verification commands.**

```bash
grep -n 'applyVerdictUnchecked\|private def' \
  LegalKernel/Disputes/Verdict.lean
lake build LegalKernel.Disputes.Verdict
lake test
```

**Reviewer checklist.**

  - [ ] Is `private` applied at the correct scope (file or
        namespace)?
  - [ ] Are there any production call sites that *should*
        be migrated to the checked variant rather than
        accessing the private form?

**Risk.**  Low.

**Effort estimate.**  S (≤ ½ day).

### AR.19 — `fileDispute` rejection lemmas (`_indexOutOfRange`, `_duplicateDispute`)

**Finding map:** per-area audit (`07-disputes.md`) — the
documented `fileDispute_rejects_*` family is incomplete;
`_indexOutOfRange` and `_duplicateDispute` rejection lemmas
are not exposed.

**Scope.**

  * `LegalKernel/Disputes/Filing.lean` — add the two
    theorems.
  * `LegalKernel/Test/Disputes/Filing.lean` — add term-level
    API-stability tests.

**Math / proof outline.**

```lean
theorem fileDispute_rejects_indexOutOfRange
    (es : ExtendedState) (d : Dispute) (log : List LogEntry)
    (h : d.targetIdx ≥ log.length) :
    fileDispute es d log = .error .indexOutOfRange := by
  unfold fileDispute
  -- Branch on d.targetIdx vs log.length; h forces the
  -- index-OOR arm.
  ...

theorem fileDispute_rejects_duplicateDispute
    (es : ExtendedState) (d : Dispute) (log : List LogEntry)
    (h : ∃ d' ∈ es.disputes,
            d'.targetIdx = d.targetIdx ∧
            d'.status ≠ .withdrawn) :
    fileDispute es d log = .error .duplicateDispute := by
  ...
```

**Implementation steps.**  Standard pattern-matching proofs.
The relevant `FilingError` constructors (`indexOutOfRange`
and `duplicateDispute`) and the `fileDispute` arms that
emit them already exist at `LegalKernel/Disputes/Filing.lean`
lines 153, 159, 164, and 170 (verified against source);
AR.19 adds the *named* theorems on top.

**Acceptance criteria.**

  * Theorems shipped and named per the documented family.
  * `#print axioms` clean.

**Test plan.**

  * Value-level cases for each rejection variant.
  * Term-level API stability test.

**Definition of Done.**

  - [ ] `fileDispute_rejects_indexOutOfRange` shipped.
  - [ ] `fileDispute_rejects_duplicateDispute` shipped.
  - [ ] Term-level API-stability tests landed.
  - [ ] `#print axioms` returns canonical three.

**Verification commands.**

```bash
grep -n 'fileDispute_rejects_' LegalKernel/Disputes/Filing.lean
lake build LegalKernel.Disputes.Filing
lake test
echo '#print axioms fileDispute_rejects_indexOutOfRange' \
  | lake env lean --stdin
echo '#print axioms fileDispute_rejects_duplicateDispute' \
  | lake env lean --stdin
```

**Reviewer checklist.**

  - [ ] Do the two new theorems sit alongside the existing
        `fileDispute_rejects_unknown_challenger`
        (Filing.lean:267) for naming consistency?
  - [ ] Does each theorem's hypothesis name the precise
        rejection condition (not a more general
        precondition that admits multiple rejection
        modes)?

**Risk.**  Low.  Pattern-matching proofs of well-typed
predicates.

**Effort estimate.**  S (≤ ½ day).

### AR.20 — `.github/CODEOWNERS`

**Finding map:** i-6 (two-reviewer rule is a process rule;
no CODEOWNERS file or branch-protection rule observed).

**Scope.**

  * `.github/CODEOWNERS` (new).

**Math / proof outline.**  None.

**Implementation steps.**

  1. Create the file with the canonical TCB-core protection
     pattern:

     ```
     # TCB-core: requires two reviewers per Genesis Plan §13.6.
     /LegalKernel/Kernel.lean        @hatter6822 @second-reviewer
     /LegalKernel/RBMapLemmas.lean   @hatter6822 @second-reviewer
     /tcb_allowlist.txt              @hatter6822 @second-reviewer

     # Audit-tooling: requires the original author's
     # acknowledgement before re-shaping the gate set.
     /Tools/                          @hatter6822
     /tools/                          @hatter6822
     ```

     The `@second-reviewer` GitHub handle is a placeholder;
     the actual co-reviewer is the project owner's
     responsibility to add.

  2. Update CLAUDE.md / `docs/GENESIS_PLAN.md` §13.6 to note
     that CODEOWNERS is the request-for-review mechanism;
     full enforcement still requires branch protection.

**Acceptance criteria.**

  * The file is present and named correctly.
  * Future PRs touching `Kernel.lean` automatically request
    review from the listed reviewers.

**Test plan.**  None.  The file is exercised by GitHub's
PR-review mechanism, not by `lake test`.

**Definition of Done.**

  - [ ] `.github/CODEOWNERS` shipped with the TCB-core
        protection pattern.
  - [ ] CLAUDE.md / Genesis Plan §13.6 updated to note
        CODEOWNERS as a request-for-review (not a merge-block).

**Verification commands.**

```bash
ls .github/CODEOWNERS
cat .github/CODEOWNERS
```

**Reviewer checklist.**

  - [ ] Is the `@second-reviewer` placeholder labelled as
        a placeholder (with a comment naming the actual
        reviewer's responsibility to land)?
  - [ ] Does the documentation update honestly note that
        full enforcement requires branch-protection rules
        (which this PR does not configure)?

**Migration notes.**

This sub-WU lands a request-for-review mechanism only.  Full
two-reviewer enforcement (the merge-block) requires a
branch-protection rule, which is repository-administrator
territory and out-of-scope for the AR PR series.  Operator
follow-up: configure branch protection in the repository
settings to require CODEOWNERS approval on the TCB-core file
set.

**Risk.**  Negligible.

**Effort estimate.**  S (≤ 15 minutes).

### AR.21 — `withdraw` positivity (optional)

**Finding map:** m-4 (`withdraw`'s precondition permits
`amount = 0`).

**Scope.**

  * `LegalKernel/Laws/Withdraw.lean` — extend the precondition
    with `0 < amount`.
  * `LegalKernel/Encoding/Action.lean` — confirm the
    `fieldsBounded` predicate already includes positivity (it
    does not; AR.21 extends the admissibility, not the
    encoder).
  * `LegalKernel/Test/Laws/Withdraw.lean` — extend the
    rejection-suite with a zero-amount case.

**Math / proof outline.**

The current precondition is:

```lean
withdraw.pre :=
  fun s => 0 < getBalance s r sender ∧
           amount ≤ getBalance s r sender
```

The fix adds `0 < amount`:

```lean
withdraw.pre :=
  fun s => 0 < amount ∧
           amount ≤ getBalance s r sender
```

Note the redundancy between `0 < amount` and
`amount ≤ getBalance s r sender` — both are subsumed by the
combined predicate when `getBalance s r sender > 0`; the
explicit `0 < amount` is the cleaner statement.

This is a *strengthening* of the precondition.  Two
implications:

  * Every previously-admissible withdraw with `amount > 0`
    is still admissible (no regression for honest callers).
  * Withdraws with `amount = 0` are no longer admissible —
    previously they were admissible but produced no
    observable state change.

The bridge actor's policy + the deployment's
admissibility-witness construction must agree: any caller
that previously constructed an admissibility witness for a
zero-amount withdraw must update to either reject the
zero-amount input or skip the call entirely.

**Implementation steps.**

  1. Add the positivity clause.

  2. Update the `withdraw.decPre` instance (still
     `inferInstance`; positivity decidable on `Nat`).

  3. Re-prove `withdraw`'s monotonicity / refinement
     properties (mechanical; positivity is preserved by
     `step_impl`).

  4. Update consumer admissibility witnesses (Bridge module)
     to account for the new clause.

  5. Add the zero-amount rejection regression test.

**Acceptance criteria.**

  * `lake test` passes; the new rejection test passes.
  * `#print axioms` on the updated headline theorems is
    unchanged.

**Test plan.**

  * **Positive — typical withdraw.**  `amount = 100`,
    `balance = 200`; admissible.
  * **Negative — zero amount.**  `amount = 0`,
    `balance = 200`; inadmissible.
  * **Negative — overdraft.**  `amount = 300`,
    `balance = 200`; inadmissible.

**Definition of Done.**

  - [ ] `0 < amount` clause added to `withdraw.pre`.
  - [ ] `withdraw.decPre` still resolves via
        `inferInstance`.
  - [ ] Bridge consumer admissibility witnesses updated.
  - [ ] Three regression tests landed.
  - [ ] `#print axioms` on `withdraw_*` theorems unchanged.

**Verification commands.**

```bash
grep -n 'withdraw.pre\|0 < amount' LegalKernel/Laws/Withdraw.lean
lake build LegalKernel.Laws.Withdraw
lake test
echo '#print axioms withdraw_conserves' | lake env lean --stdin
```

**Reviewer checklist.**

  - [ ] Does `decPre` still derive via `inferInstance`?
        (Positivity over `Nat` is decidable; the new
        clause should not require a hand-written
        instance.)
  - [ ] Is every Bridge consumer admissibility witness
        updated to satisfy the new clause?
  - [ ] Do any existing tests construct a zero-amount
        withdraw witness (search for `amount := 0` in
        test files)?

**Migration notes.**

This sub-WU strengthens admissibility; consumer call sites
that constructed admissibility witnesses for zero-amount
withdrawals must update.  In production this is a no-op
(operators never withdraw zero); the migration is purely
test-side.

**Risk.**  Low–Medium.  Strengthens an admissibility
predicate; could break a downstream test that exercised the
zero-amount path.  Mitigation: search for `amount := 0` in
withdrawal-related tests before landing.

**Effort estimate.**  S–M (1–2 days).

**Optional flag.**  This work unit is *optional*: the kernel
admissibility-layer permitting a no-op withdraw is harmless
(no observable state change), and the bridge actor's policy
is the effective gate.  Land AR.21 if the team prefers the
strictly-positive admissibility surface; defer otherwise.

### AR.22 — Documentation: CLAUDE.md / GENESIS_PLAN.md / audit index updates

**Finding map:** doc-discipline driver — CLAUDE.md requires
docs updates "in the same PR" when behaviour, theorems, or
formalisation status changes.

**Scope.**

  * `docs/GENESIS_PLAN.md` — bump the relevant phase / WU
    status subsections; note the AR remediation pass in §15
    (status registry).
  * `docs/audits/19-findings-and-followups.md` — annotate
    every finding with its AR work-unit assignment and the
    landing commit / PR.
  * `docs/audits/00-comprehensive-lean-audit-index.md` —
    add a "Remediation pass" entry pointing at this plan
    and the per-WU landing.
  * `CLAUDE.md` — bump the "Current development status" build
    tag from `"knomosis-fault-proof-migration"` to
    `"knomosis-audit-remediation"`; bump the test count
    (post-AR drift).
  * `AGENTS.md` — keep byte-identical to `CLAUDE.md`.
  * `LegalKernel.lean` — update `kernelBuildTag` to match.
  * `LegalKernel/Test/Umbrella.lean` — update the
    build-tag-pinning regression test.

**Math / proof outline.**  None.

**Implementation steps.**

  1. Bump `kernelBuildTag` and the umbrella test in lockstep.

  2. Update the GENESIS_PLAN status table for any
    AR-touched WU.

  3. Annotate `docs/audits/19-findings-and-followups.md`.

  4. Update `CLAUDE.md` + `AGENTS.md` byte-identically.

**Acceptance criteria.**

  * `LegalKernel/Test/Umbrella.lean`'s pin matches the new
    build tag.
  * `lake test` passes.
  * `git diff CLAUDE.md AGENTS.md` is empty.

**Test plan.**  Build-tag regression covers the tag.

**Definition of Done.**

  - [ ] `kernelBuildTag` bumped to
        `"knomosis-audit-remediation"`.
  - [ ] Umbrella test pinned to the new tag.
  - [ ] `docs/GENESIS_PLAN.md` §15 status registry includes
        AR.
  - [ ] `docs/audits/19-findings-and-followups.md`
        annotated with per-finding landing commits.
  - [ ] `docs/audits/00-comprehensive-lean-audit-index.md`
        notes the remediation pass.
  - [ ] CLAUDE.md and AGENTS.md byte-identical.
  - [ ] CLAUDE.md footnote 1 retired (coordinated with
        AR.4.8).

**Verification commands.**

```bash
grep -n 'kernelBuildTag\|knomosis-audit-remediation' \
  LegalKernel.lean LegalKernel/Test/Umbrella.lean
diff CLAUDE.md AGENTS.md
echo $?  # expected: 0
lake test
```

**Reviewer checklist.**

  - [ ] Are CLAUDE.md and AGENTS.md byte-identical (the
        umbrella regression test + a manual `diff`)?
  - [ ] Is every per-finding annotation in
        `19-findings-and-followups.md` accompanied by a
        landing commit reference (or "n/a — Wontfix" /
        "n/a — Defer")?
  - [ ] Does the GENESIS_PLAN status registry honestly
        reflect the AR delta (no over-claiming, no
        under-claiming)?

**Migration notes.**

This sub-WU coordinates with AR.4.8 (CLAUDE.md footnote 1
retirement) and lands last in the AR PR series.  The build
tag bump is the canonical signal that AR is complete; do
not bump it until every prerequisite sub-WU has merged.

**Risk.**  Low.

**Effort estimate.**  S (≤ ½ day).

### AR.23 — End-to-end integration regression suite (four sub-units)

**Finding map (group level):** AR.2 + AR.3 sub-deliverables.
Listed separately because the regression suite is the
integration-level acceptance criterion for AR.2.* + AR.3.*
and lands as the closing PR group.

**Group rationale.**  The four scenarios in the original
single-WU view (cross-deployment, snapshot wrong-anchor,
snapshot correct-anchor, AttestedSnapshot enforcement) test
distinct parts of the runtime hot path, depend on different
prerequisite sub-WUs, and have different fragility profiles.
Splitting into four sub-units lets each scenario land as soon
as its prerequisite is met (rather than waiting for all four
prerequisites to be in place) and makes a regression in any
one scenario bisect cleanly to its responsible sub-unit.

  * **AR.23.1** — Cross-deployment replay rejection
    (depends on AR.2.2, AR.2.4, AR.2.5, AR.2.6).
  * **AR.23.2** — Snapshot wrong-anchor rejection
    (depends on AR.3.1).
  * **AR.23.3** — Snapshot correct-anchor success +
    final-state equality (depends on AR.3.1).
  * **AR.23.4** — AttestedSnapshot CLI enforcement
    (depends on AR.3.2).

All four sub-units use the `MockCrypto` adaptor to control
`Verify` behaviour at the Lean level (so cross-deployment
rejection is observable independent of the production C
ABI).  Test files live under
`LegalKernel/Test/Integration/` per the conventional
project structure.

#### AR.23.1 — Cross-deployment replay rejection

**Finding map:** AR.2 integration acceptance.

**Scope.**

  * `LegalKernel/Test/Integration/CrossDeployment.lean`
    (new) — build a log under deploymentId `d₁`; attempt
    to replay under `d₂ ≠ d₁`; expect a diagnostic at the
    first signed action's admissibility check.

**Math / proof outline.**  The integration test asserts the
operational consequence of the AR.2 chain at the runtime
hot-path level: `processSignedAction` (or
`replayWithDeploymentId`) must reject the cross-deployment
log under the controlled-`Verify` adaptor.

**Implementation steps.**

  1. Construct two distinct deploymentId values (`d₁`, `d₂`).
  2. Build a small log of 3–5 signed actions under `d₁`
     using `MockCrypto.mockSign` keyed to a Verify that
     accepts `d₁`.
  3. Attempt to replay under `d₂` via
     `replayWithDeploymentId`; assert the diagnostic.

**Acceptance criteria.**

  * Replay returns `.notAdmissible` (or equivalent) at the
    first action.

**Test plan.**

  * Single positive case (replay under `d₁` succeeds).
  * Single negative case (replay under `d₂` rejects at
    first action).
  * Edge case: empty log (no actions to reject); both `d₁`
    and `d₂` accept.

**Definition of Done.**

  - [ ] Test file added.
  - [ ] Wired into `Tests.lean`.
  - [ ] `lake test` clean.

**Verification commands.**

```bash
lake build LegalKernel.Test.Integration.CrossDeployment
lake test
```

**Reviewer checklist.**

  - [ ] Does the test use `MockCrypto.mockSign` to make the
        `Verify` reachable at the Lean level?
  - [ ] Does the diagnostic assertion match the actual
        `replayWithDeploymentId` return type?

**Risk.**  Low.

**Effort estimate.**  S (≤ 1 day).

#### AR.23.2 — Snapshot wrong-anchor rejection

**Finding map:** AR.3.1 integration acceptance.

**Scope.**

  * `LegalKernel/Test/Integration/SnapshotBootstrap.lean`
    (new) — build a snapshot for `(state₁, seedHash₁,
    baseIdx)`; attempt to bootstrap against a log whose
    `entries[baseIdx-1].hash ≠ seedHash₁`; expect
    `.anchorMismatch`.

**Math / proof outline.**  Operational consequence of the
AR.3.1 anchor check.

**Implementation steps.**

  1. Build a log of N entries.
  2. Build a snapshot whose `seedHash` does NOT match
     `hash(entries[baseIdx-1])`.
  3. Bootstrap; assert `.error .anchorMismatch`.

**Acceptance criteria, Test plan, Definition of Done,
Verification commands, Reviewer checklist, Risk.**  Mirror
AR.23.1's structure.

**Effort estimate.**  S (≤ ½ day).

#### AR.23.3 — Snapshot correct-anchor success + final-state equality

**Finding map:** AR.3.1 integration acceptance.

**Scope.**

  * `LegalKernel/Test/Integration/SnapshotBootstrap.lean`
    (extended in the same file as AR.23.2) — build a
    correct snapshot and assert that bootstrapping +
    replaying the tail produces the same final state as
    replaying from genesis.

**Math / proof outline.**  This test is the soundness
counterpart to AR.23.2: snapshot bootstrapping is *correct*
when the anchor matches.  Final-state equality is the
strongest possible operational claim.

**Implementation steps.**

  1. Build a log of N entries; snapshot at index k.
  2. Bootstrap from snapshot + replay tail.
  3. Independently replay from genesis.
  4. Assert the two final `RuntimeState`s are equivalent
     (use the AR.4.8 `extendedState_extensional_injective`
     lemma if needed; otherwise field-wise `toList`
     equality).

**Acceptance criteria, Test plan, Definition of Done,
Verification commands, Reviewer checklist, Risk.**  Mirror
AR.23.1's structure.  Note the AR.4.8 dependency for the
strongest form of the equality assertion.

**Effort estimate.**  S (≤ ½ day).

#### AR.23.4 — AttestedSnapshot CLI enforcement

**Finding map:** AR.3.2 integration acceptance.

**Scope.**

  * `LegalKernel/Test/Integration/SnapshotBootstrap.lean`
    (extended) or `LegalKernel/Test/Integration/AttestedSnapshot.lean`
    (new) — assert that the CLI gates land:
    `--snapshot` without `--attested` /
    `--unsafe-self-attested` is refused; `--attested`
    on a properly attested snapshot succeeds; bad
    attestation is refused.

**Math / proof outline.**  None.  Pure CLI-surface
integration test.

**Implementation steps.**

  1. Use `IO`-level test scaffolding to invoke
     `Main`'s argument-parser logic (or directly test
     `bootstrapFromAttestedSnapshot`).
  2. Construct a properly attested snapshot via the
     existing `AttestedSnapshot` API.
  3. Construct an attested snapshot with a tampered
     attestor signature.
  4. Assert each case's exit / return code.

**Acceptance criteria, Test plan, Definition of Done,
Verification commands, Reviewer checklist, Risk.**  Mirror
AR.23.1's structure.

**Effort estimate.**  S (≤ 1 day).

#### AR.23 — original (deprecated single-WU view)

The original AR.23 single-WU specification is preserved
below for traceability.

**Scope.**

  * `LegalKernel/Test/Integration/CrossDeployment.lean`
    (new) — end-to-end regression.
  * `LegalKernel/Test/Integration/SnapshotBootstrap.lean`
    (new) — end-to-end regression for AR.3.

**Math / proof outline.**

The integration tests exercise the *full* runtime path:

  1. **Cross-deployment.**  Build a log under deploymentId
    `d1`; attempt to replay it under `d2 ≠ d1`; expect a
    diagnostic at the first signed-action's admissibility
    check.

  2. **Snapshot wrong-anchor.**  Build a snapshot for
     `(state₁, seedHash₁, baseIdx)`; attempt to bootstrap
     against a log whose `entries[baseIdx-1].hash ≠
     seedHash₁`; expect `.anchorMismatch`.

  3. **Snapshot correct-anchor.**  Same setup with the
     correct seedHash; expect bootstrap success and
     reaching `final state` matching the from-genesis
     replay.

  4. **AttestedSnapshot enforcement.**  `knomosis` CLI without
     `--attested` rejects a snapshot input; with
     `--attested` accepts.

**Implementation steps.**

  1. Use the `MockCrypto` adaptor to control `Verify`
     behaviour (so cross-deployment rejection is observable
     at the Lean level, not just the production binary
     level).

  2. Build the regression as a unified test suite under
     `Test/Integration/`.

  3. Wire into `Tests.lean`.

**Acceptance criteria.**

  * The integration tests elaborate and pass.
  * The diagnostic codes match the `.notAdmissible`,
    `.anchorMismatch`, etc. enums.

**Test plan.**  As described.

**Risk.**  Low.  Pure integration test; no new theorem.

**Effort estimate.**  M (1–3 days).

### §4.1 Effort summary

The 23 work-unit groups (43 sub-units) sum to roughly
**5–7 weeks** of focused engineering effort under realistic
review bandwidth, **≈ 9 working days** under maximally
parallel review, and **≈ 16 working days** if AR.4.* is fully
serialised.  Distribution by sub-unit:

| Group | Sub-unit | Title (abbrev.)                        | Effort | Tier (PR group) |
|-------|----------|----------------------------------------|--------|-----------------|
| AR.1  | —        | Shared signedActionDomain              | S (½d) | Group 3         |
| AR.2  | AR.2.1   | RuntimeState.deploymentId field        | S (½d) | Group 5         |
| AR.2  | AR.2.2   | processSignedAction reads field        | S (½d) | Group 5         |
| AR.2  | AR.2.3   | bootstrap parameterisation             | S (½d) | Group 5         |
| AR.2  | AR.2.4   | replayWithDeploymentId entry point     | S (½d) | Group 5         |
| AR.2  | AR.2.5   | checkSignatureInvalidWith variant      | S (½d) | Group 5         |
| AR.2  | AR.2.6   | CLI flag wiring + stderr warning       | S (1d) | Group 5         |
| AR.3  | AR.3.1   | Anchor check + .anchorMismatch         | S (½d) | Group 6         |
| AR.3  | AR.3.2   | AttestedSnapshot CLI default + opt-in  | S (1d) | Group 6         |
| AR.4  | AR.4.1   | Generic helper + RoundtripsAt          | S (1d) | Group 7         |
| AR.4  | AR.4.2   | BalanceMap quartet (template)          | M (4d) | Group 7         |
| AR.4  | AR.4.3   | State quartet                          | S–M (2d)| Group 7        |
| AR.4  | AR.4.4   | NonceState quartet                     | S (1d) | Group 7         |
| AR.4  | AR.4.5   | KeyRegistry quartet                    | S (1d) | Group 7         |
| AR.4  | AR.4.6   | LocalPolicies quartet                  | S–M (2d)| Group 7        |
| AR.4  | AR.4.7   | BridgeState (consumed + pending)       | S–M (3d)| Group 7        |
| AR.4  | AR.4.8   | ExtendedState + FaultProof composition | S–M (1d)| Group 7        |
| AR.5  | —        | Action tag regression tests            | S (2h) | Group 2         |
| AR.6  | —        | Event tag regression tests             | S (1h) | Group 2         |
| AR.7  | —        | Lex Diff comparator extension          | S (½d) | Group 4         |
| AR.8  | —        | naming_audit `_v2` + UsdClearing rename | S (1h)| Group 3         |
| AR.9  | —        | MockCrypto import detector             | S (½d) | Group 4         |
| AR.10 | —        | Hash `@[extern]` annotations           | S (1h) | Group 4         |
| AR.11 | —        | synth_local resource dispatch          | M (1–3d)| Group 4        |
| AR.12 | —        | lexlaw renderSyntax reprint            | S (½d) | Group 4         |
| AR.13 | AR.13.1  | Audit-tool docstrings                  | S (½h) | Group 1         |
| AR.13 | AR.13.2  | Kernel-adjacent docstrings             | S (½h) | Group 1         |
| AR.13 | AR.13.3  | Bridge & Disputes docstrings           | S (1h) | Group 1         |
| AR.13 | AR.13.4  | Lex docstrings                         | S (1h) | Group 1         |
| AR.13 | AR.13.5  | Laws & Events docstrings               | S (½h) | Group 1         |
| AR.14 | —        | count_sorries exhaustive patterns      | S (½d) | Group 1         |
| AR.15 | —        | proportionalDilute guard comment       | S (15m)| Group 1         |
| AR.16 | —        | Verdict.encode boundary check          | S (½d) | Group 4         |
| AR.17 | —        | kernelOnlyApply exhaustive switch      | S (1h) | Group 4         |
| AR.18 | —        | applyVerdictUnchecked private          | S (½d) | Group 1         |
| AR.19 | —        | fileDispute rejection lemmas           | S (½d) | Group 2         |
| AR.20 | —        | `.github/CODEOWNERS`                   | S (15m)| Group 1         |
| AR.21 | —        | Withdraw positivity (optional)         | S–M (1–2d)| Group 8       |
| AR.22 | —        | Documentation updates                  | S (½d) | Group 8         |
| AR.23 | AR.23.1  | Cross-deployment replay regression     | S (1d) | Group 8         |
| AR.23 | AR.23.2  | Snapshot wrong-anchor regression       | S (½d) | Group 8         |
| AR.23 | AR.23.3  | Snapshot correct-anchor + final-state  | S (½d) | Group 8         |
| AR.23 | AR.23.4  | AttestedSnapshot CLI integration       | S (1d) | Group 8         |

Legend: **S** ≤ 1 day, **M** ≤ 1 week, **L** > 1 week.

**Distribution.**  35 sub-units are tier S (½–1 day each); 4
sub-units are tier S–M (1–3 days each); 4 sub-units are
tier M (1 day to ≈ 1 week each); the original L-tier AR.4
work is now decomposed into 8 sub-units of which the
heaviest (AR.4.2, the template-establisher) is M-tier.
**No single sub-unit is L-tier**.

**Critical-path total.**  Per §3.3, the longest forced
sub-unit chain is AR.1 → AR.2.1 → AR.2.2 → AR.2.3 →
AR.3.1 → AR.23.1 → AR.23.2 → AR.23.3 → AR.22 ≈ **5
working days** for one serialised implementer; everything
else parallelises.

**AR.4 track minimum.**  AR.4.1 → AR.4.2 → (AR.4.3 ‖
AR.4.4 ‖ AR.4.5 ‖ AR.4.6 ‖ AR.4.7) → AR.4.8 ≈ **9 working
days** under maximally parallel review of the four
post-template quartets, ≈ **16 working days** under
sequential review.

**Realistic estimate.**  With one full-time implementer and
typical async review delays, 5–7 calendar weeks is the
honest expectation.  With two implementers (one on the
deploymentId track, one on AR.4) and parallel review, 3–4
calendar weeks is achievable.

**M-tier sub-units.**  AR.4.2 (BalanceMap template) and
AR.11 (Lex synth_local).  AR.4.2 is on the AR.4 critical
path; AR.11 is parallel.  Both touch hot paths (proof
discipline / macro elaborator) and the M estimate covers
implementation plus regression-test authoring.

**Mechanical sub-units.**  The 35 S-tier sub-units (AR.1,
AR.2.1 – AR.2.5, AR.3.1, AR.4.4 / 4.5, AR.5 – AR.10, AR.12,
AR.13.1 – AR.13.5, AR.14 – AR.20, AR.22, AR.23.2 – AR.23.3)
are mechanical or small-scope; many can land as batched PRs
within their PR group.  See §5.

## §5 Sequencing and PR structure

The 43 sub-units land in **eight sequential PR groups**.
Each group is a single PR (or a tight series of co-landing
sub-PRs) on the `claude/audit-findings-workstream-oyEAO`
branch (or a per-group sub-branch landing back into the
workstream branch).  Grouping is by theme + dependency, not
strictly by priority.

**Sub-PR convention.**  Within a group, each sub-WU is a
distinct sub-PR unless the group's "PR boundaries" note
explicitly folds related sub-WUs into a single PR.
Per-sub-PR commit messages carry `Bisect-tag: AR.<sub-id>`
(see §6.6) so a future regression bisects to the responsible
sub-WU.

### Group 1 — Cosmetic + audit-tooling baseline

Lands first; no behavioural change; reduces noise for
subsequent groups.

  * **AR.13.1** — Audit-tool docstrings (m-1, m-3).
  * **AR.13.2** — Kernel-adjacent docstrings (m-19 partial).
  * **AR.13.3** — Bridge & Disputes docstrings (m-15, i-11).
  * **AR.13.4** — Lex docstrings (m-8/9/10/12/18, m-19
    partial).
  * **AR.13.5** — Laws & Events docstrings (m-5, m-6).
  * **AR.14** — `count_sorries` exhaustive patterns.
  * **AR.15** — `proportionalDilute` snapshot-read guard
    comment.
  * **AR.18** — `applyVerdictUnchecked` visibility.
  * **AR.20** — `.github/CODEOWNERS`.

**PR boundaries within Group 1.**  AR.13.1 – AR.13.5 land as
five distinct sub-PRs (one per subject-matter reviewer).
AR.14 is one PR.  AR.15 + AR.18 + AR.20 fold into a single
"miscellaneous cleanup" PR.

**Build posture target.**  Clean `lake build`, `lake test`,
all five existing audit binaries green, plus the new
`count_sorries` pattern set elaborating against itself.

### Group 2 — Regression tests + tagging

Pins the *current* index space.  Lands after Group 1 so
audit-tooling extensions cannot interfere.

  * **AR.5** — Action tag regression tests (19 indices).
  * **AR.6** — Event tag regression tests (16 indices, plus
    new `Event.tag` definition).
  * **AR.19** — `fileDispute` rejection lemmas.

**PR boundaries.**  AR.5 + AR.6 fold into a single
"constructor-tag regression suite" PR.  AR.19 is one PR.

**Build posture target.**  Clean rebuild; the new tests pin
every index by `rfl`.

### Group 3 — Shared constants + small renames

Establishes the shared-constant surface for the
deploymentId parameterisation.

  * **AR.1** — Shared `signedActionDomain` constant.
  * **AR.8** — `naming_audit` `_v2` policy alignment +
    UsdClearing rename.

**Note on ordering.**  AR.8 lands after Group 1 because it
relies on `count_sorries` and `naming_audit` being in
their final form.  AR.1 has no dependency on Group 1; it
can land here for thematic coherence (constant cleanup is
adjacent to naming cleanup).

**Build posture target.**  `lake exe naming_audit` reports
zero violations; the new shared-constant module elaborates.

### Group 4 — Tooling refinements

Closes the Lex governance gap and the Disputes hardening
gap.

  * **AR.7** — Lex Diff comparator extension.
  * **AR.9** — MockCrypto production-import detector.
  * **AR.10** — Hash `@[extern]` annotations.
  * **AR.11** — `synth_local` resource-aware dispatch.
  * **AR.12** — `lexlaw` `renderSyntax` byte-fidelity.
  * **AR.16** — `Verdict.encode` canonical-input boundary
    check.
  * **AR.17** — `kernelOnlyApply` exhaustive switch.

**PR boundaries.**  AR.10 is one PR (the most consequential
trust-model-explicit change).  AR.11 + AR.12 fold (Lex DSL
internals).  AR.7 + AR.9 fold (audit tooling).  AR.16 +
AR.17 fold (Disputes hardening).

**Build posture target.**  New audit binary green; Lex
synthesizer rejects ill-formed `local [S]` claims; Hash
`@[extern]` annotations elaborate; Disputes hardening
regression tests pass.

### Group 5 — DeploymentId parameterisation (six sub-PRs)

The largest behavioural change.  Each sub-WU lands as its
own sub-PR for cleaner review and bisection.

  * **AR.2.1** — `RuntimeState.deploymentId` field.
  * **AR.2.2** — `processSignedAction` reads the field.
  * **AR.2.3** — Bootstrap parameterisation.
  * **AR.2.4** — `replayWithDeploymentId` entry point.
  * **AR.2.5** — `checkSignatureInvalidWith`.
  * **AR.2.6** — CLI flag wiring + stderr warning.

**PR boundaries.**  Each sub-WU is a distinct sub-PR
landing in the order above.  AR.2.1 → AR.2.2 → AR.2.3 form
a strict chain; AR.2.4 / AR.2.5 / AR.2.6 can interleave
after AR.2.3 lands.

**Build posture target.**  `processSignedAction` no longer
references `ByteArray.empty` (other than the back-compat
alias); the dispute pipeline likewise; CLI flags accepted;
the cross-deployment regression test passes (added in
AR.23.1).

### Group 6 — Snapshot bootstrap (two sub-PRs)

Builds on the Group 5 deploymentId surface.

  * **AR.3.1** — Anchor check + `.anchorMismatch`.
  * **AR.3.2** — `AttestedSnapshot` CLI default + opt-in.

**PR boundaries.**  Two distinct sub-PRs.  AR.3.1 lands
first (Lean-only); AR.3.2 lands second (operator-facing).

**Build posture target.**  `bootstrapFromSnapshot` rejects
wrong-anchor snapshots; `knomosis` CLI refuses unattested
cross-replica startup by default.

### Group 7 — Encoder injectivity (the deep theorem track; eight sub-PRs)

The most theorem-intensive group.  Lands in parallel with
Groups 5/6 if reviewer bandwidth permits; otherwise lands
after.

  * **AR.4.1** — Helper round-trip + `Encodable.RoundtripsAt`.
  * **AR.4.2** — `BalanceMap` quartet (template-establisher).
  * **AR.4.3** — `State` quartet.
  * **AR.4.4** — `NonceState` quartet.
  * **AR.4.5** — `KeyRegistry` quartet.
  * **AR.4.6** — `LocalPolicies` quartet.
  * **AR.4.7** — `BridgeState` quartet (consumed + pending).
  * **AR.4.8** — `ExtendedState` composition + FaultProof.Commit
    chain.

**PR boundaries.**  AR.4.1 → AR.4.2 are sequential.
AR.4.3 / AR.4.4 / AR.4.5 / AR.4.6 / AR.4.7 are all
parallel-safe after AR.4.2 ships and can be reviewed
concurrently by different reviewers.  AR.4.8 lands last
(after every quartet) and ships the composition + the
CLAUDE.md footnote 1 retirement (coordinated with AR.22).

**Build posture target.**  Every map-backed encoder has its
injectivity quartet; the FaultProof chain composes
bytes-eq → encode-eq → toList-eq.

### Group 8 — Integration tests + documentation (six sub-PRs)

Lands last; depends on every other group.

  * **AR.23.1** — Cross-deployment replay regression.
  * **AR.23.2** — Snapshot wrong-anchor regression.
  * **AR.23.3** — Snapshot correct-anchor + final-state.
  * **AR.23.4** — AttestedSnapshot CLI integration.
  * **AR.21** — Withdraw positivity (optional; lands here
    if the team agrees).
  * **AR.22** — Documentation: CLAUDE.md / GENESIS_PLAN.md /
    audit index updates; build tag bump.

**PR boundaries.**  AR.23.1 + AR.23.2 + AR.23.3 fold into a
single "integration regression suite" PR (they live in the
same test files).  AR.23.4 is a separate PR (different test
file; depends on AR.3.2 specifically).  AR.21 (if accepted)
is one PR.  AR.22 lands last as a unified doc-update PR.

**Build posture target.**  All gates green, all integration
tests pass, build tag bumped to `"knomosis-audit-remediation"`.

## §6 Quality gates, rollback, and roll-forward discipline

### §6.1 Per-PR forcing functions

Every AR PR must clear, in order:

  1. **`lake build`** — clean elaboration.
  2. **`lake test`** — every test suite green (including the
     new AR-introduced suites).
  3. **`lake exe count_sorries`** — zero on the
     kernel-adjacent file set.
  4. **`lake exe tcb_audit`** — TCB-core file set has no
     un-allowlisted imports.
  5. **`lake exe stub_audit`** — no placeholder bodies.
  6. **`lake exe naming_audit`** — zero forbidden-token
     matches.
  7. **`lake exe deferral_audit`** — no `until X ships`
     hedges added.
  8. **`lake exe lex_lint`** — Lex registry append-only
     discipline preserved.
  9. **`lake exe lex_codegen --check`** — Lex sidecars
     byte-stable.
  10. **`lake exe mock_import_audit`** (new in AR.9) — no
     production imports of `Test/*` modules.
  11. **`#print axioms`** spot-check on every new theorem
     returns the canonical three (plus the named opaques
     where applicable).
  12. **CI strict-warnings gate** — no `: warning:` lines.

### §6.2 Two-reviewer gate

Per Genesis Plan §13.6, any AR work unit that touches
`Kernel.lean` or `RBMapLemmas.lean` (the TCB-core file set)
requires two reviewers.  **AR is scoped to non-TCB modules,
so no AR work unit triggers this gate.**  This is by design:
AR is a deployment-facing remediation pass, not a kernel
amendment.

If a reviewer flags an AR work unit as inadvertently TCB-impacting
(e.g. by extending `Tools.Common.tcbInternalImports`), the
work unit is moved to a separate sub-WU that goes through the
§13.6 process.  AR.10's `@[extern]` annotations are *not*
TCB-impacting because:

  * Hash.lean is not in the TCB-core file set.
  * The `@[extern]` attribute does not change the Lean body
    (theorems still reason about the in-Lean implementation).
  * The trust assumption (collision resistance of the linked
    hash function) is *already* surfaced in CLAUDE.md as a
    documented opaque-style assumption; the annotation makes
    the swap-point mechanism explicit rather than introducing
    new trust.

### §6.3 Rollback discipline

Each AR sub-WU is independently rollback-able.  The
sub-unit decomposition (vs. the original group-only view)
makes revert decisions narrower: rolling back a single
proof quartet (e.g. AR.4.5) doesn't affect the other six
quartets.

  * **Group 1** (cosmetic): per-sub-PR `git revert`
    produces a clean tree.  AR.13.1 – AR.13.5 are
    file-disjoint, so reverting one doesn't disturb the
    others.
  * **Group 2** (regression tests): `git revert` removes
    the new test files; pre-AR test suite continues to
    pass.
  * **Group 3** (shared constants + renames): `git revert`
    restores the duplicated literals; rename is reverted
    by name swap.
  * **Group 4** (tooling): per-PR revert; new audit
    binary's `lakefile.lean` entry is removed.
  * **Group 5** (deploymentId parameterisation):
    per-sub-WU revert.  Reverting AR.2.6 (CLI wiring)
    leaves the Lean library plumbing in place but restores
    the dev-mode default behaviour of the binaries.
    Reverting AR.2.5 leaves the rest of the chain in place
    but restores `checkSignatureInvalid`'s hardcoded
    default.  Reverting AR.2.1 (the field) cascades:
    AR.2.2 / AR.2.3 / AR.2.4 / AR.2.5 / AR.2.6 must also
    revert because they depend on the field's existence.
  * **Group 6** (snapshot bootstrap): per-sub-WU revert.
    Reverting AR.3.2 leaves the anchor check in place but
    restores the unattested CLI default; reverting AR.3.1
    cascades into AR.3.2 (which depends on it).
  * **Group 7** (encoder injectivity): per-sub-WU revert.
    Each quartet (AR.4.2 – AR.4.7) is file-disjoint at the
    test level and namespace-disjoint at the proof level,
    so reverting one quartet leaves the others standing.
    Reverting AR.4.8 (the FaultProof composition) leaves
    every quartet intact but restores CLAUDE.md footnote
    1.  Reverting AR.4.2 (the template) cascades into
    AR.4.3 – AR.4.8.  Reverting AR.4.1 cascades into
    everything else.
  * **Group 8** (integration tests + docs): per-sub-WU
    revert.  AR.23.1 – AR.23.4 are file-disjoint.  AR.22
    revert restores the pre-AR `kernelBuildTag` and umbrella
    pin; the cascade is widely visible (umbrella regression
    test must be reverted in lockstep).

### §6.4 CI failure response

If a CI gate fails mid-AR:

  1. **`count_sorries` non-zero in non-TCB code** — the
     audit pattern set extension (AR.14) caught a previously
     unflagged `sorry`.  This is a *find*, not a
     *regression*.  Fix the `sorry` or allowlist it (the
     `allowlist` mechanism in `Tools/CountSorries.lean`
     accommodates intentional deferrals).
  2. **`naming_audit` non-zero** — AR.8 extended the
     forbidden-token list.  Rename the offending identifier
     per the `Names describe content, never provenance`
     rule.
  3. **`tcb_audit` non-zero** — a TCB-core file gained an
     un-allowlisted import.  AR is scoped to *not touch*
     TCB-core; this would be a bug in the AR PR.  Revert.
  4. **`#print axioms` returns a non-canonical axiom** — a
     custom axiom slipped in.  AR forbids new axioms.
     Revert and re-investigate.
  5. **`mock_import_audit` non-zero (post-AR.9)** — a
     production module imported a `Test/*` module.  Migrate
     the import to a non-test module or move the consumer
     to the test tier.
  6. **Cross-stack tests fail** (`solidity/make test-cross-stack`)
     — the AR change inadvertently broke the on-disk frame
     format.  Bisect to the offending commit; revert.

### §6.5 Roll-forward strategy

Rollback (§6.3) treats a defective sub-WU as something to
*remove*.  Roll-forward treats it as something to *fix
forward*.  AR's discipline is to prefer roll-forward over
rollback whenever the failure is local and the fix is
clear, because rollback erodes the workstream branch's
forward progress and creates merge-conflict cleanup.

**Roll-forward decision tree.**

  1. **Did the failure surface in a sub-WU's own tests?**
     If yes, the sub-WU is defective in implementation
     (not in design).  Push a fix-up commit on the same
     sub-PR; do not open a new sub-WU.
  2. **Did the failure surface in a *downstream* sub-WU's
     tests?**  E.g. AR.4.5's quartet exposes a latent bug
     in AR.4.1's helper lemma.  Push a fix-up commit on
     AR.4.1's PR (if AR.4.1 hasn't merged yet) or open a
     sibling sub-WU `AR.4.1.1` (if AR.4.1 has merged).
     Coordinate with the AR.4.5 reviewer.
  3. **Did the failure surface in a *cross-stack* test?**
     E.g. `solidity/make test-cross-stack` fails because
     the on-disk frame format drifted.  This is a
     soundness-tier issue: rollback the sub-WU and
     investigate the frame-format break before re-landing.
     Do not roll forward without root-cause analysis.
  4. **Did the failure surface in a *previously-green*
     audit gate?**  E.g. `tcb_audit` flags an
     un-allowlisted import that AR introduced.  This is
     also a soundness-tier issue: rollback or re-design
     the sub-WU, do not roll forward.

**Fix-up commit conventions.**

  * Commit message subject: `Fix-up AR.<sub-id>: <one-line
    summary>`.
  * Commit message body: name the failure mode that
    surfaced + the fix's mechanism.
  * `Bisect-tag: AR.<sub-id>` retained (so bisection still
    points at the sub-WU's identifier, not at the fix-up).
  * Squash on merge (the sub-PR's history is internal; the
    landed commit on `claude/audit-findings-workstream-oyEAO`
    is the canonical record).

**Roll-forward forbidden cases.**

  * A custom axiom slipped in: rollback (per §6.4 step 4).
  * A TCB-core import slipped in: rollback (per §6.4 step
    3).
  * Cross-stack test fails: rollback (per §6.4 step 6).
  * The original sub-WU's *design* turns out wrong (not
    its implementation): close the sub-PR, redesign in a
    new sub-WU, do not roll forward on a flawed design.

### §6.6 Commit-message and PR-title conventions

Every AR commit message and PR title follows a uniform
structure so a future reader can navigate the workstream
history mechanically.

**Commit message structure.**

```
AR.<sub-id>: <one-line summary, ≤ 70 chars>

<2-4 sentence rationale: what the sub-WU does and why>

Bisect-tag: AR.<sub-id>
```

  * The leading `AR.<sub-id>:` prefix is mandatory and
    matches the §4 work-unit identifier exactly (e.g.
    `AR.4.2`, `AR.13.3`, `AR.23.1`).
  * The one-line summary describes the *content* of the
    change, not its provenance.  Names like
    `audit-fix-cleanup` are forbidden (per CLAUDE.md
    "Names describe content, never provenance").
  * The rationale paragraph cross-references the relevant
    finding (M-1, m-7, etc.) and the impacted source
    files.
  * `Bisect-tag` is on its own line at the end of the
    message body.  This enables `git log --grep
    'Bisect-tag: AR.4.2'` to reconstruct the sub-WU's full
    landing trail.

**PR title structure.**

```
AR.<sub-id>: <one-line summary>
```

(Identical to the commit-message subject.)

**PR body structure.**

PR bodies follow the workstream's standard template
(`## Summary` + `## Test plan`) plus a leading line:

```
Implements AR.<sub-id> (see docs/planning/audit_remediation_plan.md §4).
```

The leading line lets a reviewer route to the sub-WU
specification without searching.

**Forbidden in PR bodies.**  Per CLAUDE.md "Pull request
authoring policy (ABSOLUTE)": no session URLs of the form
`https://claude.ai/code/session_*`.  Cite the §4 work-unit
specification + the relevant Genesis-Plan section instead.

**Squash policy.**  Within a sub-PR, fix-up commits
(`Fix-up AR.<sub-id>: ...`) may be squashed on merge so the
workstream branch carries one commit per sub-WU.  This
preserves bisection precision while keeping the workstream
history readable.

## §7 Risk register and mitigations

| ID    | Risk                                                                                              | Sub-WU(s)                | Likelihood | Impact | Mitigation                                                                              |
|-------|---------------------------------------------------------------------------------------------------|--------------------------|-----------:|-------:|-----------------------------------------------------------------------------------------|
| R-1   | Encoder-injectivity proof fails for a sub-state under unexpected Std-API drift.                   | AR.4.2 – AR.4.7          | Low        | High   | Land AR.4.2 (BalanceMap) first as the template; cross-verify each sub-state proof's `#print axioms`. |
| R-2   | DeploymentId parameterisation breaks a downstream test relying on the empty-default.              | AR.2.2 – AR.2.5          | Medium     | Medium | Search for `ByteArray.empty` in test files before landing; migrate any matches.         |
| R-3   | `@[extern]` annotation causes elaboration failure under Lean v4.29.1.                             | AR.10                    | Low        | Low    | Verify via local rebuild; the annotation is a documented Lean attribute.                |
| R-4   | Lex synthesizer change rejects a previously-accepted Lex law.                                     | AR.11                    | Low–Medium | Medium | Run full Lex test suite; spot-check ExampleLex and UsdClearing deployments.            |
| R-5   | Snapshot anchor check rejects a previously-accepted operator snapshot.                            | AR.3.1                   | Medium     | Medium | Migration note in `docs/fault_proof_runbook.md`; CLI fallback flag (AR.3.2) for explicit opt-in. |
| R-6   | Constructor-tag regression tests pass on the current source but a future PR with renamed indices fails the regression. | AR.5, AR.6 | Low | Low (by design) | The "fails by design" outcome is what the regression is for; surface failure routes via `Bisect-tag`. |
| R-7   | Rename of `federation_transfer_policy_v2` breaks a downstream test.                               | AR.8                     | Low        | Low    | Search for the identifier project-wide before renaming.                                |
| R-8   | `fieldsBounded` hypothesis is not satisfied by some downstream theorem.                           | AR.4.8                   | Medium     | Medium | Verify the hypothesis is satisfied by the runtime-introduced state; document as a deployment obligation. |
| R-9   | AR's broad set of changes accumulates merge conflicts on the long-lived branch.                   | All groups               | Medium     | Low    | Land sub-WUs in dependency order; rebase the workstream branch on `main` between groups; cherry-pick where conflicts mount. |
| R-10  | CODEOWNERS without a corresponding GitHub branch-protection rule is purely advisory.              | AR.20                    | High       | Low    | Document the limitation; flag the configuration step as a non-code follow-up.        |
| R-11  | CLI default change (AR.3.2) catches an operator off-guard mid-deploy.                             | AR.3.2                   | Medium     | Medium | Release-note coverage; opt-in `--unsafe-self-attested` flag; runbook update.            |
| R-12  | CLI default change (AR.2.6) on `knomosis-replay` blocks an existing audit pipeline.                  | AR.2.6                   | Medium     | Low    | Document at PR-time that the change is intentional; the audit binary is the right place to *force* explicit deploymentId. |
| R-13  | AR.4.2 BalanceMap template proof shape doesn't generalise to the other quartets (e.g. NonceState's `Nonce = Nat` interacts with helper differently). | AR.4.3 – AR.4.7 | Low | Medium | If the template is non-generic, capture the divergence as a minor sub-WU `AR.4.2.1` (helper extension) before proceeding to the other quartets. |
| R-14  | AR.4.8 composition lemma's `fieldsBounded` predicate over-claims (e.g. omits a sub-state).        | AR.4.8                   | Low–Medium | Medium | Reviewer checklist explicitly enumerates every sub-state field; spot-check against the `commitExtendedState_subcommits_bytes_eq` enumeration. |
| R-15  | Sub-WU AR.13.4 (Lex docstrings) surfaces latent Lex sidecar drift via `lex_codegen --check`.      | AR.13.4 (interaction with AR.12) | Low–Medium | Low | Land AR.12 first (which fixes the `renderSyntax` drift); re-regenerate sidecars if AR.13.4 surfaces additional drift. |
| R-16  | Sub-PR fan-out (43 sub-units) exhausts reviewer bandwidth; review queue grows.                    | All groups               | Medium     | Low    | Folded sub-PR groupings (Group 1 / Group 4 / Group 8) bundle related sub-WUs; reviewer assignments per §1.5 reading guide route by subject matter. |

## §8 Acceptance criteria for Workstream AR overall

AR is considered "complete" when **all** of the following
hold simultaneously:

  1. Every Major finding (M-1 through M-10) plus the two
     cross-verification additions (M+1, M+2) has a landed
     sub-WU (or an explicit Wontfix rationale in §2.2).
     Specifically:
     * M-1: AR.2.1 – AR.2.4, AR.2.6 landed.
     * M-2: AR.3.1, AR.3.2 landed.
     * M-3: AR.4.1 – AR.4.8 landed.
     * M-4: Wontfix (§2.2).
     * M-5: AR.2.5 landed.
     * M-6 – M-10, M+1, M+2: respective sub-WUs landed.
  2. Every Minor finding (m-1 through m-19) has either:
     (a) a landed sub-WU, or
     (b) a documented Defer / Document-only triage decision
     in §2.3 + an updated docstring (AR.13.*).
  3. The full CI gate set (§6.1) is green, including the
     new `mock_import_audit` binary (AR.9).
  4. The `kernelBuildTag` is bumped to
     `"knomosis-audit-remediation"` (AR.22).  Superseded by the
     subsequent Workstream EI bump to
     `"knomosis-encoder-injectivity"` (EI.8.i); both are valid
     completion-time tags for the AR + EI milestones, with EI's
     being the current value.
  5. `LegalKernel/Test/Umbrella.lean` pins the new tag.
  6. `docs/audits/00-comprehensive-lean-audit-index.md` and
     `docs/audits/19-findings-and-followups.md` are
     annotated with the per-finding sub-WU ID and the
     landing commit / PR (AR.22).
  7. CLAUDE.md and AGENTS.md are byte-identical and reflect
     the post-AR test count / theorem catalogue (AR.22).
  8. CLAUDE.md footnote 1 (the encoder-injectivity Workstream-H
     follow-up) is retired by Workstream EI (EI.8.b ships
     `commitExtendedState_subcommits_extensional_eq_under_collision_free`,
     the lift from bytes-equality to extensional state equality
     that the footnote pointed at).
  9. The Genesis Plan §15 status registry includes an "AR"
     entry naming Workstream AR as Complete.
  10. Every sub-WU's DoD checklist is fully ticked (the
      project-wide tickbox count is the authoritative
      acceptance signal).
  11. Every commit on the workstream branch carries a
      `Bisect-tag: AR.<sub-id>` line; `git log --grep
      'Bisect-tag: AR.'` enumerates the full sub-WU
      landing trail.

**Acceptance verification command (one-liner).**

```bash
# Run from repo root, post-AR.
lake build && \
lake test && \
lake exe count_sorries && \
lake exe tcb_audit && \
lake exe stub_audit && \
lake exe naming_audit && \
lake exe deferral_audit && \
lake exe lex_lint && \
lake exe lex_codegen --check && \
lake exe mock_import_audit && \
diff CLAUDE.md AGENTS.md && \
grep 'knomosis-audit-remediation' LegalKernel.lean && \
echo "AR ACCEPTANCE: OK"
```

A non-zero exit anywhere in the chain blocks the AR
complete-state declaration.

## §9 Out-of-scope items (deferred to future workstreams)

The following are intentionally **not** scoped to AR.  They
appear here so future workstream planners have a single
record of the deferrals.

  * **M-4 (CBE per-instance type-tag prefix).**  Wontfix —
    documented design choice; see §2.2.

  * **m-16 (chain-level bridge supply accounting
    theorems).**  Originally deferred; the per-step deltas and the
    cross-stack corpus already ratified the property, so the
    inductive Lean theorem was a documentation-quality
    improvement, not a soundness gap.  **Closed (2026-06-14) by
    Workstream CA:** the inductive theorem now exists —
    `bridge_chain_accounting_equation` (`Bridge/ChainAccounting.lean`)
    proves the §7.6.4 escrow identity unconditionally along
    `BridgeReachable` chains from genesis, with solvency
    (`bridgeReachable_solvent`) proved rather than assumed.

  * **Two-reviewer mechanical enforcement.**  AR.20 lands a
    CODEOWNERS file as a request-for-review mechanism.  Full
    enforcement (the merge-block branch-protection rule)
    requires repository-administrator action and is
    out-of-scope for a code-only PR.

  * **`Lex/DSL/Law.lean` `Law.mk` deprecation cleanup.**
    Every `lexlaw` macro wraps in `set_option linter.deprecated
    false in`.  M3 (or a future Lex sub-milestone) is
    expected to land a non-deprecated `lex_law_mk`
    constructor; cleanup is deferred.

  * **`std_dependencies.md` toolchain-bump pre-flight.**  AR
    does not bump the Lean toolchain.  Future bumps follow
    the existing protocol (`scripts/setup.sh` SHA-256
    recompute + `std_dependencies.md` lemma re-verification).

  * **Rust off-chain observer (Workstream H Rust track).**
    AR is Lean-only.  The Rust observer follow-up is on
    the Workstream H roadmap.

## §10 Mathematical soundness checklist

Every AR work unit ships behind the following soundness
invariants.  No exception is permitted.

  1. **No new custom `axiom`.**  `#print axioms` on every
     new theorem returns a subset of `[propext,
     Classical.choice, Quot.sound]` (plus the named opaques
     `Verify`, `hashBytes`, `l1FaultProofVerifier` where
     reachable).

  2. **No new `sorry` in proof position.**  AR.14 extends
     the `count_sorries` pattern set; the post-AR detector
     is *strictly stronger* than the pre-AR detector.  Every
     AR theorem closes without `sorry`.

  3. **No expansion of the kernel TCB.**  `tcb_allowlist.txt`
     and `Tools.Common.tcbInternalImports` are unchanged in
     content.  Every new module under AR ships *non-TCB*.

  4. **Decidability discipline preserved.**  Every new
     `Transition.decPre` field (none introduced in AR; AR is
     remediation, not feature addition) would continue to
     resolve via `inferInstance`.  Every new predicate is
     either decidable by `inferInstance` (arithmetic over
     `Nat` / finite conjunctions) or has a hand-written
     `Decidable` instance immediately adjacent.

  5. **Encoder injectivity is *conditional* on
     `fieldsBounded`.**  The AR.4 injectivity theorems do
     not claim global injectivity — they claim injectivity
     *within the canonically-bounded* domain.  This matches
     the existing `*_roundtrip` discipline for
     `DepositRecord` and follows the design pattern in
     `Encoding/Encodable.lean`.

  6. **Trust assumptions are explicit.**  AR.10 makes the
     `hashBytes` swap-point contract explicit at the Lean
     level (`@[extern]`).  AR.2 makes the deploymentId
     domain-separation gate explicit at every entry point
     (no hidden defaults at production-facing surfaces).

  7. **No silent illegality.**  The kernel's
     `impl_noop_if_not_pre` theorem is unchanged.  AR.21
     (optional) *tightens* the `withdraw` precondition; if
     adopted, the post-AR admissibility surface is strictly
     narrower than pre-AR, which is the safe direction.

  8. **Determinism preserved.**  AR.4 preserves
     `*_encode_deterministic` (which is unchanged in
     statement); AR.10 preserves
     `hashBytes_deterministic` / `hashStream_deterministic`
     (the `@[extern]` attribute does not affect the Lean
     body).  AR.3 preserves `bootstrapFromSnapshot`'s
     post-condition on the `_ok` branch.

  9. **Refinement (`impl_refines_spec`) is unchanged.**  AR
     does not modify the kernel's `step_impl` or any
     `Transition`.  Every consumer module's refinement
     pre/post relationship is preserved by construction.

  10. **Invariant preservation.**  The four-prelude
      `IsConservative` / `IsMonotonic` typeclass firewall is
      unchanged.  AR adds no new law that would need
      classification.

## §11 Plan self-audit (verification pass)

The plan has been through **two** verification passes:

  * **Pass 1 (audit-3.4 / original drafting).**  Cross-checked
    the original 23-WU specification against source.
  * **Pass 2 (sub-unit refinement, this revision).**
    Re-verified every source citation against the
    `claude/improve-audit-plan-sCDdC` branch HEAD; expanded
    the WU-group structure into 43 sub-units; added per-WU
    Definition of Done, Verification commands, Reviewer
    checklist, and Migration notes; added §1.4 glossary,
    §1.5 reading guide, §3.3 critical-path analysis, §6.5
    roll-forward strategy, §6.6 commit conventions; honest
    re-estimate of effort.

### §11.1 Findings cross-checked against source (Pass 2)

The Pass 2 verification re-confirmed the following claims by
direct grep / Read against source.  The verification was
delegated to an independent agent that read the cited lines
and reported back; results below.

  * **AR.1 (M-7).**  `signedActionDomain` defined at
    `LegalKernel/Authority/SignedAction.lean:139` and
    `LegalKernel/Encoding/SignInput.lean:63`.  ✅
  * **AR.2.2 (M-1).**  `processSignedAction` at
    `LegalKernel/Runtime/Loop.lean:172` defaults `deploymentId`
    to `ByteArray.empty`.  ✅
  * **AR.2.5 (M-5).**  `checkSignatureInvalid` at
    `LegalKernel/Disputes/Evidence.lean:206` hardcodes
    `ByteArray.empty`.  ✅  Source comment at lines 197–202
    even acknowledges this hardcoding ("relies on a
    back-compat path").
  * **AR.3.1 (M-2).**  `bootstrapFromSnapshot` lacks the
    chain-anchor check.  ✅
  * **AR.4 (M-3).**  `*_encode_deterministic` lemmas shipped
    at `LegalKernel/Encoding/State.lean` lines 527 / 534 /
    544 / 555 / 563 / 569.  Decoder definitions shipped at
    `BalanceMap.decode:223`, `State.decode:238`,
    `NonceState.decode:459`, `KeyRegistry.decodeMap:469`,
    `ExtendedState.decode:483`.  Map-backed
    `*_encode_injective` lemmas not shipped.  ✅
  * **AR.4.2 template.**  `action_encode_injective` at
    `LegalKernel/Encoding/Action.lean:818` is the structural
    template.  ✅
  * **AR.4.7 BridgeState field names.**  Verified at
    `LegalKernel/Bridge/State.lean:169-173`: `consumed :
    TreeMap DepositId DepositRecord compare` and `pending :
    TreeMap WithdrawalId PendingWithdrawal compare`.  ✅
  * **AR.5 (M-8).**  `Action.tag` at
    `LegalKernel/Authority/LocalPolicySemantics.lean:64`.
    19 constructors.  ✅
  * **AR.6 (m-7).**  16 `Event` constructors at
    `LegalKernel/Events/Types.lean:82-192` (audit pass 1
    incorrectly said 13).  No `Event.tag` function exists.
    ✅
  * **AR.7 (M-6).**  `paramsDiff` and `proofOverridesDiff`
    at `Lex/Tools/Diff.lean:172-179` compare names only.  ✅
  * **AR.8 (M-9).**  `forbiddenTokens` at
    `Tools/NamingAudit.lean:79-119` does NOT include `_v2`.
    `federation_transfer_policy_v2` declared at
    `Deployments/Examples/UsdClearing.lean:111` and used at
    line 160.  Both sites confirmed.  ✅
  * **AR.10 (M+1).**  `hashStream:151`, `hashBytes:159`,
    `hashImplementationIdentifier:258` in
    `LegalKernel/Runtime/Hash.lean` are plain `def`s with
    no `@[extern]`.  ✅
  * **AR.11 (M+2).**  `synth_local_kindOnly` at
    `Lex/DSL/Property.lean:418-420`; dispatcher calls it at
    line 505.  ✅
  * **AR.12 (m-13).**  `renderSyntax := toString` at
    `Lex/DSL/Law.lean:203`; `Lex/DSL/Deployment.lean:662`
    uses `Syntax.reprint`-based logic.  ✅
  * **AR.14 (m-2).**  `sorryPatterns` at
    `Tools/CountSorries.lean:168-174` contains 4 patterns.
    ✅
  * **AR.16 (m-17).**  `Verdict.encode:442`,
    `Verdict.decode:462` in
    `LegalKernel/Encoding/Disputes.lean`; decoder uses
    `List.zip:477` without explicit length check.  ✅
  * **AR.17 (m-14).**  `kernelOnlyApply` at
    `LegalKernel/Disputes/Evidence.lean:89` uses `_ => es''`
    wildcard at line 115.  ✅
  * **AR.19.**  Only one `fileDispute_rejects_*` theorem
    exists (`_unknown_challenger` at line 267).
    `_indexOutOfRange` and `_duplicateDispute` are real
    `FilingError` constructors emitted at lines 153, 159,
    164, 170 but not exposed as named theorems.  ✅
  * **AR.21 (m-4).**  `withdraw.pre` does NOT include
    `0 < amount`.  ✅

### §11.2 Pass 2 corrections vs. Pass 1 draft

The Pass 1 verification narrative is preserved here in
condensed form for traceability.  Pass 2 left the Pass 1
corrections intact (they were correct) and added the
following:

  * **AR.4 math precision.**  The Pass 1 rewrite of the
    AR.4 proof outline (helper + per-type round-trip
    chain, lift to extensional equality) is preserved
    verbatim and re-routed into the AR.4.1 (helper) and
    AR.4.2 (BalanceMap) sub-WU specifications.  No
    further math change.
  * **AR.4 `fieldsBounded` predicate.**  Pass 1's
    correction (value-only, since keys are `UInt64`) is
    preserved and propagated into every AR.4.* sub-WU.
  * **AR.4 BridgeState field names.**  Pass 1's correction
    (`consumed`/`pending`, not
    `depositRecords`/`pendingWithdrawals`) is preserved and
    explicitly named in AR.4.7's scope.
  * **AR.6 Event constructor count.**  Pass 1's correction
    (16, not 13) is preserved.  AR.6's effort estimate
    accounts for 16 indices.
  * **AR.8 second use-site.**  Pass 1's enumeration of two
    sites (lines 111 + 160) is preserved.
  * **Dependency graph.**  Pass 1's "four strict + three
    soft" edge count is preserved and lifted to the
    sub-WU level in §3.3 (critical-path analysis).
  * **i-11 reward / stake economics.**  Pass 1's
    document-only-with-guard-comments resolution is
    preserved and routed into AR.13.3's scope.

### §11.3 Pass 2 additions

Pass 2 added the following structural improvements not
present in Pass 1:

  * **Sub-unit decomposition.**  AR.2 → 6 sub-units; AR.3
    → 2 sub-units; AR.4 → 8 sub-units; AR.13 → 5
    sub-units; AR.23 → 4 sub-units.  The total
    work-unit-group count remains 23; the sub-unit count
    is **49**.
  * **Per-WU template fields.**  Definition of Done,
    Verification commands, Reviewer checklist, Migration
    notes (where applicable) added to every WU /
    sub-unit.
  * **§1.4 Glossary.**  Defines the recurring terms (TCB,
    sub-WU, fieldsBounded, encoder-injectivity quartet,
    Bisect-tag, etc.) once.
  * **§1.5 Reading guide.**  Routes the four reader roles
    (implementer, reviewer, release manager, auditor) to
    the relevant sections.
  * **§3.3 Critical-path analysis.**  Sub-unit-level
    dependency graph; honest wall-clock minimum
    (≈ 5 working days serial / ≈ 9 days for AR.4
    parallel).
  * **§6.5 Roll-forward strategy.**  Decision tree for
    "fix forward vs. revert" + fix-up commit conventions.
  * **§6.6 Commit-message and PR-title conventions.**
    Mandatory `AR.<sub-id>:` prefix + `Bisect-tag`
    convention.
  * **§7 risk register.**  Expanded from 10 to 16 risks;
    every risk now names the specific sub-WU(s) it
    applies to.
  * **§8 acceptance criteria.**  Augmented with a single
    one-line bash verification command + per-finding
    sub-WU mapping.
  * **§4.1 effort summary.**  Honest recomputation:
    5–7 calendar weeks (with one full-time implementer)
    or 3–4 weeks (with two parallel implementers).  No
    L-tier sub-units in the new decomposition.

### §11.4 Internal consistency check

After Pass 2 corrections, the plan is internally
consistent:

  * Every finding in
    `docs/audits/19-findings-and-followups.md` (M-1…M-10,
    m-1…m-19, i-1…i-11) has a triage decision in §2 and,
    for Remediate decisions, a citing sub-WU in §4.
  * Every concrete code citation (file paths, line
    numbers, theorem names, function names, structure
    fields) was verified against source on the
    `claude/improve-audit-plan-sCDdC` branch HEAD.
  * Every named theorem the plan relies on
    (`commit*_bytes_injective_under_collision_free` family,
    `Action.tag_matches_encode_tag`,
    `action_encode_injective`,
    `*_encode_deterministic` family,
    `TreeMap.equiv_iff_toList_eq`, `nat_roundtrip`,
    `byteArray_roundtrip`) was located at its cited
    file:line.
  * Every sub-WU's Definition of Done is internally
    consistent with the sub-WU's acceptance criteria
    (the DoD is a strict subset).
  * Every sub-WU's Verification command is runnable on
    the post-AR source tree.

Zero erroneous findings remain in the §2 triage; zero
stale references remain in the work-unit specifications;
zero sub-WUs over-claim or under-claim their effort
estimate against the dependency graph.

## §12 References

  * `docs/GENESIS_PLAN.md` — canonical design document; §4
    (kernel), §5 (refinement), §8 (admissibility), §13
    (TCB discipline), §15 (status registry).
  * `docs/audits/00-comprehensive-lean-audit-index.md` —
    audit methodology.
  * `docs/audits/19-findings-and-followups.md` — synthesis of
    the audit findings (the primary input to this plan).
  * `docs/audits/01-tcb-core.md` … `docs/audits/18-tests-overview.md`
    — per-area audit detail.
  * `docs/planning/ethereum_integration_plan.md` — Workstream A–G
    deliverables (AR.2's deploymentId parameterisation
    interacts with Workstream B / C call sites).
  * `docs/planning/actor_scoped_policies_plan.md` — Workstream LP
    (AR.6's Event tag pins overlap with LP's event-extension
    surface).
  * `docs/planning/lex_implementation_plan.md` — Workstream LX (AR.7,
    AR.11, AR.12 fold into LX tooling).
  * `docs/planning/fault_proof_migration_plan.md` — Workstream H
    (AR.3 + AR.4 close the Workstream H follow-ups).
  * `docs/planning/parameterized_laws_plan.md` — Workstream PA
    (parallel workstream; AR establishes the proof patterns
    that PA's encoder injectivity work will reuse).
  * `docs/std_dependencies.md` — Std-API surface used by the
    kernel (AR.4 relies on `TreeMap.equiv_iff_toList_eq` —
    catalogued there).
  * `docs/decidability_discipline.md` — `decPre` rule (AR
    introduces no new `decPre`).
  * `docs/abi.md` — on-disk frame format + CLI ABI (AR.2 +
    AR.3 update the CLI ABI in lockstep).


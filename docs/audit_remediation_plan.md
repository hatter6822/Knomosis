<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
three buckets:

  * **Remediate** — a defect that admits a clean, well-scoped fix
    without expanding the TCB or introducing new trust
    assumptions.  Scheduled as a numbered work unit.
  * **Document** — a design choice that the audit correctly
    flagged but where the right response is to record the
    rationale rather than to change the code (e.g. M-4 — CBE
    type-tag discipline is position-typed by spec; changing it
    would be a TCB-adjacent wire-format break).
  * **Defer** — work that requires substantial new theorem
    development beyond the scope of remediation (e.g. chain-level
    bridge accounting theorems whose ratification lives in the
    cross-stack corpus).

Every "Remediate" work unit ships behind the existing CI gates
(`tcb_audit`, `count_sorries`, `stub_audit`, `naming_audit`,
`deferral_audit`, `lex_lint`, `lex_codegen --check`, strict
warnings, `lake build`, `lake test`), preserves the §13.6
two-reviewer rule for any TCB-touching change, and adds zero
custom axioms.

## Status

  * **Drafted on branch:** `claude/audit-findings-workstream-oyEAO`.
  * **Phase prefix:** `AR` (Audit Remediation) — work units
    labelled `AR.1` … `AR.23` to disambiguate from the
    Genesis-Plan `Phase 0`/`Phase 1`/… numbering, from the
    Ethereum-integration `A`/`B`/`C`/`D` workstream prefixes,
    from the Local-Policy workstream `LP`, the Lex workstream
    `LX`, the Fault-Proof workstream `H`, and the Parameters
    workstream `PA`.
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
  * §2   Finding triage — every audit finding examined
  * §3   Work-unit dependencies
  * §4   Work-unit specifications (AR.1 – AR.23)
  * §5   Sequencing and PR structure (eight groups)
  * §6   Quality gates and rollback discipline
  * §7   Risk register and mitigations
  * §8   Acceptance criteria for Workstream AR overall
  * §9   Out-of-scope items (deferred to future workstreams)
  * §10  Mathematical soundness checklist
  * §11  Plan self-audit (verification pass)
  * §12  References

Each work unit in §4 stands alone: title, finding map, scope,
math/proof outline, implementation steps, acceptance criteria,
test plan, risk, and effort estimate.  Read in order for a
guided walkthrough; jump to a specific WU by Ctrl-F on its
identifier (e.g. `AR.4`).

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
     docstrings claim a `canon_hash_bytes` C ABI symbol that
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
     `applyVerdictUnchecked` `private` so production callers
     cannot reach the unchecked variant by accident.  AR.19 adds
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

| ID    | Finding                                                                                                              | Triage                | Work unit |
|-------|----------------------------------------------------------------------------------------------------------------------|-----------------------|-----------|
| M-1   | `Replay`'s `Admissible.decidable` and Runtime `processSignedAction` default `deploymentId := ByteArray.empty`.       | Remediate             | AR.2      |
| M-2   | `bootstrapFromSnapshot` does not chain-anchor the discarded log prefix against the snapshot's seed hash.             | Remediate             | AR.3      |
| M-3   | Map-backed sub-state encoders ship `*_encode_deterministic` only; no `*_encode_injective` / `*_roundtrip`.           | Remediate             | AR.4      |
| M-4   | CBE major-type tags collide across types (`Bool true` vs `Nat 1`).                                                   | Wontfix — design intent | n/a     |
| M-5   | `checkSignatureInvalid` hardcodes `deploymentId := ByteArray.empty`.                                                  | Remediate             | AR.2      |
| M-6   | `Lex/Tools/Diff.lean`'s param / proof-override comparators compare names only.                                       | Remediate             | AR.7      |
| M-7   | `signedActionDomain` constant duplicated as a string literal at two locations.                                       | Remediate             | AR.1      |
| M-8   | Three parallel `Action`-tag enumerations; only 4 of 19 indices pinned by tests.                                      | Remediate             | AR.5      |
| M-9   | `naming_audit` does not include `_v2` despite CLAUDE.md listing `v2` as a forbidden temporal marker.                  | Remediate             | AR.8      |
| M-10  | `MockCrypto`'s docstring claims `stub_audit` flags production imports; it does not.                                  | Remediate             | AR.9      |
| **M+1** | `hashBytes` / `hashStream` / `hashImplementationIdentifier` carry no `@[extern]` annotation; documented swap-point unrealised. | Remediate     | AR.10     |
| **M+2** | `synth_local_kindOnly` unconditionally admits every kernel-impl statement; `local [S]` claims are effectively always-true via the M1 dispatcher. | Remediate | AR.11 |

### §2.3 Minor findings (m-1 … m-19)

| ID    | Finding                                                                                          | Triage              | Work unit |
|-------|--------------------------------------------------------------------------------------------------|---------------------|-----------|
| m-1   | `tcb_audit` silently accepts unrecognised import forms (`prelude`, `import all`, `meta import`).  | Document only       | AR.13     |
| m-2   | `count_sorries` pattern set misses `refine sorry`, `apply sorry`, `(sorry : T)`, `· sorry`.       | Remediate           | AR.14     |
| m-3   | `stub_audit` 12-line docstring lookback is a magic number.                                       | Document only       | AR.13     |
| m-4   | `withdraw`'s precondition permits `amount = 0`.                                                  | Remediate           | AR.21     |
| m-5   | `deposit.pre := True`; runtime carries replay protection.                                        | Document only       | AR.13     |
| m-6   | `affectedActors` misses actors gained-only (no pre-state entry).                                  | Document only       | AR.13     |
| m-7   | `Event` constructor-index drift not mechanically enforced.                                       | Remediate           | AR.6      |
| m-8   | Lex codegen fence-marker contract is a string convention.                                        | Document only       | AR.13     |
| m-9   | `Lex/Tools/Common.lean` reverse-alphabetical JSON field order.                                    | Document only       | AR.13     |
| m-10  | Lex M1 `requiresEmission := false` universally — codegen is no-op.                                | Document only       | AR.13     |
| m-11  | `synth_*` synthesizers emit placeholder strings.                                                 | Remediate (partial) | AR.11     |
| m-12  | `Shim.stmtReferencesSignedBy` is positionless substring match.                                   | Document only       | AR.13     |
| m-13  | `lexlaw`'s `renderSyntax := toString` drifts from user source bytes.                              | Remediate           | AR.12     |
| m-14  | `kernelOnlyApply` uses non-exhaustive `_ => s` wildcard.                                         | Remediate           | AR.17     |
| m-15  | `ingest` returns `none` for `depositInitiated`; deposit flow bypasses ingest.                     | Document only       | AR.13     |
| m-16  | §7.6.4 / §7.6.5 chain-level accounting deferred to runtime cross-stack verification.              | Defer               | n/a       |
| m-17  | `Verdict.encode` relies on `List.zip_unzip`; fragile on mismatched lengths.                       | Remediate           | AR.16     |
| m-18  | Lex codegen non-deterministic load order under duplicate-index registries.                       | Document only       | AR.13     |
| m-19  | Three stale docstring claims (Codegen `--canonical`, Crypto `Verify`, LogFile hash width).        | Remediate           | AR.13     |

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
| i-11  | Reward / stake economics has sharp edges but is non-TCB.                                          | Document only (AR.13 expands the four cited sites with explicit guard comments: `claimImpugnedAmount` skip-bridge-actions, `proportionalChallengerReward` divisor-0 fallback, `stakeWeightedAdjudicatorRewards` sum-le-pool not-shipped-as-theorem, `Staking.stakeResolutionActions` rollback runtime-invariant). |

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

The 23 work units form a partial order with **four** strict
edges (must-precede) and **three** soft edges (recommended but
not blocking).  Everything else can land in parallel.

### §3.1 Strict ordering edges

```
AR.5  Action tag regression tests   ┐
                                     ├──► AR.2  DeploymentId parameterisation
AR.6  Event tag regression tests    ┘     │
AR.1  Shared signedActionDomain     ─────►│
                                          │
AR.8  naming_audit _v2 alignment    ─►    │
                                          ▼
                                       AR.3  Snapshot bootstrap chain-anchor
                                          │
                                          ▼
                                       AR.23 End-to-end regression suite
                                          │
AR.10 Hash @[extern] annotations    ─►    │
AR.4  Encoder injectivity (deepest) ─►    │
                                          ▼
                                       AR.22 Documentation updates
                                             (last; bumps `kernelBuildTag`)
```

Edge rationale:

  * **AR.1 → AR.2 (strict).**  AR.2 routes the deploymentId
    through `signedActionDomain`; the shared constant must
    exist first or AR.2 would be threading through a
    duplicated literal.
  * **AR.2 → AR.3 (strict).**  AR.3 invokes the new
    `bootstrapFromSnapshot` parameterised entry; AR.2
    supplies the deploymentId field on `RuntimeState` that
    AR.3 reads.
  * **AR.3 → AR.23 (strict).**  The end-to-end regression
    suite exercises the snapshot-bootstrap anchor check.
  * **Everything → AR.22 (strict).**  Documentation updates
    land last; the `kernelBuildTag` bump and the test-count
    refresh reflect the *cumulative* AR delta.
  * **AR.5, AR.6 → AR.2 (soft).**  The constructor-tag
    regression tests pin the current on-disk index space.
    Recommended to land first so any accidental tag drift in
    AR.2 surfaces immediately; soft because AR.2 does not
    touch `Action` / `Event` constructors directly.
  * **AR.8 → AR.2 (soft).**  AR.2 introduces new identifiers
    (e.g. `processSignedActionWith`); these names must clear
    the extended `naming_audit` token list.  Soft because
    AR.8 extends the list with `_v2`/`_v3`/etc. — the new
    AR.2 identifiers don't include those substrings either
    way.
  * **AR.4, AR.10 → AR.23 (soft).**  AR.23 includes
    integration coverage that exercises the AR.4 encoder
    injectivity and the AR.10 hash extern annotation.  Soft
    because the suite is testable without these but its
    coverage statement depends on them.

### §3.2 Parallel-safe work units

The following work units have no incoming strict edges and
can land at any time within their PR group (see §5):

  * **AR.7** — Lex Diff comparator (Lex-tools-only).
  * **AR.9** — MockCrypto import detector (audit-tools-only).
  * **AR.11** — `synth_local` resource dispatch (Lex DSL).
  * **AR.12** — `lexlaw` `renderSyntax` (Lex DSL).
  * **AR.13** — Stale docstring fixes (cosmetic).
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

AR.4 (encoder injectivity) is the deepest theorem work and
has no incoming dependency.  It can land entirely in
parallel with the deploymentId track (AR.1/AR.2/AR.3) — they
do not share any file.  This is the single most important
parallelisation opportunity in AR: AR.4 unblocks
Workstream H's final follow-up, and AR.1/AR.2/AR.3 close the
cross-deployment-replay hazard.  Different reviewers can
handle each track concurrently.

## §4 Work-unit specifications

Each work unit below carries:

  * **Finding map** — which audit findings it remediates.
  * **Scope** — files created / modified.
  * **Math / proof outline** — the theorem statements (where
    applicable), the proof strategy, and the trust posture
    (`#print axioms` expectation).
  * **Implementation steps** — atomic, ordered, ≤ ~30 line
    minimum granularity each.
  * **Acceptance criteria** — what passes / fails post-WU.
  * **Test plan** — specific cases (positive, negative, edge).
  * **Risk** — what could go wrong, mitigations.
  * **Effort estimate** — small / medium / large
    (S ≤ 1 day, M ≤ 1 week, L > 1 week of focused work).

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

**Risk.**  Low.  Pure constant extraction.  No proof
content changes.  Encoding round-trip and `signingInput_eq_encoding`
both rely on `rfl`-reduction of the constant; consolidation
preserves this.

**Effort estimate.**  S (≤ ½ day).

### AR.2 — DeploymentId parameterisation (Runtime + Replay + Disputes)

**Finding map:** M-1 (Replay tool's `Admissible.decidable` and
Runtime `processSignedAction` default `deploymentId :=
ByteArray.empty`); M-5 (`Disputes.Evidence.checkSignatureInvalid`
hardcodes `ByteArray.empty`).

**Scope.**

  * `LegalKernel/Runtime/Loop.lean` — modify
    `processSignedAction`; add `RuntimeState.deploymentId`
    field; modify `bootstrap`, `bootstrapFromSnapshot`.
  * `LegalKernel/Runtime/Replay.lean` — replace
    `Admissible.decidable` aliasing with a parameterised
    decidability instance; expose a `replayWithDeploymentId`
    entry point.
  * `LegalKernel/Disputes/Evidence.lean` — add
    `checkSignatureInvalidWith` parameterised variant; mark
    the existing `checkSignatureInvalid` as a back-compat
    alias.
  * `LegalKernel/Disputes/Filing.lean` — thread
    `deploymentId` through `fileDispute` if the call site is a
    `signatureInvalid` claim.
  * `Main.lean` — accept `--deployment-id <hex>` flag; pipe
    into `RuntimeState`.
  * `Replay.lean` — accept `--deployment-id <hex>` flag; pipe
    into the replay entry point.
  * `LegalKernel/Test/Runtime/Loop.lean` — add round-trip test
    asserting that a `processSignedActionWith d1` event cannot
    be replayed under `d2 ≠ d1`.
  * `LegalKernel/Test/Disputes/Evidence.lean` — add
    cross-deployment regression for `checkSignatureInvalidWith`.

**Math / proof outline.**  The cross-deployment-replay
protection (`Audit-3.4`, §8.8.5) is provided by the
domain-separation prefix in `signInput`: every signature
verification is over `(domainPrefix, deploymentId, action,
signer, nonce)`.  A signed action signed under deploymentId
`d1` cannot satisfy `Verify pk msg sig` when re-checked under
`d2` ≠ `d1`, because `msg` differs in the deploymentId field.

Two theorem signatures exist:

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
changes.

After AR.2, the regression test
`processSignedAction_cross_deployment_rejects` ships:

```lean
theorem processSignedAction_cross_deployment_rejects
    (es : ExtendedState) (st : SignedAction)
    (d₁ d₂ : ByteArray) (h : d₁.toList ≠ d₂.toList) :
    -- "signed-under-d₁" does not satisfy AdmissibleWith
    -- under d₂ for any non-trivial Verify
    ¬ AdmissibleWith Verify P d₂ es st
        ∨ Verify (es.registry[st.signer]?.getD ...)
                 (signInput st.action st.signer st.nonce d₁)
                 st.sig = false
```

The disjunction matches the `Verify`-opaque-default-`false`
reality: at the Lean level, `Verify` returns `false`, so the
right disjunct holds vacuously; at the production level, the
left disjunct holds non-vacuously.  The runtime test uses the
`MockCrypto` adaptor to verify the left disjunct under a
controllable `Verify` implementation.

**Implementation steps.**

  1. **Runtime field plumbing.**  Add a `deploymentId :
     ByteArray` field to `RuntimeState`.  Update
     `RuntimeState.empty` (or its equivalent).  Update
     `processSignedAction` to call
     `processSignedActionWith Verify rs.deploymentId rs st`
     instead of hard-coding `ByteArray.empty`.

  2. **Bootstrap plumbing.**  Add a `deploymentId : ByteArray`
     parameter to `bootstrap` and `bootstrapFromSnapshot`.
     Default value `ByteArray.empty` for back-compat in the
     test harness; CLI entry points require the parameter.

  3. **Replay plumbing.**  Add a `replayWithDeploymentId`
     entry point that parameterises the decidability instance
     by `d`; expose it as the canonical CLI path.  Keep
     `replay` (the un-parameterised form) as a
     test-internal helper.

  4. **Dispute plumbing.**  Add `checkSignatureInvalidWith`
     which carries the deploymentId.  Mark
     `checkSignatureInvalid` as a back-compat alias (in
     practice, callers should not use it).

  5. **CLI flags.**  Add `--deployment-id <hex>` to `Main.lean`
     and `Replay.lean`.  Parse `<hex>` as a `ByteArray` via
     the existing hex-decoding helper (or introduce one if
     absent).  Pipe into the runtime / replay state.

  6. **Default-empty diagnostic.**  When the CLI runs without
     `--deployment-id`, emit a stderr warning analogous to
     the existing fallback-hash warning (e.g.
     `"warning: --deployment-id not supplied; using empty
     sentinel (dev mode)"`).  Refuse the empty sentinel in
     `canon-replay` (the audit binary).

  7. **Tests.**  Land
     `processSignedAction_cross_deployment_rejects` and
     `checkSignatureInvalidWith_cross_deployment_distinguishes`.

**Acceptance criteria.**

  * `processSignedAction` is one line:
    `processSignedActionWith Verify rs.deploymentId rs st`.
  * Searching for `ByteArray.empty` in `Runtime/` returns no
    hits (other than the back-compat alias).
  * Searching for `ByteArray.empty` in `Disputes/Evidence.lean`
    returns no hits.
  * `lake test` passes the new cross-deployment regression
    suite.
  * `#print axioms` on the new theorems returns the canonical
    three (plus `Verify`-opaque reachability where applicable).

**Test plan.**

  * **Positive — same deployment.**  `processSignedActionWith
    Verify d rs st` succeeds (or fails for a non-replay reason)
    iff the corresponding `AdmissibleWith` predicate holds.
  * **Negative — cross deployment.**  Build a signed action
    under `d₁`, attempt `processSignedActionWith Verify d₂ ...`
    with `d₂ ≠ d₁`; expect rejection.
  * **Dispute cross-deployment.**
    `checkSignatureInvalidWith d₁ log idx` on an entry signed
    under `d₂` returns `.rejected` (Verify fails), regardless
    of the in-state registry.

**Risk.**  Medium.  Touches the runtime hot path and the CLI
surface.  Mitigations:

  * Land AR.5 (Action tag regression tests) first so the
    on-disk frame format remains pinned during parameterisation.
  * Stage the CLI flag addition as a separate commit so the
    Lean library change can be reviewed independently.
  * Run the existing cross-stack tests
    (`solidity/make test-cross-stack`) to confirm the Solidity
    mirror is unaffected.

**Effort estimate.**  M (≤ 1 week).

### AR.3 — Snapshot bootstrap chain anchor + AttestedSnapshot CLI

**Finding map:** M-2 (`bootstrapFromSnapshot` does not verify the
log prefix chains to the snapshot's seed hash).

**Scope.**

  * `LegalKernel/Runtime/Loop.lean` — modify
    `bootstrapFromSnapshot` to add the chain-anchor check.
  * `LegalKernel/Runtime/AttestedSnapshot.lean` — expose a
    `bootstrapFromAttestedSnapshot` entry point that wraps
    `bootstrapFromSnapshot` with the attestor-signature check
    as a hard prerequisite.
  * `Main.lean` — `canon` accepts `--snapshot <path>
    --attested` (or refuses unattested cross-replica startup
    by default).
  * `LegalKernel/Test/Runtime/Loop.lean` —
    `bootstrapFromSnapshot_rejects_wrong_seed_hash` and
    `bootstrapFromSnapshot_accepts_correct_seed_hash`.
  * `LegalKernel/Test/Runtime/AttestedSnapshot.lean` — extended
    coverage of the CLI-required gate.

**Math / proof outline.**  The hash chain is `prevHash :=
hash(prev_entry)`; the first post-snapshot entry has
`prevHash = seedHash`.  M-2's observation is that the existing
`bootstrapFromSnapshot` calls `replayFromSeed policy seedHash
state tail`, which checks the chain *starting from* seedHash —
but only checks the first post-snapshot entry.  If the snapshot
is *the wrong snapshot* for a given log, the first entry's
chain check fires.  However, if the operator supplies a
*different log* that happens to be a valid chain on its own,
the post-snapshot tail's local chain is consistent and
bootstrap succeeds.  The defence against this is the
attestor's signature on the snapshot — covered by
`AttestedSnapshot`.

The chain-anchor check we add is structurally simple:

```lean
def bootstrapFromSnapshot
    (policy : AuthorityPolicy) (snap : Snapshot)
    (logPath : System.FilePath) :
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

  1. Add a new `BootstrapError` variant `.anchorMismatch`.

  2. Add the value-level anchor check before
     `replayFromSeed`.  The check is decidable and runs in
     `O(1)` (a single hash equality on 32 bytes).

  3. Update `Main.lean` to refuse `bootstrapFromSnapshot`
     without `--attested` unless an explicit
     `--unsafe-self-attested` opt-in is passed.

  4. Add the matching tests.

  5. Update `docs/abi.md` to document the new CLI flag and the
     anchor-mismatch failure mode.

**Acceptance criteria.**

  * `bootstrapFromSnapshot` rejects a snapshot whose
    `seedHash` does not match the actual log[baseIdx-1] hash.
  * `canon` CLI defaults to refusing cross-replica startup
    without `--attested`.
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
    behaviour).

**Risk.**  Low–Medium.  The check is simple; the risk is in the
CLI default change (refusing self-attested by default).
Mitigation: a clear migration note in `docs/abi.md` and
`docs/fault_proof_runbook.md`.

**Effort estimate.**  S–M (1–2 days).


### AR.4 — Map-backed sub-state encoder injectivity

**Finding map:** M-3 (`*_encode_deterministic` only; no
`*_encode_injective` for `State`, `ExtendedState`, `BridgeState`,
`LocalPolicies`, `KeyRegistry`, `NonceState`); resolves
informational observation i-8 (commit-injectivity at bytes level
only).

**Scope.**

The decoder definitions are already shipped in
`LegalKernel/Encoding/State.lean` (`BalanceMap.decode:223`,
`State.decode:238`, `NonceState.decode:459`,
`KeyRegistry.decodeMap:469`, `ExtendedState.decode:483`,
`Bridge.DepositRecord.decode:301`, `Bridge.PendingWithdrawal.decode:348`,
`Bridge.BridgeState.decode:427`).  The
`*_encode_deterministic` lemmas are shipped at lines 527 / 534
/ 544 / 555 / 563 / 569.  What is *not* shipped is the
`*_roundtrip` + `*_encode_injective` + `*_encode_injective_of_equiv`
quartet for the map-backed sub-states.  AR.4 lands the
theorem track on top of the existing decoder API.

Files modified:

  * `LegalKernel/Encoding/State.lean` —
    add `BalanceMap.fieldsBounded`,
    `balanceMap_roundtrip`,
    `balanceMap_encode_injective`,
    `balanceMap_encode_injective_of_equiv`;
    analogous lemmas for `State` (the outer map),
    `NonceState`, `KeyRegistry`, and `ExtendedState`;
    analogous lemmas for `Bridge.BridgeState`'s map-backed
    sub-structures (`consumed : TreeMap DepositId
    DepositRecord compare` and `pending : TreeMap
    WithdrawalId PendingWithdrawal compare`, encoded via
    `encodeConsumed` and `encodePending`; see
    `LegalKernel/Bridge/State.lean:169-173`).
  * `LegalKernel/Encoding/LocalPolicy.lean` — analogous for
    `LocalPolicies` (the `Authority.LocalPolicies` TreeMap).
    The clause-level `fieldsBounded` is already shipped at
    line 57; the missing pieces are the
    `localPolicies_roundtrip` + `_encode_injective` quartet.
  * `LegalKernel/FaultProof/Commit.lean` — extend
    `commitState_bytes_injective_under_collision_free` (and
    siblings) with a downstream
    `commitState_extensional_injective_under_collision_free`
    lemma chaining the new encoder injectivity.
  * `LegalKernel/Test/Encoding/State.lean` — round-trip +
    cross-value distinguishability tests for each new lemma.
  * `LegalKernel/Test/FaultProof/Commit.lean` — composition
    test showing the full chain
    `commit-eq → bytes-eq → encode-eq → toList-eq`.

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

**Effort estimate.**  L (1–2 weeks of focused proof work).

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

**Risk.**  Low.  New audit binary, similar in structure to
`naming_audit`.

**Effort estimate.**  S (≤ ½ day).

### AR.10 — Hash `@[extern]` annotations

**Finding map:** Cross-verification finding (no synthesis ID).
`LegalKernel/Runtime/Hash.lean:151, 159, 258` —
`hashStream`, `hashBytes`, `hashImplementationIdentifier` are
plain `def`s.  Their docstrings claim a `canon_hash_bytes` /
`canon_hash_identifier` C ABI symbol that production
deployments link against, but no `@[extern]` annotation is
present.

**Scope.**

  * `LegalKernel/Runtime/Hash.lean` — add `@[extern
    "canon_hash_bytes"]` to `hashBytes`; add `@[extern
    "canon_hash_stream"]` to `hashStream` (or remove the
    swap-point claim from its docstring if the production
    runtime really does only swap `hashBytes`); add
    `@[extern "canon_hash_identifier"]` to
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
`canon-extern` symbols in the deployment adaptor.

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
     @[extern "canon_hash_bytes"]        def hashBytes        ...
     @[extern "canon_hash_stream"]       def hashStream       ...
     @[extern "canon_hash_identifier"]   def hashImplementationIdentifier ...
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

**Risk.**  Low–Medium.  May surface latent drift in existing
sidecars; if so, update them via `lake exe lex_codegen`.

**Effort estimate.**  S (≤ ½ day).


### AR.13 — Stale docstring fixes and documented-behaviour notes

**Finding map:** m-19 (three stale docstring claims); m-1
(`tcb_audit` parser limits); m-3 (`stub_audit` lookback);
m-5 (`deposit.pre := True`); m-6 (`affectedActors` does not
cover gained-only actors); m-8 (codegen fence-marker
contract); m-9 (Lex JSON field order); m-10 (Lex M1
`requiresEmission := false`); m-12 (`Shim.stmtReferencesSignedBy`
positionless substring match); m-15 (`Bridge.ingest`
`depositInitiated` → none); m-18 (Lex codegen duplicate-index
non-determinism); and the per-area-audit notes on
`Bridge.State` DepositId projection, `WithdrawalRoot`
runtime-supplied hypotheses, and `WithdrawalProof` empty-tree
fallback.

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
    `applyActionToBridgeState` step.  See `docs/ethereum_integration_plan.md`
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

**Risk.**  Low.  No semantic change to the behaviour.

**Effort estimate.**  S (≤ 1 hour).

### AR.18 — `applyVerdictUnchecked` visibility

**Finding map:** per-area audit (`07-disputes.md`) —
`applyVerdictUnchecked` is exported without a Lean
visibility restriction; production callers may use it
directly.

**Scope.**

  * `LegalKernel/Disputes/Verdict.lean` — add `private`
    modifier to `applyVerdictUnchecked` (and any internal
    helpers that should not be on the public surface).
  * Any test files referencing it under the new visibility
    must use the `private`-export pattern (per Lean's
    `protected`/`private` rules) or be moved into the same
    namespace.

**Math / proof outline.**  None.

**Implementation steps.**

  1. Add `private` modifier.

  2. Search for call sites; gate test references under
     `open Verdict in` (or move tests into the same
     namespace).

  3. Re-build.

**Acceptance criteria.**

  * `applyVerdictUnchecked` is `private`.
  * No production caller can reach it without explicit
    namespace opening.
  * All existing tests still elaborate.

**Test plan.**  Self-test that an external module trying
to invoke `applyVerdictUnchecked` fails to elaborate.

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

**Acceptance criteria.**

  * Theorems shipped and named per the documented family.
  * `#print axioms` clean.

**Test plan.**

  * Value-level cases for each rejection variant.
  * Term-level API stability test.

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
    tag from `"canon-fault-proof-migration"` to
    `"canon-audit-remediation"`; bump the test count
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

**Risk.**  Low.

**Effort estimate.**  S (≤ ½ day).

### AR.23 — End-to-end cross-deployment-replay regression suite

**Finding map:** AR.2 sub-deliverable.  Listed separately
because the regression suite is the integration-level
acceptance criterion for AR.2 + AR.3.

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

  4. **AttestedSnapshot enforcement.**  `canon` CLI without
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

The 23 work units sum to roughly **3–6 weeks** of focused
engineering effort, distributed as follows:

| Work unit | Title (abbrev.)                       | Effort | Tier (PR group) |
|-----------|---------------------------------------|--------|-----------------|
| AR.1      | Shared signedActionDomain             | S      | Group 3         |
| AR.2      | DeploymentId parameterisation         | M      | Group 5         |
| AR.3      | Snapshot bootstrap chain-anchor       | S–M    | Group 6         |
| AR.4      | Encoder injectivity (5 sub-states)    | **L**  | Group 7         |
| AR.5      | Action tag regression tests           | S      | Group 2         |
| AR.6      | Event tag regression tests            | S      | Group 2         |
| AR.7      | Lex Diff comparator extension         | S      | Group 4         |
| AR.8      | naming_audit `_v2` + UsdClearing rename | S    | Group 3         |
| AR.9      | MockCrypto import detector            | S      | Group 4         |
| AR.10     | Hash `@[extern]` annotations          | S      | Group 4         |
| AR.11     | synth_local resource dispatch         | M      | Group 4         |
| AR.12     | lexlaw renderSyntax reprint           | S      | Group 4         |
| AR.13     | Stale docstring fixes (≥ 14 sites)    | S      | Group 1         |
| AR.14     | count_sorries exhaustive patterns     | S      | Group 1         |
| AR.15     | proportionalDilute guard comment      | S      | Group 1         |
| AR.16     | Verdict.encode boundary check         | S      | Group 4         |
| AR.17     | kernelOnlyApply exhaustive switch     | S      | Group 4         |
| AR.18     | applyVerdictUnchecked private         | S      | Group 1         |
| AR.19     | fileDispute rejection lemmas          | S      | Group 2         |
| AR.20     | `.github/CODEOWNERS`                   | S      | Group 1         |
| AR.21     | Withdraw positivity (optional)        | S–M    | Group 8         |
| AR.22     | Documentation updates                 | S      | Group 8         |
| AR.23     | Integration regression suite          | M      | Group 8         |

Legend: **S** ≤ 1 day, **M** ≤ 1 week, **L** > 1 week.

The **L-tier work unit AR.4** dominates the total.  Inside AR.4,
the five sub-state proofs (BalanceMap, State/ExtendedState,
NonceState, KeyRegistry, LocalPolicies, BridgeState) each take
roughly 2–3 days once the BalanceMap template is established;
the BalanceMap proof itself is closer to a week because it
establishes the reusable `*_decode` / `*_roundtrip` /
`*_encode_injective` quartet pattern.

The **M-tier work units** are AR.2 (deploymentId), AR.11
(synth_local), and AR.23 (integration suite).  AR.2 and AR.11
touch hot paths (Runtime / Lex macro elaborator); the M
estimate covers the implementation plus regression-test
authoring.  AR.23 is integration-test scaffolding.

The remaining 18 S-tier work units are mechanical or
small-scope; many can land as a single batched PR within their
PR group.

## §5 Sequencing and PR structure

The 23 work units land in **eight sequential PR groups**.
Each group is a single PR (or a tight series of co-landing
PRs) on the `claude/audit-findings-workstream-oyEAO` branch
(or a per-group sub-branch landing back into the workstream
branch).  Grouping is by theme + dependency, not strictly by
priority.

### Group 1 — Cosmetic + audit-tooling baseline

Lands first; no behavioural change; reduces noise for
subsequent groups.

  * **AR.13** — Stale docstring fixes (3 sites + ~10
    documented-behaviour notes).
  * **AR.14** — `count_sorries` exhaustive patterns.
  * **AR.15** — `proportionalDilute` snapshot-read guard
    comment.
  * **AR.18** — `applyVerdictUnchecked` visibility.
  * **AR.20** — `.github/CODEOWNERS`.

**PR boundaries within Group 1:**  AR.13 is one PR (single
audit, single review).  AR.14 is one PR.  AR.15 + AR.18 +
AR.20 can fold into a single "miscellaneous cleanup" PR.

**Build posture target:** clean `lake build`, `lake test`,
all five audit binaries green, plus the new `count_sorries`
pattern set elaborating against itself.

### Group 2 — Regression tests + tagging

Pins the *current* index space.  Lands after Group 1 so
audit-tooling extensions cannot interfere.

  * **AR.5** — Action tag regression tests (19 indices).
  * **AR.6** — Event tag regression tests (13 indices).
  * **AR.19** — `fileDispute` rejection lemmas.

**PR boundaries:** AR.5 + AR.6 fold into "constructor-tag
regression suite" — a single review covers both.  AR.19 is
one PR.

**Build posture target:** clean rebuild; the new tests pin
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

**Build posture target:** `lake exe naming_audit` reports
zero violations; the new shared-constant module elaborates.

### Group 4 — Tooling refinements

Closes the Lex governance gap.

  * **AR.7** — Lex Diff comparator extension.
  * **AR.9** — MockCrypto production-import detector.
  * **AR.10** — Hash `@[extern]` annotations.
  * **AR.11** — `synth_local` resource-aware dispatch.
  * **AR.12** — `lexlaw` `renderSyntax` byte-fidelity.
  * **AR.16** — `Verdict.encode` canonical-input boundary
    check.
  * **AR.17** — `kernelOnlyApply` exhaustive switch.

**PR boundaries:** AR.10 is one PR (the most consequential
trust-model-explicit change).  AR.11 + AR.12 fold (Lex DSL
internals).  AR.7 + AR.9 fold (audit tooling).  AR.16 +
AR.17 fold (Disputes hardening).

**Build posture target:** new audit binary green; Lex
synthesizer rejects ill-formed `local [S]` claims; Hash
`@[extern]` annotations elaborate; Disputes hardening
regression tests pass.

### Group 5 — DeploymentId parameterisation

The largest behavioural change.

  * **AR.2** — DeploymentId parameterisation (Runtime +
    Replay + Disputes).

**PR boundaries:** AR.2 is one PR but with three commits:
(a) Runtime field plumbing, (b) Replay parameterisation, (c)
Disputes parameterisation, (d) CLI flag wiring.

**Build posture target:** `processSignedAction` no longer
references `ByteArray.empty` (other than the back-compat
alias); cross-deployment rejection regression test passes.

### Group 6 — Snapshot bootstrap

Builds on the Group 5 deploymentId surface.

  * **AR.3** — Snapshot bootstrap chain anchor +
    AttestedSnapshot CLI.

**PR boundaries:** one PR.

**Build posture target:** `bootstrapFromSnapshot` rejects
wrong-anchor snapshots; `canon` CLI refuses unattested
cross-replica startup by default.

### Group 7 — Encoder injectivity (the deep theorem track)

The most theorem-intensive group.  Lands in parallel with
Groups 5/6 if reviewer bandwidth permits; otherwise lands
after.

  * **AR.4** — Map-backed sub-state encoder injectivity.

**PR boundaries:** AR.4 lands as five sub-PRs, one per
sub-state, in the order BalanceMap → State → NonceState →
KeyRegistry → LocalPolicies → BridgeState.  Each sub-PR
ships its own `*_decode`, `*_roundtrip`, `*_encode_injective`,
`*_encode_injective_of_equiv` quartet.  The final sub-PR
also lands the FaultProof.Commit composition lemma.

**Build posture target:** every map-backed encoder has its
injectivity quartet; the FaultProof chain composes
bytes-eq → encode-eq → toList-eq.

### Group 8 — Integration tests + documentation

Lands last; depends on every other group.

  * **AR.23** — End-to-end regression suite.
  * **AR.21** — Withdraw positivity (optional; lands here if
    the team agrees).
  * **AR.22** — Documentation: CLAUDE.md / GENESIS_PLAN.md /
    audit index updates; build tag bump.

**PR boundaries:** AR.23 is one PR.  AR.21 (if accepted) is
one PR.  AR.22 lands last as a unified doc-update PR.

**Build posture target:** all gates green, all integration
tests pass, build tag bumped.

## §6 Quality gates and rollback discipline

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

Each AR work unit is independently rollback-able:

  * **Group 1** (cosmetic): per-PR `git revert` produces a
    clean tree.
  * **Group 2** (regression tests): `git revert` removes
    the new test files; pre-AR test suite continues to
    pass.
  * **Group 3** (shared constants + renames): `git revert`
    restores the duplicated literals; rename is reverted
    by name swap.
  * **Group 4** (tooling): per-PR revert; new audit
    binary's `lakefile.lean` entry is removed.
  * **Group 5** (deploymentId parameterisation): revert
    requires restoring the `Runtime.processSignedAction =
    processSignedActionWith Verify ByteArray.empty` back-compat
    line.  All callers expecting parameterisation are removed
    in the same revert.
  * **Group 6** (snapshot bootstrap): revert removes the
    anchor check; pre-AR behaviour restored.
  * **Group 7** (encoder injectivity): revert per sub-PR.
    The FaultProof.Commit composition lemma is independent
    of the other consumers; reverting it does not affect
    `commitState_bytes_injective_under_collision_free`.
  * **Group 8** (integration tests + docs): revert removes
    the new test files; the `kernelBuildTag` is restored.

**Bisection discipline.**  Every AR PR carries a commit
message line `Bisect-tag: AR.<n>` so that a future
regression can be bisected to a specific work unit.

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
  5. **Cross-stack tests fail** (`solidity/make test-cross-stack`)
     — the AR change inadvertently broke the on-disk frame
     format.  Bisect to the offending commit; revert.

## §7 Risk register and mitigations

| ID    | Risk                                                                                              | Likelihood | Impact | Mitigation                                                                              |
|-------|---------------------------------------------------------------------------------------------------|-----------:|-------:|-----------------------------------------------------------------------------------------|
| R-1   | AR.4 encoder injectivity proof fails for a sub-state under unexpected Std-API drift.              | Low        | High   | Land BalanceMap first as the template; cross-verify each sub-state proof's `#print axioms`. |
| R-2   | AR.2 deploymentId parameterisation breaks a downstream test relying on the empty-default.        | Medium     | Medium | Search for `ByteArray.empty` in test files before landing; migrate any matches.         |
| R-3   | AR.10 `@[extern]` annotation causes elaboration failure under Lean v4.29.1.                      | Low        | Low    | Verify via local rebuild; the annotation is a documented Lean attribute.                |
| R-4   | AR.11 synthesizer change rejects a previously-accepted Lex law.                                  | Low–Medium | Medium | Run full Lex test suite; spot-check ExampleLex and UsdClearing deployments.            |
| R-5   | AR.3 snapshot anchor check rejects a previously-accepted operator snapshot.                      | Medium     | Medium | Migration note in `docs/fault_proof_runbook.md`; CLI fallback flag for explicit opt-in. |
| R-6   | AR.5 / AR.6 regression tests pass on the current source but a future PR with renamed indices fails the regression. | Low | Low (by design) | The "fails by design" outcome is what the regression is for; surface failure routes via `Bisect-tag`. |
| R-7   | AR.8 rename of `federation_transfer_policy_v2` breaks a downstream test.                         | Low        | Low    | Search for the identifier project-wide before renaming.                                |
| R-8   | AR.4 introduces a `fieldsBounded` hypothesis that downstream theorems do not satisfy.            | Medium     | Medium | Verify the hypothesis is satisfied by the runtime-introduced state; document as a deployment obligation. |
| R-9   | AR's broad set of changes accumulates merge conflicts on the long-lived branch.                  | Medium     | Low    | Land in the eight-group sequence; cherry-pick into smaller PRs if conflicts mount.     |
| R-10  | The CODEOWNERS file (AR.20) without a corresponding GitHub branch-protection rule is purely advisory. | High | Low | Document the limitation; flag the configuration step as a non-code follow-up.        |

## §8 Acceptance criteria for Workstream AR overall

AR is considered "complete" when:

  1. Every Major finding (M-1 through M-10) plus the two
     cross-verification additions has a landed work unit
     (or an explicit Wontfix rationale in §2.2).
  2. Every Minor finding (m-1 through m-19) has either:
     (a) a landed work unit, or
     (b) a documented Defer / Document-only triage
     decision in §2.3.
  3. The full CI gate set (§6.1) is green.
  4. The `kernelBuildTag` is bumped to
     `"canon-audit-remediation"`.
  5. `LegalKernel/Test/Umbrella.lean` pins the new tag.
  6. `docs/audits/00-comprehensive-lean-audit-index.md` and
     `docs/audits/19-findings-and-followups.md` are
     annotated with the per-finding AR work-unit ID and the
     landing commit / PR.
  7. CLAUDE.md and AGENTS.md are byte-identical and reflect
     the post-AR test count / theorem catalogue.
  8. The Genesis Plan §15 status registry includes an "AR"
     entry naming Workstream AR as Complete.

## §9 Out-of-scope items (deferred to future workstreams)

The following are intentionally **not** scoped to AR.  They
appear here so future workstream planners have a single
record of the deferrals.

  * **M-4 (CBE per-instance type-tag prefix).**  Wontfix —
    documented design choice; see §2.2.

  * **m-16 (chain-level bridge supply accounting
    theorems).**  Defer to Workstream G (Ethereum
    documentation + amendment).  The per-step deltas and the
    cross-stack corpus already ratify the property; the
    inductive Lean theorem is a documentation-quality
    improvement, not a soundness gap.

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

Before landing, the plan was cross-checked by an independent
verification pass.  The pass reviewed:

  * **Finding coverage.**  Every finding in
    `docs/audits/19-findings-and-followups.md` (M-1…M-10,
    m-1…m-19, i-1…i-11) has a triage decision in §2 and, for
    Remediate decisions, a citing work unit in §4.  Zero
    findings are missing; zero are incorrectly triaged
    (M-4's Wontfix and m-16's Defer are justified in §2.2,
    §2.6, and §9).

  * **File / line references.**  Every concrete code citation
    in the plan (file paths, line numbers, theorem names,
    function names, structure fields) was verified against
    source on the audit-snapshot branch.  All citations land
    within 0–3 lines of the cited content.  Spot-check
    coverage: ~30 distinct file:line references.

  * **Theorem references.**  Every named theorem the plan
    relies on (the five
    `commit*_bytes_injective_under_collision_free` lemmas,
    `commitExtendedState_subcommits_bytes_eq_under_collision_free`,
    `Action.tag_matches_encode_tag`, `action_encode_injective`,
    the `*_encode_deterministic` family, `TreeMap.equiv_iff_toList_eq`,
    `nat_roundtrip`, `byteArray_roundtrip`, etc.) was located
    at its cited file:line.  Zero broken references.

  * **AR.4 math precision.**  The original draft's
    pseudo-decoder used direct `cborHeadDecode` chaining; the
    actual source delegates to generic helpers
    (`encodeSortedPairs`, `decodeMap`) at lines 107–176 of
    `Encoding/State.lean`.  AR.4's proof outline was
    rewritten to (a) match the actual decoder API, (b)
    introduce the two-layer round-trip (helper + per-type),
    and (c) be honest that the lift is to *extensional*
    equality (`Equiv` / `toList = toList`), not Lean `=`.
    The shipped pattern matches `action_encode_injective`
    (`Encoding/Action.lean:818-827`).

  * **AR.4 `fieldsBounded` predicate.**  Since
    `ActorId = UInt64` and `ResourceId = UInt64`
    (`Kernel.lean:51-54`), keys are bounded by their type
    and need no explicit clause.  Only `Amount = Nat` (line
    59) requires `< 2^64`.  The original draft over-stated
    the predicate (key + value clauses); the verified form
    is value-only.

  * **AR.4 BridgeState field names.**  Verified at
    `Bridge/State.lean:169-173`: fields are `consumed :
    TreeMap DepositId DepositRecord compare` and `pending :
    TreeMap WithdrawalId PendingWithdrawal compare`
    (corrected from the draft's mistaken
    `depositRecords`/`pendingWithdrawals`).

  * **AR.6 Event constructor count.**  Verified by direct
    enumeration of `Events/Types.lean` lines 82–192: **16**
    constructors, indices 0–15 (corrected from the draft's
    mistaken count of 13).  The source also lacks a
    `def Event.tag` function (unlike `Action.tag` in
    `LocalPolicySemantics.lean:64`).  AR.6 therefore both
    introduces the function and pins each constructor's
    index.

  * **AR.8 second use-site.**  Verified by
    `grep federation_transfer_policy_v2 UsdClearing.lean`:
    sites at lines 111 (declaration) and 160 (deployment
    binding).  AR.8's rename step explicitly enumerates
    both.

  * **Dependency graph.**  Re-counted: four strict edges
    (AR.1→AR.2, AR.2→AR.3, AR.3→AR.23, Everything→AR.22)
    plus three soft edges (AR.5/AR.6→AR.2, AR.8→AR.2,
    AR.4/AR.10→AR.23).  The "seven strict edges" wording in
    the draft was reduced to "four strict + three soft".

  * **i-11 reward / stake economics.**  Augmented from
    Document-only to AR.13-with-guard-comments at four
    cited sites (`claimImpugnedAmount`,
    `proportionalChallengerReward`,
    `stakeWeightedAdjudicatorRewards`,
    `Staking.stakeResolutionActions`).

After applying the verification-pass corrections, the plan is
internally consistent, every concrete reference resolves to
source, and every work unit's math/proof outline matches the
actual decoder / encoder API.  Zero erroneous findings remain
in the §2 triage; zero stale references remain in the work
unit specifications.

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
  * `docs/ethereum_integration_plan.md` — Workstream A–G
    deliverables (AR.2's deploymentId parameterisation
    interacts with Workstream B / C call sites).
  * `docs/actor_scoped_policies_plan.md` — Workstream LP
    (AR.6's Event tag pins overlap with LP's event-extension
    surface).
  * `docs/lex_implementation_plan.md` — Workstream LX (AR.7,
    AR.11, AR.12 fold into LX tooling).
  * `docs/fault_proof_migration_plan.md` — Workstream H
    (AR.3 + AR.4 close the Workstream H follow-ups).
  * `docs/parameterized_laws_plan.md` — Workstream PA
    (parallel workstream; AR establishes the proof patterns
    that PA's encoder injectivity work will reuse).
  * `docs/std_dependencies.md` — Std-API surface used by the
    kernel (AR.4 relies on `TreeMap.equiv_iff_toList_eq` —
    catalogued there).
  * `docs/decidability_discipline.md` — `decPre` rule (AR
    introduces no new `decPre`).
  * `docs/abi.md` — on-disk frame format + CLI ABI (AR.2 +
    AR.3 update the CLI ABI in lockstep).


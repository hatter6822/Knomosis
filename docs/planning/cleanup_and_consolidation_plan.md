<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Cleanup and Consolidation — Engineering Plan

This document plans the cleanup of small-but-real deferred
items surfaced by the audit: documentation drift, stale code
comments, LP minor items, AR.18 visibility, AR.23 lift, and the
synthesis-doc refresh.  None of these is individually large
enough to merit its own workstream; collectively they form a
single tidy-up PR-sequence.

The cleanup is *non-load-bearing*: nothing in this document
blocks a production deployment.  But these items are technical
debt the project's discipline says to keep at zero.

## Status

  * **Workstream prefix:** `CL` (Cleanup).  Five sub-units
    (**all 5 complete**):
    - **CL.1** Documentation drift (README build tag,
      test-count consistency, synthesis-doc refresh).
      **— COMPLETE.**  README version matches
      `LegalKernel.lean` (`kernelVersion`, mirroring `lakefile.lean`);
      README uses a "run `lake test`" pointer rather than a pinned
      count; synthesis-doc post-AR refresh shipped (OQ-DOC-4).
    - **CL.2** Stale code comments (the historical-context
      cleanup catalogue).  **— COMPLETE.**  Of the 16 catalogued
      comments, 4 were already clean; the remaining 11 are
      rewritten to describe content + cross-reference the tracking
      registry (open-questions / workstream plans).  The
      TCB-adjacent `RBMapLemmas.lean` conditional design-note
      (item 16) is intentionally left as-is per its two-reviewer
      status — it is a design note, not debt.
    - **CL.3** AR.18 mechanical visibility (the `protected` lift
      for `applyVerdictUnchecked`).
      **— COMPLETE.**  `applyVerdictUnchecked` is now `protected`
      in `LegalKernel/Disputes/Verdict.lean`; every call site
      spells out `Disputes.applyVerdictUnchecked`.  Path A (move
      the reward composers into `Verdict.lean`) was rejected — it
      would invert the Verdict → Rewards layering; `protected`
      (Path B) is the clean form that preserves it.
    - **CL.4** AR.23 partial → complete (depends on EI.8).
      **— COMPLETE.**  `Test/Integration/SnapshotBootstrap.lean`
      now asserts extensional equality via the EI.8.b lemma
      `commitExtendedState_subcommits_extensional_eq_under_collision_free`.
    - **CL.5** LP minor / forward-roadmap items deferred
      enforcement (the §13.2 items not promoted to v2 roadmap).
      **— COMPLETE.**  OQ-LP-1 – OQ-LP-6 are registered in
      `docs/planning/open_questions.md`.
  * **Effort estimate:** 4–8 engineer-days total.  Each
    sub-unit is ≤ 1–2 days.
  * **Build-posture target:** all gates green.  CL is
    documentation + visibility tweaks; no theorem changes.
  * **TCB delta:** zero.  CL.3 (`applyVerdictUnchecked`)
    touches `LegalKernel/Disputes/Verdict.lean` which is
    non-TCB.
  * **Trust-assumption delta:** zero.

## Table of contents

  * §1 Goals and non-goals
  * §2 Sub-unit specifications (CL.1 – CL.5)
  * §3 Sequencing and PR structure
  * §4 Quality gates
  * §5 Risk register
  * §6 Acceptance criteria
  * §7 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Eliminate documentation drift.**  README build-tag
    matches `LegalKernel.lean:285`; CLAUDE.md and README test-
    count claims are coherent or marked explicitly as drifting;
    audit synthesis doc's "Open follow-ups" section reflects
    post-AR state.
  2. **Clean up stale code comments.**  Comments referencing
    "deferred to Phase 6" (where Phase 6 is now complete) and
    similar history-bound prose get rewritten to describe
    content, not provenance (per CLAUDE.md "Names describe
    content, never provenance" rule applied to comments).
  3. **Land AR.18 mechanical visibility** for
    `applyVerdictUnchecked` (the `private` / `protected` lift
    with cross-file caller relocation).
  4. **Land AR.23 partial → complete** post-EI.8 (lift
    `SnapshotBootstrap.lean:117` assertion from bytes-eq to
    extensional-eq).
  5. **Catalogue LP forward-roadmap items** into the master
    open-questions document so future workstream planners have
    a single point of reference.

### §1.2 Non-goals

  1. **No new theorems.**
  2. **No re-litigation of the AR triage.**  Items marked
    "Defer", "Document-only", or "Wontfix" in AR remain as
    triaged.
  3. **No new feature work.**

### §1.3 Reading guide

Cleanup PRs land independently; this document organises the
review surface.  Implementers may pick any sub-unit; reviewers
should still apply the standard checklist for each.

## §2 Sub-unit specifications

---

### CL.1 — Documentation drift cleanup

**Finding map.**  Audit §10 "Documentation drift".

**Scope.**  `README.md`, `CLAUDE.md`,
`docs/audits/19-findings-and-followups.md`.

**Implementation steps.**

  1. **README build tag.**  Edit `README.md:64` from
    `knomosis-fault-proof-migration` to whatever
    `LegalKernel.lean:285`'s `kernelBuildTag` currently reads
    (`knomosis-audit-remediation` as of audit date).  This is a
    one-line edit.
  2. **README test count.**  Either update `README.md:65`
    "~1 835" to match CLAUDE.md's "~1907" (the canonical
    number), or strike both numbers in favour of a "run
    `lake test` for the current count" pointer.  Recommend the
    latter: test count is not pinned by design (CLAUDE.md
    "Current development status"), so prose claims will always
    drift.
  3. **Audit synthesis doc refresh.**  Edit
    `docs/audits/19-findings-and-followups.md:630` "Open
    follow-ups" section to add a header line "As of audit
    date; the AR workstream has since closed M-1, M-2, M-5
    – M-10; only M-3 (encoder injectivity) remains open at
    this writing" — or strike the closed items individually.
    Recommend striking individually with footnote linking to
    `audit_remediation_plan.md` §15C.2 for current status.
  4. Audit `docs/audits/00-comprehensive-lean-audit-index.md`
    for any other stale claims; refresh.
  5. (Optional, low priority) Audit other docs/ files for
    "as-of-audit" prose using `grep -nE 'as of [A-Z][a-z]+'
    docs/`.

**Acceptance criteria.**

  * `grep -n kernelBuildTag README.md` matches
    `LegalKernel.lean:285`.
  * `grep "M-1\|M-2\|M-3\|M-5\|M-6\|M-7\|M-8\|M-9\|M-10" docs/audits/19-findings-and-followups.md`
    surfaces only entries that reference current state, not
    open-status-as-of-audit.
  * No PR adds a new "as of <date>" line without an explicit
    "AR-status-update" cross-reference.

**Test plan.**

  * Documentation-only: visual review.

**DoD.**

  * [ ] README build tag updated.
  * [ ] README test count updated or replaced with pointer.
  * [ ] Synthesis doc "Open follow-ups" annotated or refreshed.

**Verification.**

```bash
grep kernelBuildTag README.md LegalKernel.lean  # values match
```

**Reviewer checklist.**

  * No content removed without a forwarding cross-reference.
  * No process tokens (PR numbers, session URLs, branch names)
    added.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

---

### CL.2 — Stale code comments

**Finding map.**  Audit §9 "Cosmetic / test-only" code-level
deferral markers.

**Scope.**  ~10 `.lean` files; targeted edits only.

**Implementation steps.**

For each of the following comment locations, rewrite or remove
the historical-context prose per CLAUDE.md's "Names describe
content, never provenance" rule (which applies to comments
as well as identifiers in spirit):

  1. **`LegalKernel/Events/Types.lean:34`** — currently:
    "disputeFiled and verdictApplied constructors are
    deferred to Phase 6".  Phase 6 is complete; rewrite to
    "disputeFiled and verdictApplied constructors are
    extracted by the dispute pipeline (§8.9.2)".
  2. **`LegalKernel/Test/DSL/Law.lean:24`** — currently:
    "deprecation cleanup is explicitly deferred".  Refers to
    `Law.mk` deprecation (still open per AR triage).  Update
    the comment to cite the open-questions doc:
    "[Law.mk deprecation cleanup is open — see
    `docs/planning/open_questions.md` for status]".
  3. **`Lex/Test/ExampleLex.lean:23`** — similar legacy-DSL
    deprecation; same treatment.
  4. **`Lex/Examples/ExampleLex.lean:81`** — currently:
    "<law>_identifier, <law>_version are deferred to Pass 2".
    If Pass 2 is M3 (now complete), update to describe the
    current shipped state.  Otherwise (if Pass 2 is a future
    pass), add a cross-reference to the relevant open-questions
    entry.
  5. **`LegalKernel/Bridge/State.lean:122`** — "ByteArray swap
    is a follow-up requiring refactoring".  Add a cross-
    reference to either CA or a new open-questions entry.
  6. **`LegalKernel/Bridge/WithdrawalRoot.lean:1003`** — "leaf-
    recovery lemma scoped as a follow-up".  Cross-reference EI
    if related to encoder injectivity; otherwise an open-
    questions entry.
  7. **`Lex/DSL/Shim.lean:90`** — "is a follow-up workstream".
    Cross-reference the relevant Lex roadmap or open-questions.
  8. **`LegalKernel/Disputes/Staking.lean:150`** — "semantics,
    a follow-up workstream".  Cross-reference the open-
    questions entry (PA-adjacent — staking economics).
  9. **`LegalKernel/Test/Bridge/WithdrawalProofCLI.lean:36`** —
    "Std.Process integration is Phase-5 follow-up".  Phase 5
    Lean-side is complete; Rust integration is RH-G or RH-C.
    Cross-reference `rust_host_runtime_plan.md`.
  10. **`LegalKernel/Test/Bridge/CrossCheck/Goldens.lean:21`** —
     "upgrading to real mainnet corpus is the follow-up".
     Cross-reference SC.3 (cross-stack corpus extension) or a
     dedicated open-questions entry.
  11. **`LegalKernel/Authority/LocalPolicy.lean:139`** —
     "variant (deferred)".  Cross-reference the LP open-
     questions entry (LP.2.1 `expireAtNonce` or LP.2.2
     `anyOf`).
  12. **`LegalKernel/FaultProof/Cell.lean:52`** — "Solidity-side
     SMT form documented as a follow-up integration".  Cross-
     reference `smt_cell_proofs_plan.md`.
  13. **`LegalKernel/FaultProof/KeyDerivation.lean:127`** —
     "full structural injectivity theorem (via
     `Nat.eq_of_testBit_eq`) is deferred as a follow-up".
     Cross-reference EI or open-questions for the bitvector
     theorem.
  14. **`LegalKernel/Encoding/State.lean:62`** — "full abstract
     round-trip theorem is deferred to a follow-up".  Cross-
     reference EI.
  15. **`LegalKernel/Disputes/Rewards.lean:726`** — "inductive
     lemma over the `filterMap` body; deferred to a future
     workstream (a 'PA-tier' follow-up)".  Cross-reference PA
     landing plan or open-questions.
  16. **`LegalKernel/RBMapLemmas.lean:41`** — "treatment of
     arbitrary commutative monoids is deferred until a
     non-Nat quantity functional first appears".  This is a
     conditional design note, not a debt; leave as-is or
     rewrite to make the condition explicit.  Recommend:
     "Only Nat carriers are mechanised today; widening to
     commutative monoids is added when the first non-Nat
     quantity ships."  (Note: this is a TCB-adjacent file;
     **two-reviewer rule** applies even for a comment change.)

**Acceptance criteria.**

  * Each comment edit either describes current content or
    cross-references a tracking document (open-questions or a
    workstream plan).
  * No comment retained the "as of phase / WU / audit" form
    without a forwarding pointer.
  * `lake exe deferral_audit` passes (since most of these
    comments use words like "deferred" but not the
    audit's forbidden phrases, they pass today — but the
    refactor should not introduce a new forbidden phrase
    inadvertently).

**Test plan.**

  * `lake build` succeeds (comment-only changes).
  * `lake exe deferral_audit` passes.
  * `lake exe naming_audit` passes.

**DoD.**

  * [ ] All 16 comments edited.
  * [ ] If `RBMapLemmas.lean` touched, two reviewers signed
    off (CL.2 may land as multiple PRs if reviewer load is a
    concern).
  * [ ] No new forbidden phrases.

**Verification.**

```bash
lake build
lake exe deferral_audit
lake exe naming_audit
```

**Reviewer checklist.**

  * Each comment describes content, not provenance.
  * Cross-references resolve (file paths and section
    identifiers correct).
  * `RBMapLemmas.lean` change has two reviewers.

**Risk.**  Low.

**Effort.**  ~2 engineer-days (split across reviewer-load-
appropriate PRs).

---

### CL.3 — AR.18 mechanical visibility for `applyVerdictUnchecked`

**Finding map.**  AR.18 (deferred per GENESIS_PLAN §15C.6).

**Scope.**  `LegalKernel/Disputes/Verdict.lean`,
`LegalKernel/Disputes/Rewards.lean`.

**Background.**  `applyVerdictUnchecked` is intentionally
unexported via docstring contract ("UNCHECKED — TESTING ONLY")
but is not lexically gated.  AR.18 deferred the mechanical
fix because Lean 4's `private` is file-local and the
legitimate cross-file callers
(`Rewards.applyVerdictWithRewardsUnchecked`,
`Rewards.applyVerdictWithRewardsMultiUnchecked`) live in a
different file.

Two solution paths:
  - **Path A (move callers).**  Relocate the two Rewards
    callers into `Verdict.lean`; mark `applyVerdictUnchecked`
    `private`.
  - **Path B (protected + namespace discipline).**  Mark
    `applyVerdictUnchecked` `protected`; update ~20 in-file
    references and the 4 cross-file references with full
    namespace qualification.

**Landed: Path B** (`protected`).  Path A was rejected: moving the
reward composers into `Verdict.lean` would invert the clean
Verdict → Rewards layering (`Rewards.lean` composes reward issuance
*on top of* the verdict core and imports `Verdict.lean`).  Path B's
qualification churn (~20 in-file + the cross-file references) is the
acceptable cost of the strongest visibility that preserves the
layering.

**Implementation steps (Path A).**

  1. Move `applyVerdictWithRewardsUnchecked` and
    `applyVerdictWithRewardsMultiUnchecked` from
    `Disputes/Rewards.lean` into `Disputes/Verdict.lean`.
  2. Update `Rewards.lean` callers to invoke the new
    in-`Verdict.lean` symbols.
  3. Mark `applyVerdictUnchecked` `private`.
  4. Verify the test-file callers (`LegalKernel/Test/Disputes/*.lean`)
    still build; they should because they are in different
    namespaces and Lean's `private` is file-local.
  5. Update `Verdict.lean` docstring to record the visibility
    enforcement: "AR.18: `applyVerdictUnchecked` is `private`
    to this file; legitimate callers live within the same
    file (see `applyVerdictWithRewardsUnchecked`)".
  6. Update GENESIS_PLAN §15C.6 from "AR.18 mechanical
    visibility (deferred)" to "AR.18 mechanical visibility
    (complete; landed under CL.3)".

**Acceptance criteria.**

  * `applyVerdictUnchecked` is `protected` (the bare short name
    no longer resolves; callers qualify as
    `Disputes.applyVerdictUnchecked`).
  * `lake build` succeeds.
  * `lake test` passes.
  * GENESIS_PLAN §15C.6 retired.
  * AR.18 status in `audit_remediation_plan.md` §15C.2 moves
    from "Document-only (mechanical `private` deferred — see
    below)" to "Complete".

**Test plan.**

  * `lake build` succeeds.
  * Existing test suite still passes.

**DoD.**

  * [ ] `applyVerdictUnchecked` private.
  * [ ] Callers relocated.
  * [ ] Docstring updated.
  * [ ] GENESIS_PLAN §15C.6 updated.
  * [ ] AR plan status table updated.

**Verification.**

```bash
lake build LegalKernel.Disputes.Verdict
lake build LegalKernel.Disputes.Rewards
lake test
```

**Reviewer checklist.**

  * No call sites broken.
  * Docstring contract preserved.

**Risk.**  Low-medium.  The move-callers operation has many
small touches.

**Effort.**  ~1 engineer-day.

---

### CL.4 — AR.23 partial → complete (post-EI.8)

**Finding map.**  AR.23 (Partial per GENESIS_PLAN §15C.2).

**Scope.**  `LegalKernel/Test/Integration/SnapshotBootstrap.lean`.

**Background.**  AR.23 is the end-to-end cross-deployment-
replay regression suite.  Its strongest-form final-state
assertion requires extensional-equality lift over map-backed
sub-states (the EI workstream's deliverable).  Until EI ships,
AR.23 asserts bytes-equality only.

**Implementation steps.**

  1. **Precondition:** EI.8 has landed.
  2. Edit `Test/Integration/SnapshotBootstrap.lean:117`:
     replace the bytes-eq assertion with the new
     extensional-eq assertion using
     `commitExtendedState_subcommits_extensional_eq_under_collision_free`.
  3. Remove the comment "requires the AR.4.8 extensional-
     equality lemma (deferred)".
  4. Update `audit_remediation_plan.md` §15C.2 row AR.23 from
     "Partial — depends on AR.4.8 for strongest form" to
     "Complete".

**Acceptance criteria.**

  * Test passes with the stronger assertion.
  * AR.23 status moves to "Complete".

**Test plan.**

  * `lake test` passes (existing infrastructure).

**DoD.**

  * [ ] Test lifted.
  * [ ] AR plan updated.
  * [ ] No remaining "deferred" comment in
    `SnapshotBootstrap.lean`.

**Risk.**  None (additive strengthening).

**Effort.**  ~0.5 engineer-day.

---

### CL.5 — LP forward-roadmap registry in open-questions doc

**Finding map.**  `docs/planning/actor_scoped_policies_plan.md` §13.2.

**Scope.**  `docs/planning/open_questions.md`.

**Background.**  LP shipped Lean-side complete but the §13.2
"Open questions / future work" list has not been incorporated
into a master roadmap doc.  CL.5 registers each LP forward item
in `open_questions.md`.

**Implementation steps.**

  1. In `docs/planning/open_questions.md` "LP — Actor-Scoped Policies"
    section, list:
     - LP.2.1 `expireAtNonce` clause.
     - LP.2.2 Disjunction of clauses (`anyOf`).
     - LP.2.3 Cross-actor policies (explicitly out-of-scope;
       different concern).
     - LP.2.4 Policy versioning.
     - LP.2.5 Policy commitments / hashes.
     - LP.13 Solidity-side mirror (future Workstream E
       follow-up).
  2. Each entry: one-line description + status + cross-
    reference to `actor_scoped_policies_plan.md` for design
    detail.

**Acceptance criteria.**

  * Six LP entries land in open-questions doc.
  * Each has a `actor_scoped_policies_plan.md` cross-reference.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

---

## §3 Sequencing and PR structure

```
PR-1: CL.1 (documentation drift)         — 0.5d
PR-2: CL.5 (LP roadmap registry)         — 0.5d
PR-3: CL.3 (AR.18 visibility)            — 1d
PR-4: CL.2 (stale comments, 1–2 PRs)     — 2d total
PR-5: CL.4 (AR.23 lift, post-EI.8)       — 0.5d  (gated on EI completion)
```

PR-1, PR-2, PR-3, PR-4 are parallelisable.  PR-5 lands after EI.

## §4 Quality gates

  * `lake build`, `lake test`
  * `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit`, `lake exe naming_audit`,
    `lake exe deferral_audit`, `lake exe lex_lint`,
    `lake exe lex_codegen --check`
  * CL.2 if it touches `RBMapLemmas.lean`: two-reviewer gate.

## §5 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| CL.2 comment edit introduces a new `deferral_audit` forbidden phrase | Low | Low | Run `lake exe deferral_audit` in each CL.2 PR |
| CL.3 reveals a hidden caller of `applyVerdictUnchecked` not anticipated | Medium | Low | Lean's `private` error message is precise; fix surfaces immediately |
| CL.1 README update collides with concurrent EI build-tag bump | Medium | Low | Coordinate: CL.1 ships first; EI.8's build-tag bump updates README again in its own PR |

## §6 Acceptance criteria

CL is **complete** when:

  1. README build tag matches `LegalKernel.lean:285`.
  2. Audit synthesis doc reflects post-AR state.
  3. 16 stale-comment edits land.
  4. `applyVerdictUnchecked` is `protected` (every call site
    qualified as `Disputes.applyVerdictUnchecked`).
  5. AR.23 is "Complete" status post-EI.8.
  6. LP open questions registered in `open_questions.md`.
  7. GENESIS_PLAN §15C.6 (AR.18 deferred) retired.
  8. `audit_remediation_plan.md` §15C.2 status table updated
    (AR.18 → Complete, AR.23 → Complete).

## §7 References

  * `docs/planning/audit_remediation_plan.md` §15C.6, §15C.2.
  * `docs/GENESIS_PLAN.md` §15C.6.
  * `docs/audits/19-findings-and-followups.md` "Open follow-
    ups".
  * `CLAUDE.md` "Names describe content, never provenance"
    rule (applied to comments by extension).
  * `docs/planning/encoder_injectivity_plan.md` — CL.4 dependency.

---

**End of plan.**  CL is the project's "tidy-up" PR sequence.
Landing each PR cleanly tightens project discipline without
affecting any soundness property.

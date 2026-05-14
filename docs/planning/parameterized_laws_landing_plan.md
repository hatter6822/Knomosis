<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Parameterized Laws (PA) — Landing Plan

This document plans the landing of Workstream PA (Parameterized
Laws), whose specification is already drafted in
`docs/planning/parameterized_laws_plan.md` but has not landed in the
canonical phase-status table.  PA introduces deployment-tunable
parameters (transfer caps, mint quorums, withdrawal windows,
etc.) governed by an on-chain `governance` actor set, while
keeping all proven invariants intact.

This is the "finish the drafted workstream" plan: it does not
re-do PA's design work; it organises the implementation,
review, and landing.

## Status

  * **Drafted on:** branch `claude/add-law-voting-0jBAh` (per
    audit, drafted but not landed in main).
  * **Workstream prefix:** `PA` (Parameters).  Adopts the
    existing `parameterized_laws_plan.md` work-unit
    decomposition: PA.1 through PA.12 (the drafted plan's
    enumeration).  Confirm and adopt by reading the drafted
    plan §3 work-unit specifications.
  * **Effort estimate:** 6–10 calendar weeks for one full-time
    Lean engineer.  The drafted plan estimates per-WU effort;
    sum here is conservative (~30 engineer-days).
  * **Build-posture target:** all existing CI gates green;
    new `Parameters` substrate adds an `ExtendedState` field
    plus an `Action.setParameters` constructor (which freezes
    its index per the AR.5 regression pattern).
  * **TCB delta:** zero.  Parameters substrate lives in
    `LegalKernel/Parameters/` (new non-TCB sub-tree).
  * **Trust-assumption delta:** zero.  Parameter governance
    uses the existing `Verify` opaque.

## Table of contents

  * §1 Goals and non-goals
  * §2 Background
  * §3 Work-unit landing strategy
  * §4 Per-WU landing checklist (PA.1 – PA.12)
  * §5 Sequencing and PR structure
  * §6 Quality gates
  * §7 Risk register
  * §8 Acceptance criteria
  * §9 Out-of-scope items (the §14.2 deferrals stay deferred)
  * §10 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Land PA in main.**  Every PA WU spec'd in
    `parameterized_laws_plan.md` ships behind the existing CI
    gates, with two reviewers for any kernel-touching change
    (none expected for PA per the drafted plan's TCB-delta-zero
    posture).
  2. **Reserve `Action` / `Event` indices.**  PA adds at least
    `Action.setParameters` and `Event.parametersChanged`.  The
    AR.5 / AR.6 regression suites must extend in the same PR
    that introduces each constructor.
  3. **Ship the parameter-monotonicity firewall.**  PA's
    headline type-level guarantee:
    `ParameterMonotonicLawSet` — any law set declared
    parameter-monotonic mechanically rejects laws whose
    behaviour depends adversarially on a parameter change.
  4. **Update the project status surface.**  Add `PA` row to
    CLAUDE.md and README's phase-status tables.

### §1.2 Non-goals

  1. **No re-design.**  The drafted plan is the contract.
    Implementation deviations require updating the drafted plan
    in the same PR.
  2. **No §14.2 deferrals.**  The drafted plan's "Open
    questions / future work" remain deferred (stake-weighted
    voting, two-stage propose-then-apply, delta-style updates,
    timelock activation, per-resource caps, governance-actor
    LP interaction, dispute-pipeline interaction, fork
    parameter migration).  These are listed in the project's
    `open_questions.md` for future design decisions.
  3. **No Solidity mirror.**  Solidity-side governance is
    Workstream E-future; PA is Lean-only.
  4. **No retroactive law parameterisation.**  Existing laws
    stay un-parameterised; PA adds the parameter substrate
    *alongside* them.  A future workstream may parameterise
    `transfer` etc., but not under PA.

### §1.3 Reading guide

  * Read `docs/planning/parameterized_laws_plan.md` first (the drafted
    plan).
  * This document supplements with landing-specific
    sequencing, CI gate alignment with the AR remediation
    pass's standards, and post-landing status updates.

### §1.4 Glossary

  * **Parameter substrate.**  The `ExtendedState.parameters`
    field holding deployment-tunable values.
  * **Parameter-monotonic.**  A law whose behaviour respects
    the partial order on parameter changes (e.g. a cap that
    can only loosen, not tighten retroactively).
  * **Governance signer set.**  The actors whose threshold
    signatures may issue `Action.setParameters`.

## §2 Background

`docs/planning/parameterized_laws_plan.md` (drafted, ~3000 lines)
specifies:

  * **§3 Parameter substrate** — `ExtendedState.parameters`
    field; CBE encoding; deployment-genesis initialisation.
  * **§4 Governance** — `governanceSigners` set;
    `setParameters` action with multi-signature precondition.
  * **§5 Per-law parameter consumption** — read access via
    `s.parameters.X`; no write access from non-governance
    laws.
  * **§6 Monotonicity discipline** — `IsParameterMonotonic`
    typeclass + `ParameterMonotonicLawSet` firewall.
  * **§7 Event surface** — `Event.parametersChanged`.
  * **§8 Disputes integration** — verdicts may reference
    parameters in scope at filing time.
  * **§9 Lex-DSL surface** — `parameters { … }` clause in
    `lexlaw` macros.
  * **§10 Test plan** — value- and term-level coverage.
  * **§14.2 Open questions** — deferred items (see §9 below
    and `open_questions.md`).

PA Landing's job is to take that drafted plan, implement it,
test it, and ship.

## §3 Work-unit landing strategy

The drafted plan has 12 WUs (PA.1 – PA.12 per the drafted plan
numbering).  Recommended landing order, with two clusters:

```
Cluster A — substrate first (lands fully before B starts):
  PA.1 (Parameters type)
  PA.2 (ExtendedState extension)
  PA.3 (CBE encoding)
  PA.4 (Genesis initialisation)

Cluster B — governance and laws (parallelisable internally):
  PA.5 (governanceSigners + setParameters action)
  PA.6 (action admissibility + nonce integration)
  PA.7 (event emission)
  PA.8 (monotonicity typeclass)
  PA.9 (firewall law set)
  PA.10 (parameter consumption examples)

Cluster C — DSL and tests (final):
  PA.11 (Lex parameters clause)
  PA.12 (end-to-end regression suite)
```

Cluster A is the foundation: every other WU depends on the
parameters substrate.  Cluster B may parallelise across two
contributors after PA.5 lands.  Cluster C is integration.

## §4 Per-WU landing checklist

For each PA.k, the landing PR must:

  - [ ] Implement the spec from
    `docs/planning/parameterized_laws_plan.md` §3.<k> verbatim
    (deviations require updating the drafted plan).
  - [ ] Pass `lake build`, `lake test`, and all audit binaries.
  - [ ] Include term-level API-stability tests for every new
    theorem.
  - [ ] If introducing an `Action` or `Event` constructor,
    extend `Authority/Action.lean` + `Encoding/Action.lean` +
    AR.5 (Action.tag) regression test + AR.6 (Event.tag)
    regression test in the same PR.
  - [ ] If introducing a new `LocalPolicyClause` variant,
    extend `Authority/LocalPolicy.lean` + LP regression tests.
  - [ ] Update `docs/planning/parameterized_laws_plan.md` "Status"
    section to mark the WU "complete".
  - [ ] One reviewer (per CLAUDE.md "law modules require one
    reviewer").

Specific WU sketches (consult drafted plan for full
specifications):

### PA.1 — `Parameters` substrate type

**Scope.**  `LegalKernel/Parameters/Types.lean` (new).

**Sub-sub-units.**

  * **PA.1.a** — `Parameters` structure definition.
    Field set: `transferCap : Option Amount`, `mintQuorum :
    Nat`, `withdrawalWindow : Nat`,
    `governanceSigners : List ActorId`,
    `governanceThreshold : Nat`, plus a `deploymentExt : ByteArray`
    extension hook for deployment-specific opaque fields.
  * **PA.1.b** — `Inhabited Parameters` with documented
    safe defaults (no transfer cap; quorum = 1; window =
    256 blocks; empty governance set).
  * **PA.1.c** — `DecidableEq Parameters` derived instance.
  * **PA.1.d** — `Parameters.le` partial order.  Required
    by PA.8's monotonicity machinery: `p₁ ≤ p₂` iff all
    caps in `p₂` are at least as permissive as in `p₁`
    (e.g. `p₁.transferCap` is `none` or `p₁.cap ≤ p₂.cap`).

**Effort.**  ~1 engineer-day.

### PA.2 — `ExtendedState.parameters` field

**Scope.**  `LegalKernel/Kernel.lean` (TCB-tier — **two-
reviewer** rule!), `LegalKernel/Runtime/`,
`LegalKernel/Test/`.

**Sub-sub-units.**

  * **PA.2.a** — Add `parameters : Parameters` field to
    `ExtendedState`.  This is a TCB touch; two reviewers
    required.
  * **PA.2.b** — Update every `ExtendedState.mk` constructor
    call site in source and tests.
  * **PA.2.c** — Update every destructuring pattern match
    (use `Std.TreeMap` plus the new field).
  * **PA.2.d** — Provide `ExtendedState.empty` initialiser
    with `parameters := default`.

**Effort.**  ~2 engineer-days (the constructor / destructure
sweep is the bulk).

### PA.3 — CBE encoding

**Scope.**  `LegalKernel/Encoding/Parameters.lean` (new).

**Sub-sub-units.**

  * **PA.3.a** — `Encodable Parameters` instance with
    deterministic field order.
  * **PA.3.b** — `parameters_encode_deterministic` lemma.
  * **PA.3.c** — `parameters_roundtrip` lemma.
  * **PA.3.d** — `parameters_encode_injective` —
    follows the EI workstream's template (see
    `docs/planning/encoder_injectivity_plan.md` §2.4 "proof recipe").
    `Parameters` is a flat structure (not map-backed) so the
    proof is simpler than EI.2 – EI.7: discharge each field's
    atomic encoder injectivity, then conclude structurally.
    If EI has not landed when PA.3 lands, the proof still
    stands (it does not consume EI's helper lemmas; the
    template is the *shape*, not a dependency).
  * **PA.3.e** — Round-trip integration with
    `ExtendedState.encode`: extend the existing top-level
    encoder to include the new `parameters` field.  TCB
    touch (encoding wire-format change); **two-reviewer**.

**Effort.**  ~3 engineer-days.

### PA.4 — Genesis initialisation

**Scope.**  `LegalKernel/Runtime/Loop.lean`,
`LegalKernel/Runtime/Bootstrap.lean`, `Main.lean`.

**Sub-sub-units.**

  * **PA.4.a** — Add `Parameters` to the bootstrap config
    record (`BootstrapConfig`).
  * **PA.4.b** — Update `bootstrap` to thread `parameters`
    into `ExtendedState.empty`.
  * **PA.4.c** — CLI flag: `--initial-parameters <hex>` on
    `canon`; parse via CBE.
  * **PA.4.d** — Add a default-parameters genesis path: if
    `--initial-parameters` is absent, use `Inhabited.default`.
    Document the deployment hazard (empty governance set
    means no parameter changes possible).

**Effort.**  ~1.5 engineer-days.

### PA.5 — `governanceSigners` + `setParameters` action

**Scope.**  `LegalKernel/Authority/Action.lean` (TCB-adjacent
— two-reviewer; this adds an `Action` constructor),
`LegalKernel/Laws/SetParameters.lean` (new).

**Sub-sub-units.**

  * **PA.5.a** — Reserve next free `Action` constructor
    index in `Lex.IndexRegistry.txt`.
  * **PA.5.b** — Add `Action.setParameters (newParams :
    Parameters) (signers : List ActorId) (sigs : List Signature)`.
  * **PA.5.c** — Extend AR.5 regression test with the new
    constructor's pinned index.
  * **PA.5.d** — Define `setParameters.law` in
    `Laws/SetParameters.lean`.  Precondition: signer set
    must be a subset of `s.parameters.governanceSigners`,
    each signature valid, threshold-many distinct signers.
  * **PA.5.e** — `setParameters.apply`: replace
    `s.parameters` with `newParams`; bump each signer's nonce.

**Effort.**  ~2 engineer-days.

### PA.6 — Admissibility + nonce integration

**Scope.**  `LegalKernel/Authority/SignedAction.lean`,
`LegalKernel/Authority/Nonce.lean`.

**Sub-sub-units.**

  * **PA.6.a** — Threshold-signed action support: extend the
    existing single-signer admissibility predicate to handle
    the multi-signer case.  Each signer's per-actor nonce
    bumps on success.
  * **PA.6.b** — `setParameters_admissible_iff_quorum_met`
    headline theorem.
  * **PA.6.c** — Cross-stack: `setParameters_replay_impossible`
    extension of the existing replay-impossible theorem.

**Effort.**  ~2 engineer-days.

### PA.7 — `Event.parametersChanged`

**Scope.**  `LegalKernel/Events/Types.lean`,
`LegalKernel/Events/Extract.lean`.

**Sub-sub-units.**

  * **PA.7.a** — Reserve next free `Event` constructor index.
  * **PA.7.b** — Add `Event.parametersChanged (oldParams :
    Parameters) (newParams : Parameters) (signers : List
    ActorId)`.
  * **PA.7.c** — Update `Events.extractEvents` to emit on
    `Action.setParameters` admission.
  * **PA.7.d** — Extend AR.6 regression test.

**Effort.**  ~1 engineer-day.

### PA.8 — `IsParameterMonotonic` typeclass

**Scope.**  `LegalKernel/Parameters/Monotonicity.lean` (new).

**Sub-sub-units.**

  * **PA.8.a** — Define `IsParameterMonotonic` typeclass:
    ```lean
    class IsParameterMonotonic (t : Transition) : Prop where
      mono : ∀ s s', s.parameters ≤ s'.parameters →
                     t.pre s → t.pre s'
    ```
    where `≤` is `Parameters.le` from PA.1.d.
  * **PA.8.b** — Witness instance for `transfer` (vacuously
    monotonic; doesn't consume parameters).
  * **PA.8.c** — Witness instance for `parameterizedTransfer`
    (PA.10).
  * **PA.8.d** — Witness instances for every existing
    kernel law that does not consume parameters (vacuous;
    bulk).
  * **PA.8.e** — Negative witnesses for any law that
    *cannot* be parameter-monotonic — ship explicit
    `instance : ¬ IsParameterMonotonic …` to make the
    firewall sound by exhibiting counterexamples.

**Effort.**  ~2 engineer-days.

### PA.9 — `ParameterMonotonicLawSet` firewall

**Scope.**  `LegalKernel/Parameters/Monotonicity.lean`.

**Sub-sub-units.**

  * **PA.9.a** — `def ParameterMonotonicLawSet : List
    Transition → Prop := fun ls => ∀ t ∈ ls,
    IsParameterMonotonic t`.
  * **PA.9.b** — `parameter_monotonic_law_set_preserves_admissibility`
    headline theorem: if the law set is
    `ParameterMonotonicLawSet`, increasing parameters
    cannot turn a previously-admissible action inadmissible.
  * **PA.9.c** — Type-level firewall demonstration: an
    example deployment that tries to include a non-monotonic
    law fails elaboration.

**Effort.**  ~1.5 engineer-days.

### PA.10 — Parameter consumption: example laws

**Scope.**  `LegalKernel/Laws/ParameterizedTransfer.lean`
(new).

**Sub-sub-units.**

  * **PA.10.a** — Define `parameterizedTransfer.law` with
    precondition that reads `s.parameters.transferCap`:
    ```lean
    pre := fun s =>
      transfer.pre s ∧
      (match s.parameters.transferCap with
       | none      => True
       | some cap  => transfer.amount ≤ cap)
    ```
  * **PA.10.b** — Reserve `Action.parameterizedTransfer`
    constructor index.
  * **PA.10.c** — `IsParameterMonotonic
    parameterizedTransfer.toTransition` proof.
  * **PA.10.d** — Test fixtures.

**Effort.**  ~1.5 engineer-days.

### PA.11 — Lex `parameters` clause

**Scope.**  `Lex/DSL/Law.lean`, `Lex/DSL/Parameters.lean`
(new).

**Sub-sub-units.**

  * **PA.11.a** — Parse `parameters { transferCap : Option
    Amount, mintQuorum : Nat, ... }` block in `lex_law`.
  * **PA.11.b** — Synthesize `s.parameters.X` reads inside
    law bodies that mention the parameter names.
  * **PA.11.c** — Generate `IsParameterMonotonic` instance
    when the law's pre is monotonic (best-effort; complex
    cases default to manual proof).
  * **PA.11.d** — Test fixtures: re-express
    `parameterizedTransfer` in Lex; assert byte-equal to
    PA.10's hand-written form.

**Effort.**  ~3 engineer-days.

### PA.12 — End-to-end regression suite

**Scope.**  `LegalKernel/Test/Integration/Parameters.lean`
(new).

**Sub-sub-units.**

  * **PA.12.a** — Genesis-parameter test: bootstrap with
    explicit parameters; assert state.parameters matches.
  * **PA.12.b** — Apply action with parameter consumption:
    `parameterizedTransfer` under a cap; assert admission.
  * **PA.12.c** — Apply `setParameters`; assert
    `Event.parametersChanged` emitted; new parameters
    visible.
  * **PA.12.d** — Apply action that violates new cap;
    assert rejection.
  * **PA.12.e** — Replay determinism: rerun the entire
    chain; assert byte-equal commitment.

**Effort.**  ~2 engineer-days.

## §5 Sequencing and PR structure

```
Sprint 1 (week 1–2)            PA.1, PA.2, PA.3, PA.4 (Cluster A)
Sprint 2 (week 3–4)            PA.5, PA.6, PA.7
Sprint 3 (week 5)              PA.8, PA.9
Sprint 4 (week 6)              PA.10, PA.11
Sprint 5 (week 7)              PA.12 + status updates
```

Total: ~7 calendar weeks for one full-time engineer (10–14
calendar weeks if part-time or in parallel with other work).

## §6 Quality gates

Standard project gates:

  * `lake build`
  * `lake test`
  * `lake exe count_sorries`
  * `lake exe tcb_audit`
  * `lake exe stub_audit`
  * `lake exe naming_audit`
  * `lake exe deferral_audit`
  * `lake exe lex_lint`
  * `lake exe lex_codegen --check`

Plus PA-specific:

  * AR.5 / AR.6 regression tests extended for each new
    `Action` / `Event` constructor.
  * `#print axioms` on every new theorem reduces to a subset
    of the three Lean built-ins.

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `ExtendedState` extension breaks existing tests | High | Low | Add `parameters` field with `Inhabited` default; update test fixtures in PA.2 PR |
| New `Action` index collides with E-future reservation | Low | Medium | Audit `Action.lean` for reserved-but-unused indices before PA.5 |
| Monotonicity typeclass too restrictive (rejects sensible laws) | Medium | Medium | Provide an `IsParameterMonotonic.weaken` escape hatch with deployment-level justification |
| Lex `parameters` clause complexity creep | Medium | Low | Defer advanced features (typed-parameter wrappers) to LX v3 per existing roadmap |
| Drafted plan revisions during landing | High | Low | Land plan-revision PR before resuming WU PRs; never silently deviate |

## §8 Acceptance criteria

PA is **complete** when:

  1. All 12 PA WUs land.
  2. `lake build` and `lake test` green across the full
    project.
  3. Headline theorems shipped:
     - `parameters_roundtrip`
     - `parameters_encode_injective` (post-EI; otherwise
       parameters substate gets a future encoder-injectivity
       follow-up registered alongside EI)
     - `setParameters_admissible_iff_quorum_met`
     - `parameter_monotonic_law_set_preserves_admissibility`
  4. `Action.setParameters` and `Event.parametersChanged`
    indices reserved and frozen.
  5. CLAUDE.md status table adds "PA" row marked "Complete".
  6. README phase-table updated.
  7. `docs/planning/parameterized_laws_plan.md` "Status" section says
    "Landed in PR #..." with the merge SHA.
  8. `docs/planning/parameterized_laws_plan.md` §14.2 "Open questions"
    forwarded to `docs/planning/open_questions.md`.

## §9 Out-of-scope items (these stay deferred — see open_questions.md)

  * Stake-weighted / token-weighted quorum.
  * Two-stage propose-then-apply.
  * Delta-style parameter updates.
  * Effective-at-block timelock.
  * Per-resource parameter caps.
  * Governance-actor / LocalPolicy interaction enforcement.
  * Parameter migration across `CanonMigration` forks.
  * Solidity-side governance mirror.

Each is registered in `docs/planning/open_questions.md` under "PA forward
roadmap".

## §10 References

  * `docs/planning/parameterized_laws_plan.md` — the drafted spec.
  * `docs/planning/audit_remediation_plan.md` — AR.5 / AR.6 patterns.
  * `docs/planning/actor_scoped_policies_plan.md` — LP pattern for
    actor-scoped behavioural specs.
  * `docs/planning/lex_implementation_plan.md` — Lex macro extension
    pattern.

---

**End of plan.**  Landing PA closes the only "drafted but not
landed" workstream and adds parameter-tuning capability to
deployments while preserving every shipped invariant.

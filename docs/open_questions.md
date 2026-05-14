<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Open Questions — Master Design-Decision Registry

This document is the canonical registry of *open design
questions* for the Canon project: questions that have surfaced
during planning but for which a project-level decision has not
yet been made.  It is the single point of reference for future
workstream planners and for design-review discussions.

Each open question is presented with:
  - **Context** — where it arose, what's at stake.
  - **Options** — the alternatives identified.
  - **Trade-offs** — what each option costs / buys.
  - **Recommendation** — the project's current best guess
    (subject to discussion).
  - **Owner / status** — who's expected to drive the decision.

Open questions are **not** deferred work in the sense of
"someone will implement this later" — they are decisions
prerequisite to *deciding what to implement*.  Once a decision
is made, the relevant workstream plan absorbs the choice and
implementation proceeds.

## Table of contents

  * §1 How to use this document
    * §1.1 Urgency matrix
    * §1.2 Decision-dependency graph
    * §1.3 Summary table (all questions, one row each)
  * §2 Cross-cutting / architectural questions
  * §3 PA (Parameterized Laws) — forward-roadmap questions
  * §4 LP (Actor-Scoped Policies) — open questions
  * §5 LX (Lex language) — v2 / v3 design questions
  * §6 Workstream H (Fault-Proof) — open questions
  * §7 Phase 7 — portfolio prioritisation questions
  * §8 Documentation / process questions
  * §9 Sub-workstream-surfaced questions (post-expansion)
  * §10 Resolved questions (historical record)
  * §11 References

## §1 How to use this document

  * **For workstream planners.**  Read the relevant section
    (PA, LP, LX, etc.) before writing implementation details.
    A question marked "OPEN" with no recommendation means the
    workstream must surface the trade-off in its plan and
    request a project-level decision.  A question with a
    recommendation may be implemented per the recommendation;
    document the choice in the plan PR.
  * **For reviewers.**  When you see a PR implementing a
    behaviour, check whether that behaviour is governed by an
    open question.  If yes: was the recommendation followed?
    Was an alternative chosen with explicit reasoning?
  * **For maintainers.**  Promote a question from "OPEN" to
    "RESOLVED" when a definitive decision lands; move it to
    §9 with the resolution recorded.

Each question has a sticky identifier (e.g. `OQ-PA-1`) that
PR descriptions can cite.

### §1.1 Urgency matrix — questions by when they must resolve

The columns are *blocking horizon*: when a decision on the
question becomes necessary for a workstream to proceed.

| Horizon | Questions | Drive-by workstream |
|---------|-----------|----------------------|
| **NOW** (blocks an in-flight workstream) | OQ-DOC-4 | CL.1 (cleanup landing) |
| **Before EI lands** | OQ-EI-1 (Std `toList_canonical` audit) | EI.1.b |
| **Before RH lands** | OQ-X-1 (Rust toolchain), OQ-X-2 (corpus format), OQ-RH-2 (re-org alert depth) | RH-H, RH-B.1, RH-G.1 |
| **Before RH-G ships** | OQ-RH-1 (cell-proof format default) | RH-G.4 (coordinated with SC.2) |
| **Before SC lands** | (none; OQ-SC-1 resolved in SC.1.c) | SC |
| **Before WG.1 lands** | OQ-WG-1 (§15 numbering decision) | WG.1.a |
| **Before CA.3 lands** | OQ-CA-1 (L1EscrowLedger ownership) | CA.3.a |
| **Before PA lands** | OQ-PA-1 through OQ-PA-9 (most default to "v1 simpler") | PA |
| **Before LX2 lands** | OQ-LX-1 (refinement direction), OQ-LX-5 (deploymentId derivation), OQ-LX2-4-1 (Decidable fallback) | LX2 |
| **Before LX3 lands** | OQ-LX-6 (resource-roles), OQ-LX-7 (LSP scope), OQ-LX-8 (revokeKey kernel) | LX3 |
| **Before Phase 7 sub-workstream selection** | OQ-P7-1 (selection), OQ-X-3 (multi-deployment) | P7 portfolio review |
| **Before P7.A lands** | OQ-P7-A-1 (delegation depth) | P7.A.7 |
| **Before P7.B lands** | OQ-P7-B-1 (FROST flavour) | P7.B.1 |
| **Before P7.C lands** | OQ-P7-C-1 (proof-system choice) | P7.C.1 |
| **Long-term** | OQ-H-2 (multi-sequencer), OQ-H-3 (ZK timing), OQ-H-4 (L1Attestation soundness lift) | future H follow-ups |

A question with a clear recommendation may be acted on under
that recommendation without explicit ratification.  A question
without a recommendation or one marked "OPEN" *with* a
trade-off that varies by deployment requires the
deployment / project lead to decide.

### §1.2 Decision-dependency graph

Some open questions are *blocked* on others.  Resolving them
in the wrong order produces inconsistent decisions.

```
OQ-X-1 (Rust toolchain pin)
   └──► (no downstream blockers)

OQ-X-2 (Cross-stack corpus format)
   └──► (no downstream blockers)

OQ-X-3 (Multi-deployment shared infrastructure)
   └──► OQ-P7-RH (does P7 require multi-tenancy?)

OQ-DOC-4 (synthesis-doc refresh policy)
   └──► CL.1 landing strategy

OQ-WG-1 (GENESIS_PLAN §15 numbering)
   └──► every §15-numbered cross-reference in source
       (affects CLAUDE.md, audit_remediation_plan.md, …)

OQ-LX-8 (revokeKey kernel addition)
   ◄── depends on ► OQ-X-4 (Mathlib in non-TCB?)
                   (independent of kernel touch policy)

OQ-P7-C-1 (proof-system choice)
   ├── depends on ► OQ-X-3 (deployment-isolation model)
   └──► every deployment that ships a ZK admissibility variant

OQ-P7-1 (Phase 7 sub-workstream selection)
   └──► every Phase 7 sub-workstream's effort estimate
       (the menu shrinks based on this decision)

OQ-RH-1 (cell-proof format default in observer)
   ◄── depends on ► SC.2 landing
   └──► RH-G.4 implementation choice

OQ-CA-1 (L1EscrowLedger type ownership)
   └──► CA.3 implementation
```

### §1.3 Summary table — all open questions

| ID | Topic | Status | Urgency | Recommendation |
|----|-------|--------|---------|----------------|
| OQ-X-1 | Rust toolchain pinning strategy | OPEN | Before RH lands | (a) Pin minor; quarterly bump |
| OQ-X-2 | Cross-stack fixture corpus storage format | OPEN | Before corpus expands | (a) In-tree CBE goldens |
| OQ-X-3 | Multi-deployment shared infrastructure | OPEN | Before Phase 7 | (a) Single-deployment for v1 |
| OQ-X-4 | Mathlib in non-TCB modules | RESOLVED-DEFAULT | Long-term | (a) No Mathlib until specifically justified |
| OQ-PA-1 | Stake-weighted quorum | OPEN | Before PA lands | (a) Equal-weight for v1 |
| OQ-PA-2 | Two-stage propose-then-apply | OPEN | Before PA lands | (a) Immediate for v1 |
| OQ-PA-3 | Delta-style parameter updates | OPEN | Before PA lands | (a) Full-object for v1 |
| OQ-PA-4 | Effective-at-block timelock | OPEN | Before PA lands | (a) No timelock for v1 |
| OQ-PA-5 | Per-resource parameter caps | OPEN | Before PA lands | (a) Single cap for v1 |
| OQ-PA-6 | Governance / LocalPolicy interaction | OPEN | Before PA lands | (a) Document only |
| OQ-PA-7 | Dispute pipeline parameter consumption | OPEN | Before PA lands | (b) Snapshot at filing |
| OQ-PA-8 | Parameter migration across `CanonMigration` | OPEN | Before PA lands | (a) Inherit |
| OQ-PA-9 | Parameter encoder injectivity timing | NEW | Before PA.3 lands | Ship even if EI hasn't (template is the *shape*) |
| OQ-LP-1 | `expireAtNonce` clause | OPEN | Demand-driven | (a) No expiration |
| OQ-LP-2 | Disjunction of clauses (`anyOf`) | OPEN | Demand-driven | (a) AND-only for v1 |
| OQ-LP-3 | Cross-actor policies | RESOLVED | (resolved) | (a) Out-of-scope; capability territory |
| OQ-LP-4 | Policy versioning | OPEN | Demand-driven | (a) No versioning |
| OQ-LP-5 | Policy commitments / hashes | OPEN | Demand-driven | (a) Full storage |
| OQ-LP-6 | Solidity-side LP mirror | OPEN | Demand-driven | (b) Future Workstream-E follow-up |
| OQ-LX-1 | Refinement direction policy | OPEN | Before LX2.1 | (b) Weakening allowed under opt-in |
| OQ-LX-2 | In-flight signed actions across amendments | OPEN | Per deployment | (c) Deployment chooses |
| OQ-LX-3 | Cross-law invariant synthesis | OPEN | Before LX3.5 | (a) No cross-law for v2 |
| OQ-LX-4 | Property-test seed reproducibility | OPEN | Before LX3.6 | (b) Seed printed and replayable |
| OQ-LX-5 | Deployment-ID derivation sub-language | OPEN | Before LX2.3 | (b) Derivation function |
| OQ-LX-6 | Resource-role wrappers | OPEN | Before LX3.1 | (b) Opt-in per law |
| OQ-LX-7 | LSP integration scope | OPEN | Before LX3.2 | (b) Squiggles + hovers + go-to-impl |
| OQ-LX-8 | `Action.revokeKey` kernel addition | OPEN | Before LX3.3 | (b) Ship the constructor |
| OQ-LX-9 | Signer-identity strengthening lift to kernel | OPEN | Before LX2.5 | (a) Shim only |
| OQ-H-1 | SMT cell-proof scheme variants | RESOLVED | (resolved) | (a) Depth 256 uniform |
| OQ-H-2 | Multi-sequencer support (OQ3) | OPEN | Demand-driven | (a) Single-sequencer for MVP |
| OQ-H-3 | ZK Phase 3 timing | OPEN | Long-term | (a) Stay optimistic for v1 |
| OQ-H-4 | L1AttestationSemantics deployment model | OPEN | Long-term | (a) Operational ratification for v1 |
| OQ-P7-1 | Phase 7 sub-workstream prioritisation | OPEN | Per release cycle | Demand-driven; P7.A + P7.F first |
| OQ-P7-2 | Capability-Threshold-signature interaction | OPEN | Before P7.A + P7.B both land | (c) Composable; both orthogonal |
| OQ-P7-3 | Cross-shard atomicity model | OPEN | Before P7.E begins | (a) Coordinator-based 2PC |
| OQ-DOC-1 | `kernelBuildTag` bump cadence | RESOLVED | (resolved) | (a) Bump per workstream landing |
| OQ-DOC-2 | Single canonical "Headline theorems" location | RESOLVED | (resolved) | (a) CLAUDE.md canonical |
| OQ-DOC-3 | `Test/Umbrella.lean` build-tag pin lift | RESOLVED | (resolved) | (a) Keep the pin |
| OQ-DOC-4 | Audit synthesis doc post-AR refresh | OPEN | CL.1 landing | (a) Annotate in place |
| OQ-EI-1 | EI.1.c necessity (Std `toList_canonical` audit) | NEW | Before EI.1.b | Audit Std first; ship EI.1.c only if Std lacks |
| OQ-RH-1 | Witness-state vs SMT cell-proof format default in observer | NEW | RH-G.4 + SC.2 coordination | Pre-SC: witness-state; post-SC: SMT-path |
| OQ-RH-2 | Deep L1 re-org operator-alert threshold | NEW | Before RH-B / RH-G land | (a) confirmationDepth = 12; halt on deeper |
| OQ-SC-1 | Cell-proof bitmask format choice | RESOLVED | (resolved during SC.2 spec) | Bitmask + non-empty siblings concatenated |
| OQ-WG-1 | GENESIS_PLAN §15 chapter numbering | NEW | Before WG.1 lands | (a) Renumber existing §15B → §16 |
| OQ-CA-1 | L1EscrowLedger type ownership | NEW | Before CA.3 lands | (a) `Bridge/L1Escrow.lean` (new module) |
| OQ-P7-A-1 | Capability delegation depth limit default | NEW | Before P7.A.7 lands | (a) Default 4; configurable per deployment |
| OQ-P7-B-1 | FROST flavour choice | NEW | Before P7.B.1 lands | (a) FROST-Ed25519 (more audited) |
| OQ-P7-C-1 | Proof-system choice (Plonk / Halo2 / Groth16 / STARK) | NEW | Before P7.C.1 lands | (a) Plonk over BN254 (universal SRS) |

## §2 Cross-cutting / architectural questions

### OQ-X-1 — Rust toolchain pinning strategy

**Context.**  `rust_host_runtime_plan.md` pins Rust at stable
1.83 LTS.  Future Rust LTS bumps require workspace updates.

**Options.**

  - (a) **Pin minor version, bump quarterly.**  Stable
    cadence; some maintenance overhead.
  - (b) **Pin patch version, freeze.**  Maximum reproducibility;
    eventual incompatibility with new dependencies.
  - (c) **Track stable, no pin.**  Maximum flexibility; risk
    of CI breakage from upstream changes.

**Recommendation.**  (a).  Pin minor; bump on a quarterly
cadence aligned with Lean toolchain bumps.

**Status.**  OPEN.  Owner: Rust workstream lead.

---

### OQ-X-2 — Cross-stack fixture-corpus storage format

**Context.**  E-F shipped a Solidity-Lean cross-stack corpus.
RH and SC extend this to include Rust outputs and SMT cell
proofs.  The fixture format and versioning is informal.

**Options.**

  - (a) **CBE-encoded golden files in source.**  Current
    practice; simple but bloats the repo.
  - (b) **Out-of-tree corpus with content-hash pinning.**
    Build references a tarball with a SHA-256 pin; smaller
    repo but external dependency.
  - (c) **In-tree compressed corpus.**  zstd-compressed CBE;
    smaller than (a), no external dependency.

**Recommendation.**  (a) for ≤ 10 MB total; (c) for larger
corpora.  Cross-stack corpus is currently under 5 MB.

**Status.**  OPEN.  Owner: anyone landing a corpus expansion.

---

### OQ-X-3 — Multi-deployment shared infrastructure

**Context.**  The project supports many deployments
(`deploymentId`-distinguished).  Single-deployment-per-binary
is MVP.  Eventually a single binary or a multi-tenant `canon-host`
will serve multiple deployments.

**Options.**

  - (a) **Stay single-deployment.**  Operators run one binary
    per deployment.  Simplest.
  - (b) **Multi-tenant `canon-host`.**  One host process serves
    multiple `canon` subprocesses indexed by `deploymentId`.
  - (c) **Library-mode `canon`.**  Embed the kernel directly in
    a multi-tenant host; no subprocess.

**Trade-offs.**

  - (a): operational simplicity, resource overhead.
  - (b): resource efficiency, isolation question.
  - (c): tightest integration, biggest design change.

**Recommendation.**  (a) for v1.  (b) as a Phase 7-tier
follow-up if demand justifies.

**Status.**  OPEN.  Owner: project lead / operator team.

---

### OQ-X-4 — Project-wide use of `Mathlib`

**Context.**  CLAUDE.md explicitly forbids Mathlib in the TCB.
Non-TCB modules may import "if absolutely necessary, but the
default is Std core only".  No non-TCB module currently
imports Mathlib.

**Options.**

  - (a) **No Mathlib anywhere.**  Current state; preserved.
  - (b) **Mathlib in select non-TCB modules.**  E.g. EI helper
    lemmas that ride on `Mathlib.Data.Finset`.
  - (c) **Mathlib for tests only.**  Tests may use Mathlib
    convenience lemmas; production code may not.

**Trade-offs.**

  - (a): smallest dependency surface, slowest proof velocity
    for advanced math.
  - (b): risk of accidental TCB-coupling if reviewers slip.
  - (c): tests bloat; production stays clean.

**Recommendation.**  (a) until a specific non-TCB proof is
infeasible without Mathlib.  At that point, gate the addition
behind a §13.6 two-reviewer ratification.

**Status.**  OPEN by default; resolved (a) until challenged.

---

## §3 PA (Parameterized Laws) — forward-roadmap questions

Sources: `docs/parameterized_laws_plan.md` §14.2, audit catalog.

### OQ-PA-1 — Stake-weighted / token-weighted quorum

**Context.**  PA v1 uses equal-weight governance signers.
Real-world deployments may want token-weighted quorum.

**Options.**

  - (a) **Equal-weight only.**  v1 design.
  - (b) **Balance-snapshot-weighted.**  Weight signers by
    their resource-0 balance at proposal time.  Requires
    snapshot mechanism.
  - (c) **Delegated weight.**  Signers may delegate; weight
    flows transitively.

**Trade-offs.**

  - (a): trivially implementable, governance-capture risk.
  - (b): requires `getBalance @ time t` infrastructure;
    snapshot-game-ability concern.
  - (c): transitive delegation can mask actual control.

**Recommendation.**  (a) for v1.  (b) as PA-v2 follow-up when
a deployment requests it.

**Status.**  OPEN.  Owner: PA workstream lead.

---

### OQ-PA-2 — Two-stage propose-then-apply

**Context.**  PA v1 applies parameter changes immediately on
admission.  Some deployments want a "proposal queue" with
discussion period before activation.

**Options.**

  - (a) **Immediate application.**  v1.
  - (b) **Two-stage: propose → apply.**  Adds
    `Action.proposeParameterChange` and
    `Action.applyParameterChange`.
  - (c) **Three-stage: propose → ratify → apply.**  Adds an
    explicit ratification stage.

**Recommendation.**  (a) for v1.  (b) when demand justifies
the doubled action count.

**Status.**  OPEN.

---

### OQ-PA-3 — Delta-style parameter updates

**Context.**  PA v1 ships full-parameter-object updates.
A delta-style ("update only this field") variant saves wire
bytes.

**Options.**

  - (a) **Full-object only.**  v1.
  - (b) **Delta encoding additive.**  Both forms supported.

**Recommendation.**  (a).  Wire-byte savings are marginal at
1 governance action per epoch.

**Status.**  OPEN.

---

### OQ-PA-4 — Effective-at-block timelock

**Context.**  PA v1 changes parameters atomically.  Production
deployments may want a delay between admission and effect for
user-notice purposes.

**Options.**

  - (a) **No timelock.**  v1.
  - (b) **`pending : Option (Parameters × Block)` field.**
    Apply at the recorded block.

**Recommendation.**  (a) for v1.  (b) for v2.

**Status.**  OPEN.

---

### OQ-PA-5 — Per-resource parameter caps

**Context.**  v1 has a single `transferCap : Option Amount`.
Different resources may want different caps.

**Options.**

  - (a) **Single cap.**  v1.
  - (b) **`TreeMap ResourceId Amount` cap.**

**Recommendation.**  (a) until a deployment asks.

**Status.**  OPEN.

---

### OQ-PA-6 — Governance / LocalPolicy interaction

**Context.**  A governance signer with a restrictive LocalPolicy
could lock themselves out of governance.  PA v1 documents this
but does not enforce.

**Options.**

  - (a) **Document only.**  v1.
  - (b) **Mechanical enforcement: governance actions exempt
    from LocalPolicy.**  Matches LP's meta-action exemption.
  - (c) **Mechanical enforcement: governance LocalPolicies
    are vacuous.**  Stronger; eliminates the question.

**Recommendation.**  (a) for v1.  (b) for v2 alignment with LP.

**Status.**  OPEN.

---

### OQ-PA-7 — Dispute pipeline and parameter consumption

**Context.**  Disputes may reference parameters in scope at
filing time.  v1 documents this as "out of scope per PA
design".

**Options.**

  - (a) **Parameter-aware verdicts.**  Verdicts re-evaluate
    using parameters at filing time.
  - (b) **Snapshot at filing.**  Filing captures the current
    parameters; the dispute uses that snapshot.
  - (c) **Latest parameters apply.**  Verdicts always use the
    *current* parameters.

**Recommendation.**  (b).  Captures the user's intent at
filing time; immune to mid-dispute parameter changes.

**Status.**  OPEN.

---

### OQ-PA-8 — Parameter migration across `CanonMigration`

**Context.**  When a chain forks via `CanonMigration`, what
happens to the parameter state?

**Options.**

  - (a) **Inherit.**  Successor uses predecessor's parameters
    until explicitly changed.
  - (b) **Reset.**  Successor starts with defaults.
  - (c) **Explicit migration sequence.**  Deployment supplies
    a parameter-migration function.

**Recommendation.**  (a) by default; (c) available for
deployments that want a reset.

**Status.**  OPEN.

---

## §4 LP (Actor-Scoped Policies) — open questions

Sources: `docs/actor_scoped_policies_plan.md` §13.2.

### OQ-LP-1 — `expireAtNonce` clause

**Context.**  LP v1 supports `denyTag`, `requireRecipient`,
`capAmount`.  An `expireAtNonce N` clause would auto-disable
the policy after N actions by the actor.  Requires recursive
wrapper; v1 deferred.

**Options.**

  - (a) **No expiration.**  v1.  Policies are revoke-only.
  - (b) **`expireAtNonce` recursive wrapper.**

**Recommendation.**  (a) until a real user asks.

**Status.**  OPEN.

---

### OQ-LP-2 — Disjunction of clauses (`anyOf`)

**Context.**  LP v1 is per-clause-AND.  An `anyOf` constructor
would give full boolean expressivity.

**Options.**

  - (a) **AND-only.**  v1.
  - (b) **`anyOf` recursive clause variant.**

**Recommendation.**  (a) for v1.  (b) for v2 if a deployment
requests it.

**Status.**  OPEN.

---

### OQ-LP-3 — Cross-actor policies (delegation / authz)

**Context.**  LP v1 lets actor A constrain A's own outgoing
actions.  Cross-actor authz (e.g. Cosmos `authz` module)
is a different concern.

**Options.**

  - (a) **No cross-actor policies.**  v1; out-of-scope.
  - (b) **Cross-actor authz as a separate workstream.**
    Possibly Phase 7.A (Capabilities) overlap.

**Recommendation.**  (a).  Cross-actor delegation is
capabilities territory (Phase 7.A), not LP.

**Status.**  RESOLVED in favour of (a); cross-reference Phase
7.A.

---

### OQ-LP-4 — Policy versioning

**Context.**  Policies have no version field.  A deployment
might want to enforce "minimum policy version N".

**Options.**

  - (a) **No versioning.**  v1.
  - (b) **`version : Nat` field on `LocalPolicy`.**

**Recommendation.**  (a) until requested.  Trivially additive.

**Status.**  OPEN.

---

### OQ-LP-5 — Policy commitments / hashes

**Context.**  Policies are stored full-text on-chain.  A
space-efficient alternative: store `hash(policy)`; provide the
full policy on revoke.

**Options.**

  - (a) **Full storage.**  v1.
  - (b) **Hash commitments.**  Saves on-chain bytes; auditor
    visibility trade-off.

**Recommendation.**  (a).  Policies are small (typically <
1 KB); savings marginal.

**Status.**  OPEN.

---

### OQ-LP-6 — Solidity-side LP mirror

**Context.**  LP is Lean-only.  L1 contracts could mirror the
policy check for L1-visible audit.

**Options.**

  - (a) **No L1 mirror.**  Operators audit policy off-chain.
  - (b) **L1 mirror as future Workstream-E follow-up.**

**Recommendation.**  (b) when an Ethereum deployment requests
it.

**Status.**  OPEN.  Owner: Workstream-E follow-up.

---

## §5 LX (Lex language) — v2 / v3 design questions

Sources: `docs/law_language_design.md` §14, audit catalog.

### OQ-LX-1 — Refinement direction policy

**Context.**  v1 admits only `pre` strengthening across
versions.  v2 may admit weakening under opt-in.

**Options.**

  - (a) **Strengthening only.**  v1.
  - (b) **Weakening allowed under `@weakening_allowed`.**
    v2 / LX2.1.

**Recommendation.**  (b) in v2 with `lex_diff` flagging.

**Status.**  OPEN until LX2.1 lands.

---

### OQ-LX-2 — In-flight signed actions across amendments

**Context.**  When a deployment amends a law, what happens
to signed actions in-flight (signed under the old law's
admissibility)?

**Options.**

  - (a) **Reject.**  Old actions become inadmissible
    immediately.
  - (b) **Accept under old law for one epoch.**
  - (c) **Deployment chooses.**  Each amendment specifies
    behaviour.

**Recommendation.**  (c).  Deployment-level policy.

**Status.**  OPEN.

---

### OQ-LX-3 — Cross-law invariant synthesis

**Context.**  v3 may synthesize cross-law invariants
("no two laws grant minting authority").  N² scaling.

**Options.**

  - (a) **No cross-law invariants.**  v1 / v2.
  - (b) **Limited cross-law (mint authority only).**
  - (c) **Full cross-law (arbitrary user-supplied
    predicates).**

**Recommendation.**  (a) until v3 establishes a clear use
case.

**Status.**  OPEN until LX3.5.

---

### OQ-LX-4 — Property-test seed reproducibility

**Context.**  v1 property tests use a non-reproducible seed.

**Options.**

  - (a) **No seed reproducibility.**  v1.
  - (b) **Seed printed and replayable.**  v3 / LX3.6.

**Recommendation.**  (b).

**Status.**  OPEN until LX3.6.

---

### OQ-LX-5 — Deployment-ID derivation sub-language

**Context.**  v1 hard-codes `deploymentId`.  v2 / LX2.3 may
introduce a derivation language.

**Options.**

  - (a) **Hard-coded.**  v1.
  - (b) **Derivation function.**  v2.

**Recommendation.**  (b) in v2; derivation function is small.

**Status.**  OPEN until LX2.3.

---

### OQ-LX-6 — Resource-role wrappers (typed-flow enforcement)

**Context.**  v3 / LX3.1 introduces `Roled ρ` phantom-typed
wrappers.

**Options.**

  - (a) **Untyped flat `ResourceId`.**  v1.
  - (b) **Phantom-typed wrappers; opt-in per law.**  v3.
  - (c) **Phantom-typed wrappers; mandatory across all laws.**
    Most disruptive; rejects existing flat-resource laws.

**Recommendation.**  (b) in v3.

**Status.**  OPEN until LX3.1.

---

### OQ-LX-7 — LSP integration scope

**Context.**  v3 / LX3.2.  How much LSP functionality is in scope?

**Options.**

  - (a) **Error squiggles only.**  Cheapest.
  - (b) **Squiggles + hovers + go-to-impl.**  Recommended.
  - (c) **Full IDE support: refactorings, completions,
    code actions.**  Expensive.

**Recommendation.**  (b).

**Status.**  OPEN until LX3.2.

---

### OQ-LX-8 — `Action.revokeKey` kernel addition

**Context.**  v3 / LX3.3.  Kernel amendment requires §13.6
two-reviewer rule.

**Options.**

  - (a) **No `revokeKey`.**  v1.  Workaround: `replaceKey`
    with a known-burnt key.
  - (b) **Ship `Action.revokeKey`.**  v3.

**Recommendation.**  (b).  `replaceKey`-with-burnt-key is
fragile.

**Status.**  OPEN until LX3.3 begins.

---

### OQ-LX-9 — Signer-identity strengthening lift to kernel

**Context.**  v1 ships a shim-layer signer-identity check.
v2 / LX2.5 may lift to the kernel.

**Options.**

  - (a) **Shim only.**  v1 / v2.
  - (b) **Kernel-level lift.**  Triggers §13.6 two-reviewer.

**Recommendation.**  (a).  Shim is sufficient; kernel touch
adds risk.

**Status.**  OPEN until LX2.5.

---

## §6 Workstream H (Fault-Proof) — open questions

### OQ-H-1 — SMT cell-proof scheme variants

**Context.**  `smt_cell_proofs_plan.md` specifies a depth-256
SMT.  Alternative: depth-bounded by actual key range.

**Options.**

  - (a) **Depth 256 (uniform).**
  - (b) **Depth-bounded by max-key.**  Smaller proofs, more
    complex verifier.

**Recommendation.**  (a).  Uniform depth simplifies the
verifier.

**Status.**  RESOLVED in favour of (a); see SC.1.

---

### OQ-H-2 — Multi-sequencer support (OQ3, deferred)

**Context.**  Single-sequencer is MVP.  Multi-sequencer
(round-robin or permissionless) is a deployment-level scaling
question.

**Options.**

  - (a) **Single-sequencer.**  MVP.
  - (b) **Round-robin among configured set.**
  - (c) **Permissionless sequencing (with cryptoeconomic
    backing).**

**Recommendation.**  (a) for MVP.  (b) when demand justifies.

**Status.**  OPEN.

---

### OQ-H-3 — ZK Phase 3 timing

**Context.**  Workstream H ships optimistic disputes; Phase 3
ZK validity proofs are a separate workstream.

**Options.**

  - (a) **No ZK.**  Stay optimistic.
  - (b) **Add ZK alongside optimistic.**  Hybrid.
  - (c) **Replace optimistic with ZK.**  Long-horizon.

**Recommendation.**  (a) for v1.  (b) once Phase 7.C ships
production-grade SNARK infrastructure.

**Status.**  OPEN.

---

### OQ-H-4 — L1AttestationSemantics deployment model

**Context.**  CLAUDE.md footnote 2: the
`faultProof_challenger_won_implies_state_root_wrong` theorem
relies on `L1AttestationSemantics` (a deployment-level
assumption).  Today: cross-stack corpus ratifies operationally.

**Options.**

  - (a) **Operational ratification only.**  Current state.
  - (b) **Mechanical L1-side verifier soundness theorem.**
    Promotes the assumption to a proven property over the
    Solidity contract source.

**Recommendation.**  (a) for v1.  (b) is a longer-term
research project (Solidity verification).

**Status.**  OPEN.

---

## §7 Phase 7 — portfolio prioritisation questions

Phase 7 is a portfolio.  Each sub-workstream's "should we ship"
question is itself an open question.

### OQ-P7-1 — Which Phase 7 sub-workstreams to prioritise

**Context.**  Phase 7 has seven sub-workstreams (P7.A – P7.G).
Resources rarely allow all seven.

**Options.**  Any 2–3 of P7.A – P7.G per release cycle.

**Recommendation.**  Demand-driven.  P7.A (Capabilities) and
P7.F (Schema migration) are recommended first by
`phase_7_plan.md` §4 due to low risk and high demand pattern.

**Status.**  OPEN.  Owner: project lead.

---

### OQ-P7-2 — Capability-Threshold-signature interaction

**Context.**  P7.A (Capabilities) and P7.B (Threshold sigs)
overlap conceptually: a capability with a threshold-signature
issuance.  Should P7.A subsume P7.B?

**Options.**

  - (a) **Independent workstreams.**  Land separately.
  - (b) **Capabilities subsume threshold sigs.**  P7.A's
    `issuerSig` slot accepts a threshold-aggregated signature.
  - (c) **Composable: capabilities + threshold sigs as
    orthogonal extensions.**

**Recommendation.**  (c).  Both ship; the user composes them
per deployment need.

**Status.**  OPEN.

---

### OQ-P7-3 — Cross-shard atomicity model

**Context.**  P7.E (Cross-shard) requires a 2PC-like atomicity
protocol.  Coordinator-based vs coordinator-free.

**Options.**

  - (a) **Coordinator-based 2PC.**
  - (b) **Coordinator-free (Paxos / Raft on the commit set).**

**Recommendation.**  (a).  Simpler; the coordinator is itself
a `canon` instance with its own log.

**Status.**  OPEN until P7.E begins.

---

## §8 Documentation / process questions

### OQ-DOC-1 — `kernelBuildTag` bump cadence

**Context.**  AR.22 set the tag to `canon-audit-remediation`.
Future major workstream landings (EI, RH, SC, WG, CA, PA, P7)
will each want to bump.

**Options.**

  - (a) **Bump per workstream landing.**
  - (b) **Bump per release cycle (semver).**
  - (c) **No bump; remove the tag.**

**Recommendation.**  (a).  Each workstream's PR includes the
bump; `Test/Umbrella.lean` regression test enforces.

**Status.**  RESOLVED in favour of (a).

---

### OQ-DOC-2 — Single canonical "Headline theorems" location

**Context.**  README has a list; CLAUDE.md has a fuller table;
some plan docs have their own headline-theorem subsections.

**Options.**

  - (a) **CLAUDE.md canonical; README and plans cross-
    reference.**
  - (b) **Multiple sources, accept drift.**

**Recommendation.**  (a).

**Status.**  RESOLVED in favour of (a) (per CLAUDE.md
documentation rules).

---

### OQ-DOC-3 — `Test/Umbrella.lean` build-tag pin lift

**Context.**  Currently `Test/Umbrella.lean` pins
`kernelBuildTag` in a regression test.  This means a bump must
update both the constant and the test in the same PR.

**Options.**

  - (a) **Keep the pin.**  v1.
  - (b) **Remove the pin (rely on review discipline).**

**Recommendation.**  (a).  The pin is a forcing function.

**Status.**  RESOLVED in favour of (a).

---

### OQ-DOC-4 — `audits/19-findings-and-followups.md` post-AR refresh

**Context.**  The synthesis doc's "Open follow-ups" section
predates AR remediation.  Should it be regenerated, annotated,
or left as a historical record?

**Options.**

  - (a) **Annotate in place.**  Add an "as of audit date"
    header; strike closed items.
  - (b) **Full rewrite.**  Regenerate from current state.
  - (c) **Add a new doc.**  Leave old doc historical; new doc
    tracks current state.

**Recommendation.**  (a).  Lightest touch; preserves audit
trail.  This is the recommended approach in
`cleanup_and_consolidation_plan.md` CL.1.

**Status.**  OPEN until CL.1 lands.

---

## §9 Sub-workstream-surfaced questions (post-expansion)

Questions that surfaced during the per-plan expansion pass.
Each is scoped to a specific sub-sub-unit and must resolve
before that sub-sub-unit lands.

### OQ-EI-1 — `Std.TreeMap.toList_canonical` audit

**Context.**  EI.1.c (`docs/encoder_injectivity_plan.md`)
introduces an auxiliary lemma in `RBMapLemmas.lean` *only if*
Lean's Std core does not already provide an equivalent.  EI.1.c
triggers the §13.6 two-reviewer rule for `RBMapLemmas.lean`.

**Options.**

  - (a) **Audit first, land EI.1.c only if needed.**  Cheapest:
    if Std covers, the auxiliary lemma is unnecessary.
  - (b) **Ship EI.1.c unconditionally.**  Pre-emptively
    expands the TCB-tier lemma library.

**Recommendation.**  (a).  EI.1.c's first activity is the audit.

**Status.**  OPEN until EI.1.b lands (EI.1.c is gated on it).

### OQ-RH-1 — Cell-proof format default in observer

**Context.**  RH-G.4 (`docs/rust_host_runtime_plan.md`)
constructs cell proofs.  Two formats coexist post-SC:
witness-state (pre-SC) and SMT-path (post-SC).  RH-G's
crate ships a feature flag `cell-proof-format = {witness, smt}`.

**Options.**

  - (a) **Pre-SC: witness-state default; post-SC: SMT-path
    default.**  Matches the deployment-readiness curve.
  - (b) **Witness-state default forever; deployments opt into
    SMT via feature flag.**  Conservative.
  - (c) **SMT-path default immediately; refuse to ship
    witness-state.**  Most aggressive; assumes SC ships first.

**Recommendation.**  (a).  Default tracks the L1-contract
upgrade path.

**Status.**  NEW; resolves when SC.2 reaches mainnet.

### OQ-RH-2 — Deep L1 re-org operator-alert threshold

**Context.**  RH-B.4 and RH-G.2 use the same re-org sliding-
window discipline.  Re-orgs deeper than `confirmationDepth`
trigger an operator alert.

**Options.**

  - (a) **`confirmationDepth = 12` (Ethereum mainnet
    convention); halt on deeper re-org.**
  - (b) **Configurable per deployment via CLI flag.**

**Recommendation.**  (a) as default; (b) as escape hatch.
Both ship simultaneously.

**Status.**  NEW; resolves at RH-B.1 / RH-G.1 design time.

### OQ-WG-1 — GENESIS_PLAN §15 chapter numbering

**Context.**  WG.1.a (`docs/ethereum_workstream_g_plan.md`)
must decide whether to append §15 (Ethereum Integration) or
renumber existing §15B (Fault-Proof Migration) → §16.

**Options.**

  - (a) **Renumber §15B → §16.**  Disruptive (every cross-
    reference updates) but produces clean §15 / §16 / §17
    numbering forever.
  - (b) **Name new chapter §15A; keep §15B as-is.**  Less
    disruptive but creates §15A / §15B / §15C cluster,
    which is asymmetric.

**Recommendation.**  (a).  Long-term clarity wins; budget
~half day for the renumber pass in WG.1.l.

**Status.**  NEW; resolves at WG.1.a.

### OQ-CA-1 — `L1EscrowLedger` type ownership

**Context.**  CA.3 (`docs/chain_level_accounting_plan.md`)
requires a `L1EscrowLedger` type.  May not exist yet.

**Options.**

  - (a) **New module `LegalKernel/Bridge/L1Escrow.lean`.**
    Clean separation; deployment-supplied semantics.
  - (b) **Field on existing `BridgeState`.**  Closer coupling;
    risks scope creep.

**Recommendation.**  (a).  Future deployments may swap
`L1EscrowLedger` implementations independently.

**Status.**  NEW; resolves at CA.3.a.

### OQ-PA-9 — Parameter encoder injectivity timing

**Context.**  PA.3.d (`docs/parameterized_laws_landing_plan.md`)
ships `parameters_encode_injective`.  EI workstream's helper
lemmas are the *template* for the proof shape, not a
dependency.

**Options.**

  - (a) **Ship PA.3.d before EI lands.**  The Parameters
    struct is flat; no EI helpers needed.
  - (b) **Wait for EI to land.**  Reuses EI's helpers if
    possible.

**Recommendation.**  (a).  Parameters being flat means EI's
recursive map machinery is not consumed.

**Status.**  NEW; resolved as (a) recommendation.

### OQ-P7-A-1 — Capability delegation depth limit default

**Context.**  P7.A.7.d (`docs/phase_7_plan.md`) bounds the
delegation chain depth.

**Options.**

  - (a) **Default 4; configurable per deployment.**
  - (b) **Hard-coded 3** (more conservative).
  - (c) **Unbounded; reject in admissibility if
    cycle detected.**  Risky.

**Recommendation.**  (a).  4 is a deployment-tunable default
balancing flexibility and bounded reasoning.

**Status.**  NEW; resolves at P7.A.7 implementation.

### OQ-P7-B-1 — FROST flavour choice

**Context.**  P7.B.1.c (`docs/phase_7_plan.md`) implements
FROST verification.

**Options.**

  - (a) **FROST-Ed25519.**  IETF-standardised; well-audited
    reference implementation in `frost-secp256k1-tr` / `frost-ed25519`.
  - (b) **FROST-secp256k1.**  Ethereum-compatible curve; less
    audited.
  - (c) **Both, deployment-selectable.**

**Recommendation.**  (a) for v1.  (b) as a deployment-flag
extension if an Ethereum-native FROST deployment requests it.

**Status.**  NEW.

### OQ-P7-C-1 — Proof-system choice

**Context.**  P7.C.1.a (`docs/phase_7_plan.md`) chooses
between Plonk, Halo2, Groth16, or STARK for the ZK
admissibility verifier.

**Options.**

  - (a) **Plonk over BN254.**  Universal SRS (one ceremony);
    well-supported tooling; ~100k gas verifier.
  - (b) **Halo2.**  No trusted setup; larger proof sizes;
    halo2-solidity-verifier tooling.
  - (c) **Groth16.**  Smallest proofs / verifier; per-circuit
    trusted setup (operationally painful).
  - (d) **STARK.**  No trusted setup; large proofs, large
    verifier gas; future-proof against quantum.

**Recommendation.**  (a) for v1.  Universal SRS is the
biggest operational advantage; tooling is mature.

**Status.**  NEW.

### OQ-LX2-4-1 — `Decidable`-synthesis fallback policy

**Context.**  LX2.4 (`docs/lex_v2_v3_roadmap_plan.md`)
synthesises `Decidable` instances at elaboration time.  If
synthesis fails, what's the behaviour?

**Options.**

  - (a) **Emit lint warning L024; let elaboration continue.**
    Author can supply hand-written `Decidable`.
  - (b) **Reject elaboration entirely.**  Forces hand-written
    instance.

**Recommendation.**  (a).  Forcing rejection is too strict;
authors should opt into manual instances explicitly.

**Status.**  NEW.

---

## §10 Resolved questions (historical record)

Resolved questions stay here for traceability.  Each carries
the original context, options, resolution, and the workstream /
PR that ratified it.

### OQ-LP-3 — Cross-actor policies (resolved at v1)

**Resolved as.**  (a) Out-of-scope.  Cross-actor authz is
capabilities territory (P7.A), not LP.

**Ratifying decision.**  Documented in
`docs/actor_scoped_policies_plan.md` §13.2.

### OQ-DOC-1 — `kernelBuildTag` bump cadence

**Resolved as.**  (a) Bump per workstream landing.

**Ratifying decision.**  Confirmed across multiple workstream
plans (EI.8.e, RH-H, etc.).

### OQ-DOC-2 — Single canonical "Headline theorems" location

**Resolved as.**  (a) CLAUDE.md canonical; README and plans
cross-reference.

**Ratifying decision.**  CLAUDE.md "Documentation rules"
section.

### OQ-DOC-3 — `Test/Umbrella.lean` build-tag pin

**Resolved as.**  (a) Keep the pin.

**Ratifying decision.**  CLAUDE.md "Current development status".

### OQ-H-1 — SMT cell-proof depth

**Resolved as.**  (a) Depth 256 uniform.

**Ratifying decision.**  `docs/smt_cell_proofs_plan.md` SC.1.b
adopts uniform depth.

### OQ-SC-1 — Cell-proof bitmask format

**Resolved as.**  Bitmask (32 bytes, 256-bit) + non-empty
siblings concatenated.

**Ratifying decision.**  `docs/smt_cell_proofs_plan.md` SC.1.c
ships this layout.

### OQ-X-4 — Mathlib in non-TCB modules (resolved-default)

**Resolved as.**  (a) No Mathlib until specifically justified.

**Ratifying decision.**  CLAUDE.md TCB discipline section.

---

## §11 References

  * `docs/encoder_injectivity_plan.md`
  * `docs/rust_host_runtime_plan.md`
  * `docs/smt_cell_proofs_plan.md`
  * `docs/ethereum_workstream_g_plan.md`
  * `docs/chain_level_accounting_plan.md`
  * `docs/parameterized_laws_landing_plan.md`
  * `docs/phase_7_plan.md`
  * `docs/lex_v2_v3_roadmap_plan.md`
  * `docs/cleanup_and_consolidation_plan.md`
  * `docs/deferred_work_index.md`
  * `docs/GENESIS_PLAN.md`
  * `docs/audit_remediation_plan.md`

---

**End of document.**  This registry is *living*: every PR that
makes a design decision should update this file in the same
landing.  Decisions left implicit are decisions left
unauditable.

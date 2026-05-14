<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Phase 7 — Advanced Capabilities — Engineering Plan

This document plans Phase 7, the long-horizon advanced-capability
workstream that GENESIS_PLAN.md §12 lists as "not started"
with a 20.0+ engineer-weeks open-ended estimate.

Phase 7 is **not a single deliverable**; it is a portfolio of
seven independent work units that may be undertaken in any
order, each adding a major capability to the system.  This plan
treats them as seven sub-workstreams, each with its own goals,
non-goals, work-unit decomposition, and acceptance criteria.

## Status

  * **Workstream prefix:** `P7`.  Seven sub-workstreams:
    - **P7.A** Capabilities (object-capability authorisation).
    - **P7.B** Threshold signatures (FROST adaptor).
    - **P7.C** ZK proof of admissibility (Plonk via halo2).
    - **P7.D** Intent solver (constraint-based action search).
    - **P7.E** Cross-shard transition protocol.
    - **P7.F** Schema migration framework.
    - **P7.G** Multi-region replication (CRDT log).
  * **Effort estimate:** 20+ engineer-weeks (open-ended).  Each
    sub-workstream's effort is 2–4 calendar weeks for one
    full-time engineer with relevant domain expertise.
  * **Build-posture target:** every sub-workstream lands behind
    the existing CI gates; introduces zero custom axioms; does
    not touch the TCB without explicit two-reviewer approval.
  * **Dependencies:** each sub-workstream has prerequisites on
    earlier phases (Phase 3 for P7.A / P7.B / P7.D, Phase 5 for
    P7.C / P7.E / P7.F / P7.G).
  * **Trust-assumption delta:** P7.B and P7.C introduce new
    trust assumptions (FROST DKG correctness; SNARK soundness)
    documented in their respective sub-workstream §1.2.

## Table of contents

  * §1 Goals and non-goals for Phase 7 overall
  * §2 Sub-workstream specifications
    * §2.A Capabilities (P7.A)
    * §2.B Threshold signatures (P7.B)
    * §2.C ZK proof of admissibility (P7.C)
    * §2.D Intent solver (P7.D)
    * §2.E Cross-shard transition protocol (P7.E)
    * §2.F Schema migration framework (P7.F)
    * §2.G Multi-region replication (P7.G)
  * §3 Cross-cutting concerns
  * §4 Sequencing recommendations
  * §5 Quality gates
  * §6 Risk register (portfolio-level)
  * §7 Acceptance criteria for Phase 7 as a whole
  * §8 References

## §1 Goals and non-goals (portfolio-level)

### §1.1 Phase 7 goals

  1. **Add seven major capabilities** to the project, each
    additive to the existing kernel + Authority + Bridge +
    Lex + FaultProof surface.
  2. **Preserve TCB invariants.**  Every sub-workstream ships
    under non-TCB modules.  Any kernel touch requires the
    §13.6 two-reviewer rule.
  3. **Preserve zero-custom-axiom discipline.**  Each
    sub-workstream's theorems reduce to a subset of
    `[propext, Classical.choice, Quot.sound]`.

### §1.2 Phase 7 non-goals

  1. **No single big-bang landing.**  Each sub-workstream is
    independent and can land in any order.
  2. **No commitment to ship all seven.**  Phase 7 is a
    capability menu; deployments may pick a subset.
  3. **No retroactive changes to Phases 0–6.**  Each
    sub-workstream extends the surface; existing theorems
    are unchanged.

### §1.3 Reading guide

This document is a *portfolio plan*.  Each sub-workstream's
detailed engineering plan should be lifted out into its own
document at the moment landing begins (e.g.
`docs/phase_7a_capabilities_plan.md`).  Use this document for:
  - Portfolio-level coordination.
  - Pre-implementation cost-benefit triage.
  - Cross-cutting design constraint enumeration.

## §2 Sub-workstream specifications

---

### §2.A Capabilities (P7.A)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.1 + §3.X.

**Goal.**  Introduce object-capability authorisation alongside
the existing identity + nonce + signature scheme.  Capabilities
are unforgeable tokens that grant scoped permission (e.g. "may
mint resource R up to amount A until block B").

**Dependencies.**  Phase 3 (Authority layer) complete (✓).

**Design sketch.**

```lean
structure Capability where
  issuer    : ActorId
  scope     : ScopeSpec      -- inductive: resource, amount cap, time bound
  delegates : List ActorId   -- transitive delegation
  nonce     : Nonce
  issuerSig : Signature

inductive ScopeSpec where
  | mintAuthority (resource : ResourceId) (cap : Amount) (validUntil : Block)
  | transferAuthority (from : ActorId) (allow : Set ResourceId) ...
  | spend (capId : Hash) (amount : Amount)
  ...
```

A new `Action.applyCapability (cap : Capability) (use : ApplyUse)`
constructor takes a capability + a usage record, validates that:
  1. The capability's issuer signature is valid.
  2. The capability has not expired (block bound, nonce-burn).
  3. The usage is within scope.
  4. The capability has not been revoked (registry check).

**Work-unit decomposition.**  P7.A decomposes into eight
sub-units; each ships as its own PR.

#### P7.A.1 — `Capability` type + `ScopeSpec` inductive

  * **P7.A.1.a** — `Capability` structure with five fields
    (`issuer`, `scope`, `delegates`, `nonce`, `issuerSig`).
  * **P7.A.1.b** — `ScopeSpec` inductive with three variants
    (`mintAuthority`, `transferAuthority`, `spend`) plus
    extension hook for deployment-specific scopes.
  * **P7.A.1.c** — `CapabilityRegistry` substrate
    (`TreeMap Hash Capability compare`) added to
    `ExtendedState` (TCB touch — **two reviewers**).
  * **P7.A.1.d** — `Inhabited` + `DecidableEq` derivations.

**Effort.**  ~2 engineer-days.

#### P7.A.2 — CBE encoding

  * **P7.A.2.a** — `Encodable Capability` instance.
  * **P7.A.2.b** — `Encodable ScopeSpec` (inductive,
    constructor-tag prefix).
  * **P7.A.2.c** — Round-trip + injective lemmas (follow
    EI workstream's template — see
    `docs/planning/encoder_injectivity_plan.md`).
  * **P7.A.2.d** — Map-injectivity for the registry
    (template from EI.4 / EI.5).

**Effort.**  ~2 engineer-days.

#### P7.A.3 — Issuance law: `Action.issueCapability`

  * **P7.A.3.a** — Reserve `Action.issueCapability`
    constructor index (P7 reserves indices 30+; see §3.1).
  * **P7.A.3.b** — Pre: issuer's signature valid + nonce
    fresh + scope well-formed.
  * **P7.A.3.c** — Apply: insert into `CapabilityRegistry`
    keyed by `hash(cap.encode)`.
  * **P7.A.3.d** — Event emission: `Event.capabilityIssued`.

**Effort.**  ~2 engineer-days.

#### P7.A.4 — Use law: `Action.applyCapability`

  * **P7.A.4.a** — Reserve constructor index.
  * **P7.A.4.b** — Pre: `cap.encode` hash matches a registry
    entry; `use` falls within `cap.scope`; capability not
    expired (block bound check via `s.blockNumber`); user is
    `cap.issuer` or in `cap.delegates`.
  * **P7.A.4.c** — Apply: execute the scope-matched effect
    (mint, transfer, etc.).  This is the load-bearing
    case-split: each `ScopeSpec` variant calls the
    appropriate underlying law's `apply`.
  * **P7.A.4.d** — Headline theorem `capability_use_admissible_iff_scope_match`.

**Effort.**  ~3 engineer-days.

#### P7.A.5 — Revocation law

  * **P7.A.5.a** — Reserve `Action.revokeCapability` index.
  * **P7.A.5.b** — Pre: signer holds the capability's issuer
    role.
  * **P7.A.5.c** — Apply: remove from registry.
  * **P7.A.5.d** — Verify no interaction with existing
    `replaceKey` machinery via cross-test.

**Effort.**  ~1.5 engineer-days.

#### P7.A.6 — `CapabilitySafeLawSet` firewall

  * **P7.A.6.a** — `IsCapabilitySafe` typeclass: a law is
    capability-safe iff it cannot bypass the capability
    registry (every grant must be via `issueCapability`).
  * **P7.A.6.b** — Witness instances for all kernel laws.
  * **P7.A.6.c** — `CapabilitySafeLawSet` firewall: type-
    level rejection of unsafe law sets.

**Effort.**  ~2 engineer-days.

#### P7.A.7 — Test suite

  * **P7.A.7.a** — Issuance + use happy path.
  * **P7.A.7.b** — Expiration negative test.
  * **P7.A.7.c** — Revocation test.
  * **P7.A.7.d** — Delegation chain test (bound depth via
    `--delegation-depth-limit`).
  * **P7.A.7.e** — Cross-stack fixture corpus.

**Effort.**  ~1.5 engineer-days.

#### P7.A.8 — Lex DSL extension

  * **P7.A.8.a** — `lex_law` macro extension: `capability_grant
    { scope: …, expires_at: … }` clause.
  * **P7.A.8.b** — Synthesize the `Action.issueCapability`
    invocation from the clause.

**Effort.**  ~1 engineer-day.

---

#### P7.A — Rolled-up

**Headline theorem.**

```lean
theorem capability_use_admissible_iff_scope_match :
  ∀ s cap use, Action.applyCapability cap use ∈ admissible s ↔
    capability_in_scope cap use ∧ capability_not_revoked s cap ∧
    capability_signature_valid cap
```

**Aggregate effort:** ~15 engineer-days = 3 calendar weeks
(revised up from 2 weeks; the decomposition surfaced
~5 days of additional scope, primarily in P7.A.4's
case-split and P7.A.6's firewall typeclass).

**Risks.**

  * Capability revocation interacts with the existing nonce
    machinery; design carefully (P7.A.5).
  * Transitive delegation can lead to exponential authority
    chains; bound by `--delegation-depth-limit` (default 4).
  * `CapabilityRegistry` adds an `ExtendedState` field — TCB
    touch; two-reviewer rule applies for P7.A.1.c.

---

### §2.B Threshold signatures — FROST adaptor (P7.B)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.2.

**Goal.**  Replace single-signer `Verify` with a threshold-
signature scheme (FROST over secp256k1) for governance and
multi-actor admission flows.

**Dependencies.**  Phase 3.4 complete (✓); ideally PA (parameter
governance) landed first.

**Design sketch.**

Two integration points:
  1. **Aggregated signature opaque.**  A new `verifyThreshold :
    List PublicKey → ByteArray → Signature → Nat → Bool` opaque
    (alongside the existing `Verify`).  The implementation
    expects a FROST-aggregated `Signature` and a threshold `Nat`.
  2. **Distributed key generation (DKG).**  The DKG protocol
    runs off-chain; only the aggregated public key lands on-chain.
    `Action.registerThresholdGroup (pk_agg, members, threshold)`
    publishes the group.

**Work-unit decomposition.**  Six sub-units; landing parallels
the RH-A pattern for adaptor crates.

#### P7.B.1 — `verifyThreshold` opaque + Rust adaptor

  * **P7.B.1.a** — Add `opaque verifyThreshold : List
    PublicKey → ByteArray → Signature → Nat → Bool` to
    `LegalKernel/Authority/Crypto.lean`.  Triggers
    `Authority/Crypto.lean` two-reviewer rule (TCB-adjacent).
  * **P7.B.1.b** — `runtime/canon-verify-frost/` crate
    (parallel to RH-A.1 pattern from
    `docs/planning/rust_host_runtime_plan.md`).
  * **P7.B.1.c** — FROST-Ed25519 verification (the
    standardised FROST flavour; secp256k1 variant
    available but less audited).
  * **P7.B.1.d** — Cross-stack fixture corpus.

**Effort.**  ~4 engineer-days.

#### P7.B.2 — `Action.registerThresholdGroup`

  * **P7.B.2.a** — Reserve constructor index.
  * **P7.B.2.b** — Pre: signer authorised by deployment
    (per a deployment-supplied policy).
  * **P7.B.2.c** — Apply: insert into
    `ThresholdGroupRegistry` (a new substrate on
    `ExtendedState`; TCB touch, two reviewers).
  * **P7.B.2.d** — Event emission.

**Effort.**  ~2 engineer-days.

#### P7.B.3 — `Action.applyThresholdSigned`

  * **P7.B.3.a** — Wraps an inner non-threshold `Action`
    with a threshold signature.
  * **P7.B.3.b** — Pre: `verifyThreshold (group.members)
    (innerAction.encode) sig group.threshold = true`; inner
    action's pre also holds.
  * **P7.B.3.c** — Apply: invoke inner action's apply with
    a synthesised signer (the group's aggregated identity).

**Effort.**  ~2 engineer-days.

#### P7.B.4 — Replay prevention

  * **P7.B.4.a** — Per-group nonce in
    `ThresholdGroupRegistry`.
  * **P7.B.4.b** — `threshold_nonce_strict_mono` lemma
    (analog of the per-actor lemma).
  * **P7.B.4.c** — `threshold_signature_replay_impossible`
    headline theorem.

**Effort.**  ~2 engineer-days.

#### P7.B.5 — Lex DSL clause

  * `threshold_signed_by { group: G, threshold: K }` clause
    in `lex_law`.
  * Synthesise the threshold-signature wrapping.

**Effort.**  ~1 engineer-day.

#### P7.B.6 — Test suite

  * Cross-stack FROST vectors (≥ 30).
  * Replay-prevention regression.
  * Insufficient-quorum negative test.

**Effort.**  ~2 engineer-days.

---

#### P7.B — Rolled-up

**Headline theorem.**

```lean
theorem threshold_signature_replay_impossible :
  ∀ s s' wrapped, AdmissibleThreshold s wrapped →
                  ApplyThreshold s wrapped = .ok s' →
                  ¬ AdmissibleThreshold s' wrapped
```

(Same structure as the existing `replay_impossible` but lifted
to threshold-wrapped actions.)

**Aggregate effort:** ~13 engineer-days ≈ 2.6 calendar weeks.

**Trust-assumption delta.**  Adds: "FROST DKG produces an
honestly-generated aggregated public key when at least `threshold`
of the participants follow the protocol."  Documented in
`extraction_notes.md` §2 under WG.4 pattern.

---

### §2.C ZK proof of admissibility — Plonk / halo2 (P7.C)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.3.

**Goal.**  Allow `Action` admissibility to be proved via a
SNARK rather than via in-line precondition evaluation, reducing
L1 verification cost and enabling private inputs.

**Dependencies.**  Phase 5 (Runtime + extraction) complete (✓).

**Design sketch.**

The SNARK circuit encodes:
  - Public input: pre-state hash, action ID, post-state hash.
  - Witness: full pre-state, action body, admissibility proof
    trace.
  - Constraint: `step_impl` agrees with the public inputs.

**Work-unit decomposition.**  P7.C is the most technically
complex Phase 7 sub-workstream.  Eight sub-units, with the
circuit IR (P7.C.1) being the critical path.

#### P7.C.1 — Circuit specification

  * **P7.C.1.a** — Choose proof system: Plonk over BN254
    (recommend); alternatives Halo2 (BN254 + IPA),
    Groth16 (smaller proofs, no universal setup), STARK
    (no trusted setup, larger proofs).  Decision recorded
    in OQ-P7-zk (open question).
  * **P7.C.1.b** — Design the public-input encoding:
    `(prestate_hash : Field, action_hash : Field,
    poststate_hash : Field)`.  All three are 32-byte hashes
    bit-decomposed into `Field` elements (Plonkish circuits
    work over `Field`).
  * **P7.C.1.c** — Specify the circuit for `transfer` (the
    smallest concrete law).  Constraints:
     - Decode the prestate's `balances[from][resource]`
       from the prestate hash via a Merkle-path opening.
     - Decode `balances[to][resource]` similarly.
     - Verify `balances[from][resource] ≥ amount`.
     - Compute new balances; re-hash to poststate_hash.
  * **P7.C.1.d** — Estimate constraint count: target ≤ 2M
    constraints for `transfer` (corresponds to ~5-10s proof
    time on a 32-core machine).

**Effort.**  ~10 engineer-days.

#### P7.C.2 — `halo2` proof generator (Rust crate)

  * **P7.C.2.a** — Crate skeleton `runtime/canon-zk-prover/`.
  * **P7.C.2.b** — Implement the circuit per P7.C.1.c.
  * **P7.C.2.c** — Proving-key generation (one-time trusted
    setup or universal SRS).
  * **P7.C.2.d** — Proof generation API: `prove(prestate :
    ExtendedState, action : Action, poststate :
    ExtendedState) → Proof`.

**Effort.**  ~10 engineer-days.

#### P7.C.3 — Solidity on-chain verifier

  * **P7.C.3.a** — Generate Solidity verifier from circuit
    (Plonk verifiers are mechanically derivable; `snarkjs`
    or `halo2-solidity-verifier` provide tooling).
  * **P7.C.3.b** — Optimise gas: target ≤ 100k gas for
    verification.
  * **P7.C.3.c** — Solidity test suite.

**Effort.**  ~5 engineer-days.

#### P7.C.4 — `Action.applyWithZkProof`

  * **P7.C.4.a** — Reserve `Action.applyWithZkProof
    (innerAction : Action) (proof : ZkProof)` constructor.
  * **P7.C.4.b** — Pre: `verifyZkProof (commitState s)
    innerAction.hash (commitNextState s innerAction) proof
    = true`.  Note that the precondition *does not require*
    `innerAction.pre s` to hold operationally — the SNARK
    proof attests admissibility.
  * **P7.C.4.c** — Apply: compute the next state per the
    inner action; the SNARK proof guarantees admissibility
    held.

**Effort.**  ~3 engineer-days.

#### P7.C.5 — Soundness + completeness theorems

  * **P7.C.5.a** — `SnarkSoundness verifyZkProof : Prop`
    opaque (deployment-supplied; documented as the trust
    assumption).
  * **P7.C.5.b** — `zk_proof_completeness` headline theorem
    (any valid step admits a ZK proof).
  * **P7.C.5.c** — `zk_proof_soundness` headline theorem
    (under `SnarkSoundness`, a verified proof implies a
    valid step exists).

**Effort.**  ~5 engineer-days.

#### P7.C.6 — Cross-stack verifier corpus

  * **P7.C.6.a** — 50+ recorded proofs from the Rust prover.
  * **P7.C.6.b** — Solidity verifier validates each.
  * **P7.C.6.c** — Lean side: assert proof bytes round-trip
    through CBE.

**Effort.**  ~3 engineer-days.

#### P7.C.7 — Performance optimisation

  * Gas target: ≤ 100k for verifyZkProof.
  * Proof-time target: ≤ 30s on a developer machine
    (8-core, 32 GB RAM) for `transfer`.
  * If miss: profile and document the gap.

**Effort.**  ~5 engineer-days (worst case; may not be
needed if initial targets are met).

#### P7.C.8 — Extension to multiple laws

  * **P7.C.8.a** — Generalise the circuit to a union of
    per-law sub-circuits.
  * **P7.C.8.b** — Add `mint`, `burn` to the circuit set.
  * **P7.C.8.c** — Cross-stack corpus extension.

**Effort.**  ~5 engineer-days per additional law (open-
ended; deployments choose which laws to ZKify).

---

#### P7.C — Rolled-up

**Headline theorem.**

```lean
theorem zk_proof_completeness :
  ∀ s action s' hpre, step_impl action.toTransition hpre s = .ok s' →
                       ∃ π, verifyZkProof (commitState s) action.id (commitState s') π = true

theorem zk_proof_soundness :
  SnarkSoundness verifyZkProof →
  ∀ s action s' π, verifyZkProof (commitState s) action.id (commitState s') π = true →
                    ∃ hpre, step_impl action.toTransition hpre s = .ok s'
```

`SnarkSoundness` is a new opaque deployment-supplied predicate
capturing the SNARK's cryptographic soundness assumption.

**Aggregate effort:** ~46 engineer-days for `transfer`-only
(matches prior 4-week estimate optimistically; realistic is 6
weeks).  Each additional law: ~5 days.

**Trust-assumption delta.**  Adds: "Plonk over BN254 is sound
under the AGM and the discrete-log assumption."

**Risks.**

  * High: SNARK soundness gaps are subtle and historically
    devastating.  Mitigation: use only well-audited proving
    systems (Plonk / Halo2); never roll a custom one.
  * Medium: gas target may not be achievable without circuit-
    specific optimisation.
  * Medium: trusted setup (if Plonk) requires a deployment
    ceremony; alternative is to use STARKs or transparent
    SNARKs (no setup).

---

### §2.D Intent solver (P7.D)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.4.

**Goal.**  A constraint-based action-sequence search engine:
given a desired post-state predicate (`P : ExtendedState → Prop`)
and a starting state `s`, search the action space for a
sequence of admissible actions producing a state satisfying
`P`.

**Dependencies.**  Phase 3 (Authority) complete (✓).

**Design sketch.**

```lean
def IntentSolve (s : ExtendedState) (P : ExtendedState → Prop) :
                IO (Option (List Action))
```

The solver is *not* part of the kernel; it lives in
`LegalKernel/Intent/Solver.lean` as a non-TCB synthesis
helper.  It produces a candidate action sequence; the kernel's
admissibility predicate still verifies each step.

**Work-unit decomposition.**

  * P7.D.1 Constraint language (a small predicate DSL).
  * P7.D.2 Solver core (best-first search over `Action`
    constructors with depth bound).
  * P7.D.3 Heuristic pruning (parameter-aware).
  * P7.D.4 Test suite over toy intents.
  * P7.D.5 Lex DSL: `intent { from: X, achieves: P, by: ... }`.

**Headline property** (not a theorem; the solver is a tool):

```
If IntentSolve s P returns Some seq, then applying seq to s
produces a state satisfying P.
```

This is *operationally* verified: the solver's output is fed
through the standard admissibility chain; bugs in the solver
produce rejected actions, not unsoundness.

**Effort.**  3.0 calendar weeks.

---

### §2.E Cross-shard transition protocol (P7.E)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.5.

**Goal.**  Allow a single logical state to span multiple
`canon` instances (shards), with cross-shard transitions
mediated by a shard-coordination protocol.

**Dependencies.**  Phase 5.5 (replay tool) complete (✓).

**Design sketch.**

Two-phase commit over `n` shards.  Each shard runs its own
`canon`; cross-shard actions are split into:
  1. A "prepare" phase on every shard touching its substate.
  2. A "commit" phase that finalises all shards atomically.

**Work-unit decomposition.**  Seven sub-units.  Cross-shard
protocols are historically difficult; each phase ships with
explicit failure-mode catalogue.

#### P7.E.1 — Shard model + `ShardId` substrate

  * **P7.E.1.a** — `ShardId : Type` (a 32-byte deployment-
    chosen identifier).
  * **P7.E.1.b** — `ExtendedState.shardId : ShardId` field
    (TCB touch, two reviewers).
  * **P7.E.1.c** — `ShardConfiguration` record: list of
    shard ids, coordinator selection policy.

**Effort.**  ~2 engineer-days.

#### P7.E.2 — `Action.crossShardPrepare`

  * Reserve constructor index.
  * Pre: action's substate-effect is locally admissible on
    this shard; shard has not already prepared for this
    cross-shard transaction.
  * Apply: write a `Pending` entry in
    `crossShardPending : TreeMap TxnId CrossShardTxn` (new
    substate field; TCB touch).
  * Block local mutations to affected substate until commit
    or rollback.

**Effort.**  ~4 engineer-days.

#### P7.E.3 — `Action.crossShardCommit` + `Action.crossShardRollback`

  * Pre: every shard's coordinator has confirmed prepare
    (via signature) OR the timeout has elapsed (rollback).
  * Apply commit: apply the pending action's local effect;
    remove from `crossShardPending`.
  * Apply rollback: discard the pending entry; release the
    locked substate.

**Effort.**  ~3 engineer-days.

#### P7.E.4 — Coordinator opaque

  * `opaque crossShardCoordinator : ShardId → TxnId → Coordinator
    PrepareVote` — deployment-supplied 2PC implementation.
  * Document deployment-level requirements: coordinator
    must be Byzantine fault-tolerant or single-trusted-party
    (TA: "coordinator is honest").

**Effort.**  ~1 engineer-day.

#### P7.E.5 — Atomicity theorem

  * `crossShard_atomic : ∀ shards txn, CrossShardCommitted
    shards txn → ∀ s ∈ shards, s.committed txn`.
  * Proof depends on the coordinator-opaque trust assumption.

**Effort.**  ~3 engineer-days.

#### P7.E.6 — Two-shard demonstration

  * Spin up two `canon` instances; execute a cross-shard
    transfer (move balance from actor A on shard 1 to
    actor B on shard 2); verify atomicity.

**Effort.**  ~3 engineer-days.

#### P7.E.7 — Failure-mode catalogue + chaos test

  | Failure | Detection | Response |
  |---------|-----------|----------|
  | Coordinator crashes mid-prepare | Timeout | Rollback all shards |
  | Coordinator crashes post-prepare, pre-commit | Timeout | Manual operator decision (commit or rollback) |
  | Network partition isolates a shard | Heartbeat loss | Affected shards rollback; partition heals → reconcile |
  | Byzantine coordinator | Detected at commit time (signature mismatch) | Reject; alert operators |

  * Chaos suite simulates each failure.

**Effort.**  ~4 engineer-days.

---

#### P7.E — Rolled-up

**Headline theorem.**

```lean
theorem crossShard_atomic :
  ∀ shards txn, CrossShardCommitted shards txn →
                 ∀ s ∈ shards, s.committed txn
```

**Aggregate effort:** ~20 engineer-days ≈ 4 calendar weeks.

**Risks.**  Distributed systems are hard.  Failure modes
catalogued in P7.E.7; deployment-level mitigation is
documented in the trust-assumption catalogue
(`extraction_notes.md` §2).

---

### §2.F Schema migration framework (P7.F)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.6.

**Goal.**  Allow a running deployment to migrate to a new
`ExtendedState` schema (e.g. add a new sub-state) without log
truncation.

**Dependencies.**  Phase 5.12 (`CanonMigration` infrastructure)
complete (✓).

**Design sketch.**

A migration is a function
`migrate : ExtendedState_old → ExtendedState_new` plus a
provable invariant `migrate_preserves_admissibility`.  Live
deployments execute the migration at a designated `Block`;
the transition appears as a new `Action.migrate` constructor
in the log.

**Work-unit decomposition.**

  * P7.F.1 `MigrationSpec` type with `oldSchema` /
    `newSchema` / `migrate` / `preservation_proof`.
  * P7.F.2 `Action.migrate` constructor.
  * P7.F.3 Type-level guarantee:
    `migration_preserves_law_set_admissibility`.
  * P7.F.4 Demo: add a `tags : Set Tag` field to a synthetic
    state schema.

**Effort.**  2.0 calendar weeks.

---

### §2.G Multi-region replication (CRDT log) (P7.G)

**Provenance.**  GENESIS_PLAN.md §12 WU 7.7.

**Goal.**  Replicate the canonical log across geographically
distributed `canon` instances using CRDT-style convergent
operations.

**Dependencies.**  Phase 5.12 (replay infrastructure) complete
(✓).

**Design sketch.**

A *commutative* operation set: only kernel `Action`s that
admit commutative composition can be replicated.  Non-commutative
actions (e.g. `setParameters`) require explicit anchoring to
the primary region.

The CRDT layer is *outside* the kernel; the kernel sees a single
deterministic log per region.  The CRDT log is the cross-region
synchronisation primitive.

**Work-unit decomposition.**

  * P7.G.1 Commutativity classification: `IsCommutative
    (action : Action) : Prop`.
  * P7.G.2 CRDT merge function over commutative actions.
  * P7.G.3 Anchor protocol for non-commutative actions.
  * P7.G.4 Multi-region demo (two regions, latency-injected
    test harness).

**Headline theorem.**

```lean
theorem crdt_convergence :
  ∀ region_logs : List Log,
    pairwise_commutative region_logs →
    ∃ merged : Log,
      ∀ r ∈ region_logs, Reachable r.final_state merged.final_state
```

**Effort.**  3.0 calendar weeks.

---

## §3 Cross-cutting concerns

### §3.1 Action index reservations

Each sub-workstream reserves a frozen range of `Action`
constructor indices.  Coordinate via `Lex.IndexRegistry.txt`
(append-only registry):

| Sub-workstream | Reserved range |
|---|---|
| P7.A Capabilities | 30–35 (5 constructors) |
| P7.B Threshold sigs | 36–38 (3 constructors) |
| P7.C ZK proofs | 39 (1 constructor) |
| P7.D Intent solver | none (solver is non-Action) |
| P7.E Cross-shard | 40–41 (2 constructors) |
| P7.F Schema migration | 42 (1 constructor) |
| P7.G Multi-region | none (CRDT is layer-above) |

Indices are illustrative; consult the actual registry before
implementation.

### §3.2 Opaque expansion

Sub-workstreams that introduce new opaques (P7.B, P7.C, P7.E)
must document them in `extraction_notes.md` §2 (the
trust-assumption catalogue) at landing time.

### §3.3 TCB discipline

No sub-workstream is expected to touch the TCB.  If a kernel
extension is necessary (e.g. for P7.A's capability machinery),
the two-reviewer rule and Genesis-Plan amendment process apply.

### §3.4 Lex DSL extensions

P7.A, P7.B, and P7.D each introduce new Lex clauses
(`capability_grant`, `threshold_signed_by`, `intent`).  These
should land alongside the kernel-side work, with `lex_lint`
diagnostic codes reserved (deferred-set in
`Lex/Test/Tools/DiagnosticCoverage.lean`).

## §4 Sequencing recommendations

Phase 7 has no single critical path.  Recommended ordering
(based on dependency, demand, and risk):

```
Highest priority (demand-driven, low risk):
  P7.A Capabilities       (2.0w, depends on Phase 3)
  P7.F Schema migration   (2.0w, depends on Phase 5.12)

Medium priority (capability-expanding):
  P7.B Threshold sigs     (2.0w, depends on Phase 3.4 + PA)
  P7.D Intent solver      (3.0w, depends on Phase 3)

Lower priority (high research, high impact):
  P7.G Multi-region       (3.0w, depends on Phase 5.12)
  P7.E Cross-shard        (4.0w, depends on Phase 5.5)
  P7.C ZK proofs          (4.0w, depends on Phase 5.1)
```

Total: **20 calendar weeks** for one full-time engineer
working serially; **8–10 weeks** for two engineers working
in parallel (P7.A + P7.F first as low-risk parallel landings).

## §5 Quality gates

Standard project gates plus:
  * Each sub-workstream's `#print axioms` reduces to a subset
    of the three Lean built-ins, plus any explicitly-documented
    sub-workstream-specific opaques.
  * `Action` / `Event` index reservations honoured (extends
    AR.5 / AR.6 regression tests in the same PR).
  * Cross-stack fixture corpus extended for sub-workstreams
    with Solidity counterparts (P7.B, P7.C, P7.F).
  * `extraction_notes.md` §2 updated for new opaques.

## §6 Risk register (portfolio-level)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Sub-workstreams interact unexpectedly (e.g. P7.A capabilities + P7.B threshold-signed actions) | Medium | Medium | Land sub-workstreams behind feature flags; integration tests at cross-cuts |
| Action-index space exhausts | Low | Low | Index space is 256-wide today; Phase 7 reserves ~13 slots; plenty of headroom |
| Phase 7 capability creep absorbs project bandwidth indefinitely | High | High | Treat as a menu; pick 2–3 sub-workstreams per release cycle; do not commit to all seven upfront |
| New opaque expansion is forgotten in `extraction_notes.md` | Medium | Medium | Pre-merge checklist includes "extraction_notes.md updated" |
| TCB change required for an unforeseen sub-workstream | Low | High | Treat any TCB-touching change as a Genesis-Plan amendment; pause sub-workstream until §13.6 + §14.4 process complete |

## §7 Acceptance criteria for Phase 7 as a whole

Phase 7 is **complete** when:

  1. Each shipped sub-workstream has:
     - Implementation complete in `LegalKernel/<area>/`.
     - Tests passing.
     - Headline theorem(s) shipped with clean `#print axioms`.
     - Cross-stack corpus extended (where applicable).
     - Lex DSL extension (where applicable).
     - `Action` / `Event` indices frozen via AR.5 / AR.6 pattern.
  2. CLAUDE.md status table:
     - "Phase 7 | 7 WUs | 20.0+ | partial — `<n>` of 7
       shipped" until all seven ship.
     - When all seven ship: "Phase 7 | 7 WUs | 20.0+ | complete".
  3. `docs/GENESIS_PLAN.md` §12 phase table updated to reflect
    each landing.
  4. Each sub-workstream's detailed plan exists as its own
    document under `docs/phase_7<letter>_<topic>_plan.md`.

**Note:** Phase 7 may *never* fully complete in the absolute
sense; deployments may legitimately ship without (e.g.) ZK
proofs.  "Complete" means "every sub-workstream's spec is
realised", not "every deployment uses every capability".

## §8 References

  * `docs/GENESIS_PLAN.md` §12 (phase roadmap).
  * `docs/planning/lex_implementation_plan.md` — pattern for new Lex
    DSL extensions.
  * `docs/planning/audit_remediation_plan.md` — AR.5 / AR.6 pattern for
    Action / Event index freezing.
  * `Lex/IndexRegistry.txt` — frozen action-index registry.
  * `LegalKernel/Authority/Action.lean` — action constructor
    set.

---

**End of plan.**  Phase 7 is a portfolio.  Each sub-workstream's
detailed implementation plan is lifted at landing time; this
document is the portfolio-level coordination contract.

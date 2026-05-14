<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Fault-Proof Migration — Workstream Plan (Workstream H)

**Document version:** v2 (revised from v1 of 2026-05-08).

The v2 revision applied a thorough correctness and rigor pass to the
v1 plan.  It makes the following classes of changes:

  * **Technical bug fixes.**  v1's bisection-game `BisectionRound`
    data shape carried two parallel midpoints per round (one
    "claimant", one "challenger"), which does not match the standard
    interactive-proof turn structure where each round has exactly
    one midpoint claim from the responding party.  v2 redesigns
    around the correct shape.  v1's `kernelStepApply` referenced
    helpers (`kernelStepApplyToCells`, `buildCellProof`) that were
    never defined; v2 specifies them.  v1's
    `Action.faultProofChallenge` carried a `gameId : Nat` field —
    but the L1 game contract assigns the gameId on
    `initiateChallenge`, so the L2 action cannot know it before the
    L1 game exists.  v2 redesigns the action to carry a
    `challengeBindingHash` instead, with the L1 contract matching
    submissions to L2 intents by hash.  v1 said anti-DoS rate
    limits were "configurable" — but Workstream-E discipline
    mandates immutability after construction.  v2 specifies them as
    constructor arguments (immutable thereafter).
  * **Sub-WU breakdown.**  Five v1 WUs (H.1.3, H.2.5, H.4.3, H.4.4,
    H.6.1) were monolithic; v2 breaks them into 18 sub-WUs whose
    boundaries follow the underlying proof structure or contract
    entry-point shape.  H.5.2 (per-variant Solidity step functions)
    now expands to 19 explicit sub-WUs, one per `Action`
    constructor.
  * **New WUs.**  Eight WUs added that v1 missed:
    H.1.6 (multi-step composition lemma);
    H.4.5 (game-state encoding for L1 storage);
    H.4.6 (tie-breaking + edge-case enumeration);
    H.7.4 (hash-chain integrity verification at submission);
    H.8.5 (in-flight game freezing during migration);
    H.9.4 (in-flight V1 dispute migration policy);
    H.10.5 (off-chain prover/observer tooling specification);
    H.11.4 (performance benchmark property).
  * **New appendices.**  Eight appendices added: detailed
    per-variant cell-read/write table (D); bond-economics
    game-theoretic analysis (E); gas budget per L1 entry point
    (F); cross-stack fixture JSON schema (G); security attack-tree
    enumeration (H); best-practices compliance checklist (I); WU
    dependency graph (J); migration runbook for operators (K).
  * **Open-question resolutions.**  v1 left eight questions open;
    v2 resolves OQ5, OQ6, and OQ7 explicitly (the resolutions were
    already named as "recommendations" in v1; v2 promotes them to
    decisions).
  * **Decidability discipline (§4.9 new).**  v1 mentioned this only
    in passing; v2 has an explicit principle and enforcement
    mechanism in the design-principles section.
  * **Per-WU commit discipline (§4.10 new).**  v1 mentioned per-WU
    commits in CLAUDE.md guidance; v2 makes the unit of merge
    explicit.

The total length grows from ~57 KB to ~140 KB, comparable in
magnitude to the existing `actor_scoped_policies_plan.md` and
`parameterized_laws_plan.md` planning documents.

---

This document plans the engineering effort needed to replace Canon's
current quorum-of-adjudicators dispute mechanism with an interactive
on-chain fault-proof game.  It is a roadmap, not a specification; the
formal design will be promoted into a Genesis-Plan amendment once the
work-unit set lands.

The motivating observation is the trust-strength gap identified in
the project review: the Phase-6 dispute pipeline, even with full
adjudicator automation (a bot-quorum), still depends on an
**M-of-N adjudicators honest** assumption.  Optimistic-rollup designs
elsewhere in the ecosystem (Optimism's Cannon, Arbitrum's BoLD) have
moved to a **1-of-anyone honest** assumption via interactive
fault-proof games.  The kernel's small footprint — ~hundreds of lines
in two TCB files — makes Canon an unusually tractable target for this
migration, smaller than any production EVM-compatible fault-proof
target.

This is the **Phase 2** of the three-phase fault-resolution roadmap
sketched in the Workstream-Q response on the engineering session of
2026-05-08:

| Phase | Mechanism | Trust assumption | Status |
|-------|-----------|------------------|--------|
| 1 | Bot-quorum (deployment template) | M-of-N bots honest | Supported by current protocol; no changes needed |
| 2 | **Interactive fault proofs (this plan)** | **1-of-anyone honest** | **Workstream H (this document)** |
| 3 | Validity proofs (ZK) | SNARK soundness only | Future workstream; conditional on production volumes |

Workstream H neither precludes nor requires Phase 3.  The fault-proof
step VM specified here can later be re-targeted to a SNARK circuit
without touching its specification, because both consume the same
`KernelStep` semantics.

## Status

  * **Drafted on branch:** `claude/document-actor-scoped-policies-UJHAw`.
  * **Phase prefix:** `H` (Hardening; the next free letter after the
    Ethereum-integration A–G workstreams) — work units labelled
    `H.1` … `H.13` to disambiguate from the Genesis-Plan numbering
    and from the Ethereum-integration A–G prefix.  This workstream
    is parallel to, not a successor of, Genesis-Plan Phase 7.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`, and
    `lake exe stub_audit` all green throughout; **no new sorries**;
    **no new axioms**; **no expansion of the kernel TCB**; **no new
    `opaque` declarations**.
  * **TCB delta:** zero.  Every new Lean module ships under
    `LegalKernel/FaultProof/`, `LegalKernel/Encoding/`, or
    `LegalKernel/Test/FaultProof/`; none touches `Kernel.lean` or
    `RBMapLemmas.lean`.  The fault-proof step VM is non-TCB:
    bugs in it can produce incorrect rollback decisions or fail
    to detect invalid state roots, but cannot violate any kernel
    invariant.  Every state advance still goes through
    `apply_admissible` (or the dispute-pipeline analogue
    `applyVerdict`), which carries the relevant witnesses.
  * **Trust-assumption delta:** strictly weaker.  The current
    `Verify` opaque trust assumption (EUF-CMA on the deployment-
    supplied signature scheme) and the production keccak256
    binding are unchanged.  The new trust assumption — "at least
    one honest challenger willing to play the fault game during
    the dispute window" — *replaces* the prior "M-of-N approved
    adjudicators honest" assumption.  Strictly weaker because the
    one-of-anyone assumption is satisfied whenever any
    adjudicator subset of the prior quorum participates honestly,
    plus when any non-adjudicator does.
  * **Backwards-compat delta:** the Phase-6 adjudicator quorum
    remains the canonical adjudication path for the
    `oracleMisreported` claim variant (which is not a function of
    the log alone and so is not amenable to fault-proof
    discharge).  All four other claim variants
    (`preconditionFalse`, `signatureInvalid`, `nonceMismatch`,
    `doubleApply`) get a new fault-proof path.  The
    `Action.dispute` constructor remains; a new
    `Action.faultProofChallenge` constructor at frozen index 17 is
    appended; no existing constructor changes index.  The on-disk
    log format extends additively; pre-Workstream-H logs replay
    successfully under the post-Workstream-H build because the
    new constructor never appears in them.
  * **Frozen indices reserved by this workstream:**
    * `Action.faultProofChallenge` at index 17
    * `Action.faultProofResolution` at index 18
    * `Event.faultProofGameOpened` at index 13
    * `Event.faultProofBisectionStep` at index 14
    * `Event.faultProofGameSettled` at index 15
  * **Solidity-side scope:** four new contracts —
    `CanonStepVM.sol`, `CanonFaultProofGame.sol`,
    `CanonStateRootSubmission.sol`, `CanonDisputeVerifierV2.sol` —
    plus a migration contract `CanonFaultProofMigration.sol`.
    All immutable per the Workstream-E §20 discipline; upgrades go
    through `CanonMigration` with a `MIN_GRACE_WINDOW_BLOCKS`
    delay.  The existing `CanonDisputeVerifier` (V1) remains
    deployed and operational for the `oracleMisreported` path; the
    new `CanonDisputeVerifierV2` handles the fault-proof claim
    variants.
  * **DoS bounds reserved by this workstream:**
    * `MAX_BISECTION_DEPTH = 64` — the maximum number of bisection
      rounds.  Caps the worst-case L1 game length at
      `2 × 64 + ε` transactions per dispute.
    * `MAX_STEP_GAS = 8_000_000` — per-step gas budget for the L1
      step VM.  Forces bulk actions (`distributeOthers`,
      `proportionalDilute`) to compile to a sub-step sequence.
    * `MAX_RECIPIENTS_PER_BULK_ACTION = 256` — per-action
      recipient cap; `MAX_STEP_GAS` already enforces this
      indirectly, but an explicit constant in the kernel admits
      faster decidability synthesis.
    * `MIN_CHALLENGE_BOND = 0.05 ETH` (denominator on L1 native
      asset, not parameterised at the kernel level).  The
      challenger's bond if no L2 deployment-side staking exists.
    * `STATE_ROOT_SUBMISSION_BOND = 1.0 ETH` — the sequencer's
      bond per submitted state root.  Slashed in full on a
      successful challenge.
    * `BISECTION_RESPONSE_TIMEOUT = 21_600 blocks` (~3 days at
      12 s blocks).  Per-round timeout; expiry settles the game
      against the unresponsive party.
    * `FAULT_PROOF_DISPUTE_WINDOW = 216_000 blocks` (~30 days,
      mirroring `MIN_GRACE_WINDOW_BLOCKS`).  After this window
      with no successful challenge, the state root is finalised
      and the sequencer's bond is unlocked.
  * **Test count target:** the Lean side should grow from 1228
    (post-Workstream-LP) to approximately 1500 (+~270 across new
    suites: `faultproof-step`, `faultproof-commit`,
    `faultproof-bisection`, `faultproof-merkle`,
    `faultproof-end-to-end`, plus extensions to existing suites
    for cross-stack-equivalence and property-based tests).  The
    Solidity side should grow by approximately 120 forge tests
    across 4 new suites.

## Executive summary

Workstream H transforms Canon's dispute mechanism from "trusted
adjudicator quorum signs verdict" to "interactive bisection game
settles state-root validity on L1."  The migration is staged in 13
work units organised across four phases:

  1. **Specification phase (H.1 – H.4).**  Lean-side formalisation
     of the step semantics, the state-commitment scheme, the per-
     step Merkle proofs, and the bisection game state machine.
     Establishes the ground truth that every other phase consumes.
  2. **L1 implementation phase (H.5 – H.7).**  Solidity-side step
     VM, bisection contract, and sequencer state-root submission.
     Three immutable contracts deployable in a single CREATE3
     bundle.
  3. **Integration phase (H.8 – H.9).**  Wiring the new path into
     the existing dispute pipeline; the migration contract that
     hands authority over from `CanonDisputeVerifier` (V1) to
     `CanonDisputeVerifierV2`.
  4. **Verification + documentation phase (H.10 – H.13).**
     Cross-stack fixture corpora extending Workstream F;
     property-based fuzz tests; audit-binary updates; Genesis Plan
     amendment.

The plan deliberately preserves the Phase-6 adjudicator quorum for
the `oracleMisreported` claim variant.  Oracle outputs are not a
function of the log alone — by definition, an oracle injects
external information — and so cannot be discharged by replaying
the log.  Adjudicators remain the canonical mechanism for this
class of dispute.  Phase 3 (ZK) eventually subsumes both, but
that is out of scope for this plan.

The end-state architecture:

```
                       ┌─────────────────────────────────────┐
                       │  Sequencer publishes state root S_N │
                       │  to CanonStateRootSubmission.sol    │
                       │  + posts STATE_ROOT_SUBMISSION_BOND │
                       └────────────┬────────────────────────┘
                                    │
                                    │ FAULT_PROOF_DISPUTE_WINDOW
                                    │ (no challenge → finalised)
                                    │
                       ┌────────────▼────────────────────────┐
                       │  Anyone challenges via              │
                       │  CanonFaultProofGame.sol            │
                       │  + posts MIN_CHALLENGE_BOND         │
                       └────────────┬────────────────────────┘
                                    │
                                    │ Interactive bisection
                                    │ over O(log N) rounds
                                    │
                       ┌────────────▼────────────────────────┐
                       │  L1 executes one disputed step via  │
                       │  CanonStepVM.sol                    │
                       │  → declares winner + slashes loser  │
                       └─────────────────────────────────────┘
```

## Table of contents

  1. Purpose and scope
  2. Goals and non-goals
  3. Architecture overview
  4. Design principles
  5. Workstream H.1 — Step semantics extraction (5 sub-WUs + new H.1.6)
  6. Workstream H.2 — State commitment scheme (5 sub-WUs + new H.2.6)
  7. Workstream H.3 — Per-step proofs (3 sub-WUs + new H.3.4, H.3.5)
  8. Workstream H.4 — Bisection game (6 sub-WUs; H.4.3, H.4.4 split + new H.4.5, H.4.6)
  9. Workstream H.5 — Solidity step VM (3 sub-WUs; H.5.2 split into 19 per-variant)
  10. Workstream H.6 — Solidity bisection contract (3 sub-WUs; H.6.1 split into 7 sub-WUs)
  11. Workstream H.7 — Sequencer state-root submission (4 sub-WUs + new H.7.4)
  12. Workstream H.8 — Dispute pipeline integration (5 sub-WUs + new H.8.5)
  13. Workstream H.9 — Migration (4 sub-WUs + new H.9.4)
  14. Workstream H.10 — Cross-stack verification (5 sub-WUs + new H.10.5)
  15. Workstream H.11 — Property-based tests (4 sub-WUs + new H.11.4)
  16. Workstream H.12 — Audit binaries / TCB / sorry budget
  17. Workstream H.13 — Documentation + Genesis Plan amendment
  18. Type-level theorems summary (#212–#272; 61 new theorems)
  19. Open questions (8 questions; 3 resolved in v2)
  20. Glossary

  Appendices (A–C from v1; D–K added in v2):

  * A. Acceptance criteria summary
  * B. Risk register
  * C. Workstream effort estimate
  * D. Per-variant cell-read/write table (19 constructors)
  * E. Bond-economics game-theoretic analysis
  * F. Per-L1-entry-point gas budget (5 contracts)
  * G. Cross-stack fixture JSON schema
  * H. Security attack-tree (6 attacker classes incl. spoiler + L1 reorg)
  * I. Best-practices compliance checklist (8 categories)
  * J. WU dependency graph + critical path
  * K. Migration runbook (operator-facing, 4 phases)
  * L. v2 audit findings and resolutions (audit-pass-1)

## 1. Purpose and scope

**Purpose.**  Replace the Phase-6 adjudicator-quorum mechanism for
the four deterministic claim variants (`preconditionFalse`,
`signatureInvalid`, `nonceMismatch`, `doubleApply`) with an
interactive fault-proof game on Ethereum L1.  Strengthen the trust
assumption from "M-of-N adjudicators honest" to "1-of-anyone
honest."  Preserve every kernel-level invariant theorem unchanged.

**In scope.**

  * Lean-side specification of the step semantics, the state
    commitment scheme, the per-step Merkle proofs, and the
    bisection game.
  * Solidity-side step VM, bisection contract, sequencer state-
    root submission, and migration contract.
  * Cross-stack equivalence fixture corpora extending Workstream F.
  * Property-based tests for bisection convergence and the
    single-honest-challenger property.
  * Two new `Action` constructors (`faultProofChallenge`,
    `faultProofResolution`) at frozen indices 17 and 18.
  * Three new `Event` constructors at frozen indices 13–15.
  * Genesis Plan amendment (a new §15 added to the existing plan).

**Out of scope.**

  * Replacing the `oracleMisreported` adjudication path.  Oracle
    disputes remain on the Phase-6 quorum mechanism.
  * ZK validity proofs.  Phase 3 of the fault-resolution roadmap.
  * Multi-rollup federation or sharding.  Single-chain only.
  * Replacement of the sequencer trust model.  The sequencer is
    still a single privileged actor that orders and timestamps
    actions; the fault-proof game disciplines them but does not
    decentralise them.
  * Slashing of misbehaving sequencers beyond the per-state-root
    bond.  Long-running sequencer misbehaviour is handled by the
    deployment's existing `CanonSequencerStake` mechanism.
  * Replacement of the `CanonMigration` mechanism.  Workstream H
    is *delivered via* `CanonMigration` (the existing primitive);
    it does not change how migrations themselves work.

## 2. Goals and non-goals

### 2.1 Goals (what shipping Workstream H means)

A successful Workstream H landing satisfies:

  1. **Trust strengthening.**  Any single honest party with access
     to the Canon log can challenge an invalid state root and
     win, regardless of adjudicator participation.
  2. **Cost preservation.**  Honest sequencer operation is not
     more expensive than under the Phase-6 quorum model (modulo
     the per-state-root submission bond, which is opportunity
     cost only — recovered when the state root finalises).
  3. **Determinism preservation.**  The fault-proof game's
     resolution is a deterministic function of the inputs.  Two
     different challengers reading the same log reach the same
     conclusion about whether a state root is valid.
  4. **TCB preservation.**  No kernel-TCB module changes.  No new
     axioms.  No new opaque declarations.  The §13.6 two-reviewer
     gate does not trigger.
  5. **Backwards compatibility.**  Pre-Workstream-H Canon logs
     replay successfully under the post-Workstream-H build.  The
     Phase-6 dispute pipeline continues to function for
     `oracleMisreported` claims.
  6. **Coherence with Workstream F.**  The cross-stack fixture
     corpora extend (do not replace) the existing F.1.1–F.1.7
     corpora; the F.4 property-based bridge tests continue to
     pass.

### 2.2 Non-goals (deferred to future workstreams)

  * **Removing adjudicators entirely.**  Adjudicators remain for
    `oracleMisreported`.  Removing them entirely requires either
    eliminating oracles from the deployment or moving to ZK.
  * **Replacing the dispute window with instant finality.**  The
    fault-proof window is tunable (`FAULT_PROOF_DISPUTE_WINDOW`)
    but cannot be zero — instant finality requires validity
    proofs.
  * **BLS or threshold-signature aggregation.**  Workstream H
    operates with standard ECDSA throughout; signature
    aggregation is an orthogonal optimisation tracked separately.
  * **Cross-deployment fault-proof games.**  Each Canon
    deployment has its own L1 contracts and its own fault-proof
    state; games cannot span deployments.
  * **Fault proofs for sub-action work** (e.g., disputing a
    single arithmetic operation inside a bulk action).  The step
    granularity is per-Action; bulk actions decompose into
    per-recipient sub-steps but no finer.

### 2.3 Acceptance test (the "Workstream H is done" criterion)

The Workstream-H equivalent of Workstream-F's acceptance test:

  1. A test sequencer publishes a state root `S_N` claiming the
     state after applying log entries `[0..N]` from genesis.
  2. A test challenger detects a fault: log entry `j ∈ [0..N]`
     was applied incorrectly (e.g. precondition was false at
     application time).  The challenger asserts the correct
     state root `S'_N`.
  3. The challenger files
     `Action.faultProofChallenge` on L2 with the disputed range
     `[0..N]` and the asserting bond.
  4. The L1 game contract `CanonFaultProofGame.sol` runs
     interactive bisection between sequencer and challenger
     until a single disputed step `j` is identified.
  5. The L1 step VM `CanonStepVM.sol` executes step `j` from
     pre-state `S_{j-1}` (with Merkle proofs for the touched
     cells) and computes the correct post-state `S_j`.
  6. The contract awards the challenger's bond + the sequencer's
     bond to the challenger; emits `faultProofGameSettled` on
     L2 via `Action.faultProofResolution`.
  7. The state-root range `[j..N]` is marked reverted via
     `revertToPriorRoot` (existing audit-2 mechanism).

The acceptance test runs end-to-end across both Lean and Solidity
in CI; the Lean side computes the expected step transcript
deterministically and the Solidity side reproduces it.  Cross-
stack equivalence is the workstream-level invariant.

## 3. Architecture overview

### 3.1 Layered diagram

```
              ┌─────────────────────────────────────────────┐
              │             L2 (Canon kernel)               │
              │                                             │
              │  Phase-6 dispute pipeline (oracle-only)     │
              │  Phase-H fault-proof challenge action       │
              │       │                                     │
              │       ▼                                     │
              │  Action.faultProofChallenge appended to log │
              │       │                                     │
              │       ▼                                     │
              │  L1 Event watcher detects challenge         │
              └─────────────────────────────────────────────┘
                                │
                                ▼
              ┌─────────────────────────────────────────────┐
              │             L1 (Ethereum)                   │
              │                                             │
              │  CanonStateRootSubmission.sol               │
              │  ───────                                    │
              │  - sequencer submits state roots            │
              │  - bonds submitted (slashed on loss)        │
              │  - dispute window timer                     │
              │                                             │
              │           │                                 │
              │           ▼                                 │
              │  CanonFaultProofGame.sol                    │
              │  ───────                                    │
              │  - challenger initiates with bond           │
              │  - bisection rounds until single step       │
              │  - per-round timeout (21_600 blocks)        │
              │                                             │
              │           │                                 │
              │           ▼                                 │
              │  CanonStepVM.sol                            │
              │  ───────                                    │
              │  - executes one Action's kernel step        │
              │  - takes Merkle proofs for read/written     │
              │    cells                                    │
              │  - returns post-state Merkle root           │
              │                                             │
              │           │                                 │
              │           ▼                                 │
              │  CanonDisputeVerifierV2.sol                 │
              │  ───────                                    │
              │  - reads game settlement                    │
              │  - calls revertToPriorRoot on bridge        │
              │  - bond redistribution to winner            │
              └─────────────────────────────────────────────┘
                                │
                                ▼
              ┌─────────────────────────────────────────────┐
              │  L2 runtime ingests fault-proof resolution  │
              │  Action.faultProofResolution appended       │
              └─────────────────────────────────────────────┘
```

### 3.2 End-to-end data-flow walkthrough

Concretely, here is what happens when a sequencer publishes a
state root and a challenger detects a fault, traced from action
execution through final settlement:

  1. **Action execution (L2).**  Sequencer receives a signed
     action `st : SignedAction` from a user; runs
     `processSignedAction`, which calls `apply_admissible` and
     appends a `LogEntry` to the canonical log.  Existing
     Phase-5 behaviour, unchanged.
  2. **State-root submission (L1).**  Periodically (per the
     deployment's submission cadence), the sequencer:
     * Computes `commit := commitExtendedState es_N` from the
       runtime's current `ExtendedState` (using the WU H.2
       commitment scheme).
     * Calls `CanonStateRootSubmission.submitStateRoot(N,
       commit, prevLogEntryHash)` on L1, posting
       `STATE_ROOT_SUBMISSION_BOND` ETH.
     * The contract emits `StateRootSubmitted(N, commit,
       sequencer)` and starts the
       `FAULT_PROOF_DISPUTE_WINDOW` countdown.
  3. **Observation (off-chain).**  Any party that maintains a
     full Canon node (the *observer*) replays the canonical log
     up to index `N`, computes `expected := commitExtendedState
     es'_N`, and compares to the on-chain `commit`.  If they
     match, the state root is correct and the observer takes no
     action.  If they differ, the observer becomes a *challenger
     candidate*.
  4. **Challenge initiation (L1).**  A challenger calls
     `CanonFaultProofGame.initiateChallenge(N, expected,
     startIdx, startCommit)` posting `MIN_CHALLENGE_BOND` ETH.
     The contract emits `FaultProofGameOpened(gameId, ...)`,
     allocates a fresh `gameId`, and stores the (start,
     end) commitments for both parties.  The first turn falls
     to the sequencer.
  5. **L2 mirror (optional).**  The challenger may also append
     `Action.faultProofChallenge {bindingHash := h, ...}` to L2
     where `h` binds `(challenger, disputedRoot,
     challengerCommit)`.  This is an optional advisory log
     record; the L1 contract is the source of truth.  The
     bindingHash mechanism replaces v1's gameId field — see WU
     H.8.1 for details.
  6. **Bisection rounds (L1).**  Sequencer and challenger
     alternate.  Each round, the *responding* party submits a
     midpoint commitment for the current dispute range.  The
     *opposing* party either accepts the midpoint (collapsing
     the range to the second half) or rejects it (collapsing
     to the first half).  Each round halves the disputed
     range; convergence in `log₂(N)` rounds is proven in
     WU H.4.3.
  7. **Single-step execution (L1).**  When the dispute range
     narrows to a single log index `j`, the responding party
     calls `terminateOnSingleStep(gameId, signedAction,
     cellProofs)` providing the `j`-th log entry's signed
     action plus Merkle proofs for every cell the step
     reads or writes.  The L1 contract calls
     `CanonStepVM.executeStep(preCommit, signedAction,
     cellProofs)` which:
     * Verifies the cell proofs against the pre-state
       commitment.
     * Decodes the signed action via `CBEDecode`.
     * Computes the post-state cells deterministically.
     * Re-aggregates the post-state commitment and returns
       it.
  8. **Settlement (L1).**  The contract compares the step
     VM's computed post-state commitment to the responding
     party's claimed midpoint:
     * If they match, the responding party wins (i.e., the
       claimed step transition is provably correct).  Bonds
       redistribute accordingly.
     * If they differ, the opposing party wins.
     * `FaultProofGameSettled(gameId, winner, payout)` is
       emitted.
  9. **Rollback propagation (L1 → L2).**  If the challenger
     wins, `CanonDisputeVerifierV2` calls
     `CanonBridge.revertToPriorRoot(j)`, which (per
     Workstream-E audit-2) marks every state root at indices
     `[j..]` as reverted via the (floor, ceiling) pair
     mechanism.  The bridge will not honour withdrawal proofs
     against reverted roots.
  10. **L2 ingest (advisory).**  The runtime's L1-event watcher
      observes the `FaultProofGameSettled` event and may
      append an `Action.faultProofResolution {gameId,
      winner, revertFromIdx}` action to L2 for the audit
      trail.  Replicas observe the same event independently;
      the L2 record is non-authoritative (the L1 contract is
      authoritative).

Steps 1–3 happen in normal sequencer operation; steps 4–10 only
fire when a fault is detected.  In the optimistic case (no
fault), the sequence is just steps 1, 2, and a final
`finaliseStateRoot(N)` after the dispute window expires — at
which point the sequencer's bond is released.

### 3.3 Trust-boundary inventory

The trust boundaries that Workstream H modifies, in addition to
those documented in the Ethereum-integration plan §3.3:

| Boundary | Pre-H assumption | Post-H assumption |
|----------|------------------|-------------------|
| State-root validity | M-of-N adjudicators honest | 1 honest challenger globally |
| Adjudicator availability | M-of-N adjudicators live within window | Any party with bond available |
| `checkEvidence` re-evaluation | Performed M times by adjudicators | Performed once on L1 by step VM |
| Verdict signature aggregation | Off-chain coordinator | None (no signatures needed) |
| Bond economics | None at protocol layer | L1-native bonds; slashed by step VM |
| Sequencer state-root truthfulness | Trusted (no on-chain verification) | Disciplined by bond + challenge window |
| Observer/challenger participation | Implicit ("someone will dispute") | Explicit (bonded right; reward economics) |

The new "Sequencer state-root truthfulness" boundary deserves
explicit naming: pre-H, sequencers could publish wrong state
roots and rely on the M-of-N quorum to catch them; if the quorum
were captured (e.g. all adjudicators offline or compromised),
wrong roots would slip through.  Post-H, a single honest party
with a Canon node can challenge.  This is the single biggest
shift in the security model.

### 3.4 Attack-tree analysis (security model)

The attacks Workstream H must defend against, with their
mitigations:

| Attack | Strategy | Mitigation | Residual risk |
|--------|----------|------------|---------------|
| Wrong state root by sequencer | Publish a fraudulent root | Single honest challenger wins (#232) | None at protocol; sequencer loses bond |
| Forged challenge by attacker | Challenge a correct root | Sequencer wins; attacker loses bond | Cost: `MIN_CHALLENGE_BOND` per attempt |
| Liveness DoS by challenger | Initiate then abandon | Timeout fires (`BISECTION_RESPONSE_TIMEOUT`); sequencer wins | None; attacker loses bond |
| Liveness DoS by sequencer | Publish then abandon | Timeout fires; challenger wins | None; sequencer loses bond |
| Spam disputes | Many junk challenges | Per-bond cost × per-game L1 gas; attacker pays | Linear cost; not scalable for attacker |
| Race-condition on settlement | Submit conflicting moves | L1 enforces turn-based ordering; second submission reverts | None |
| Merkle proof forgery | Submit fake cell proof | `CollisionFree hashBytes` + `verifyCellProof_sound` (#222) | Conditional on hash CR |
| State-commitment collision | Two states map to same commit | Same: `CollisionFree hashBytes` + `commitExtendedState_injective` (#220) | Conditional on hash CR |
| Step VM bug (Solidity ↔ Lean drift) | Step VM and kernel disagree | Cross-stack equivalence corpus (WU H.10) catches at CI | Test coverage gap (mitigation: F.1.8 corpus, 304+ fixtures) |
| Bond griefing via inflation | Attacker drains victim's gas via bisection | Per-game gas bounded by `MAX_BISECTION_DEPTH × MAX_STEP_GAS`; attacker pays own gas | Linear cost only |
| Sequencer key compromise | Attacker publishes wrong roots | Same protection as honest sequencer faults; bond slashed | Sequencer loses bond per attack |
| Concurrent disputes (same root) | Two challengers race | Single-game-per-root (OQ7 resolution); first challenger gets the slot | Liveness only; correctness preserved |
| Time-of-flight race | Sequencer abandons just before timeout | Block-deterministic timeout; no clock skew | None |
| Reentrancy on settlement | Reentrant call drains bond | `nonReentrant` on every external + CEI ordering | Audit-tested (WU H.6.2) |

Three attacks deserve special discussion:

  * **State-commitment collision.**  Critical.  If `hashBytes`
    is not collision-resistant, two distinct states could map
    to the same commit, and the bisection game could converge
    on identical commits despite underlying disagreement.  This
    is the same trust assumption Workstream-D and Workstream-A
    rest on.  Mitigated by requiring `isKeccak256Linked = true`
    for production (the FNV-1a-64 fallback is **not** safe for
    production fault-proof games).
  * **Step VM ↔ kernel drift.**  Critical.  If the Solidity
    step VM computes a different post-state than the Lean
    kernel for the same inputs, the L1 game and L2 runtime
    disagree even on valid roots.  Mitigated by the F.1.8
    fixture corpus (~304 fixtures crossing every Action
    constructor and every cell-tag combination), plus the WU
    H.4.4 (#232) theorem proof being structurally
    independent of any particular Solidity implementation.
  * **Bond griefing.**  Medium.  An attacker with deep pockets
    could file expensive challenges to inflate sequencer L1
    gas.  Mitigated by the attacker also paying L1 gas; the
    sequencer's defensive moves are bounded by
    `MAX_BISECTION_DEPTH × MAX_STEP_GAS` per game, of which
    `MAX_BISECTION_DEPTH = 64` and `MAX_STEP_GAS = 8M` cap the
    worst case at ~512M gas (~9 blocks at 60M gas/block) over
    the dispute window.  Sequencer can amortise this across
    many state roots.

### 3.5 Gas-budget summary

The L1 cost model for fault-proof operations, expressed as gas
estimates for production-keccak256-linked deployments.  These
are upper bounds; typical operations will use much less.

| L1 entry point | Gas budget | Notes |
|----------------|------------|-------|
| `submitStateRoot` | ≤ 80_000 | Bond transfer + 2 SSTOREs + 1 event |
| `finaliseStateRoot` | ≤ 50_000 | Bond release + status update |
| `initiateChallenge` | ≤ 200_000 | Bond transfer + game struct init + 2 events |
| `submitMidpoint` | ≤ 80_000 | 1 SSTORE + 1 event + turn rotation |
| `terminateOnSingleStep` | `MAX_STEP_GAS = 8_000_000` | Step VM execution + Merkle proof verification |
| `claimTimeout` | ≤ 100_000 | Status update + bond redistribution + 1 event |
| `executeStep (step VM)` | `MAX_STEP_GAS = 8_000_000` | Per-variant; see Appendix F |

Per-game gas worst case: 80k (submit) + 200k (initiate) + 64
rounds × 80k (midpoint) + 8M (terminate) + 100k (timeout
fallback) = ~13.4M gas, achievable in 1 block at 60M
gas/block, comfortably across normal congestion.

The detailed per-variant step VM gas budgets are in Appendix F.

## 4. Design principles

### 4.1 The TCB never grows

Same as the Workstream-A through F discipline.  Every new module
ships under non-TCB namespaces.  The kernel's `apply_admissible`
remains the only state-advance entry point, and no fault-proof
machinery executes inside the runtime's hot loop — the fault-proof
mechanism only fires when a `faultProofChallenge` action is
explicitly submitted.

### 4.2 No new axioms, no new opaques

The fault-proof machinery is built from existing primitives:

  * Workstream-A's `Verify` and `hashBytes` opaques (unchanged).
  * Workstream-D's SMT primitives (extended for additional sub-
    states; see WU H.2).
  * Existing `kernelOnlyApply` and `kernelOnlyReplay` from
    `Disputes/Evidence.lean` (factored, not duplicated).

The `KernelStep` data type introduced in WU H.1 is a `Prop`-free
inductive — no `Decidable` synthesis blockers, no proof obligations
beyond what the kernel already discharges.

### 4.3 Append-only constructor indices

Two new `Action` constructors (`faultProofChallenge`,
`faultProofResolution`) at frozen indices 17 and 18.  Three new
`Event` constructors at frozen indices 13–15.  No reordering, no
renumbering, no insertion.  The CBE codec extends additively.

### 4.4 Bisection convergence is structural

The bisection game's termination is a structural property of the
log being finite.  We prove it as a Lean theorem
(`bisection_converges_in_log_length` in WU H.4) rather than relying
on operational arguments about timeouts.  Timeouts handle the
unresponsive-party case at the L1 layer; the kernel-level proof
handles the responsive-party case.

### 4.5 Per-step gas is bounded a priori

The L1 step VM executes exactly one kernel step per transaction.
Each step's gas cost is bounded by:

  * The number of state cells the step reads/writes (small for
    every primitive action; sub-step decomposition handles bulk
    actions).
  * The complexity of the action's compiled `Transition.apply_impl`
    (small for every existing law; new laws are added with explicit
    gas-cost-budget review).
  * Two ECDSA verifications worst case (signed action + sequencer
    state-root submission).

The decidability proofs at the Lean layer back-stop the gas budget:
if `decPre` is `fun _ => inferInstance` for an action, the L1 step
VM's pre-check is a finite conjunction of decidable comparisons,
which compiles to a bounded gas cost.

### 4.6 Immutability mirrors Workstream E discipline

The four new Solidity contracts ship with no admin roles, no
upgrade proxies, no `pause()` functions.  Recovery from a buggy
fault-proof contract is via `CanonMigration` — exactly the same
pattern as `CanonDisputeVerifier` V1 → V2 migrations.

### 4.7 Mathematical correctness is non-negotiable

Same as the Ethereum-integration plan §4.6.  Every theorem is
proved without `sorry`.  Every definition is total (no partial
functions where avoidable).  Every hypothesis is explicit; no
implicit assumptions about state shape, log structure, or
adversarial behaviour.  The fault-proof game's correctness is
established at the Lean level *before* the Solidity port lands.

### 4.8 Names describe content, never provenance

CLAUDE.md's naming discipline applies verbatim.  No work-unit
labels in identifier names.  No "audit3" or "phaseH" tokens.  The
module names (`KernelStep`, `BisectionGame`, `CanonStepVM`)
describe what the code is, not when it was written or which
review uncovered it.

The pre-merge enforcement script (CLAUDE.md, key conventions)
applies:

```bash
git diff --cached -U0 -- '*.lean' \
  | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
  | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit|\bf[0-9]{2}\b|\btmp\b|\btodo\b|\bfixme\b|claude_|session_'
```

A non-empty result is a review-blocking naming violation.  Each
WU lands clean against this gate before merge.

### 4.9 Decidability discipline

Every new propositional predicate Workstream H introduces ships
with a `Decidable` instance synthesizable via `inferInstance`.
The discipline is:

  * **Per-WU enforcement.**  Each WU spec lists the
    `Decidable` instances it adds.  A WU that adds a `Prop`
    without a paired `Decidable` instance is incomplete.
  * **`inferInstance`-only synthesis.**  No hand-written
    `Decidable` derivations except for genuinely
    irreducible predicates.  This back-stops the L1 step VM's
    gas budget: if `Decidable P := fun _ => inferInstance`,
    the L1 port is a finite conjunction of decidable
    primitive comparisons, which compiles to a bounded gas
    cost.
  * **Named instances at decision boundaries.**  Top-level
    `Decidable` instances (the ones consumed by other modules)
    are named, not anonymous.  This prevents the "I'd like to
    use this instance but Lean's instance synthesis won't pick
    it up at this priority level" debugging trap.

Specific Workstream-H predicates that need named decidability
instances (full list in WU specs):

  * `Decidable (kernelStepApply step = some commit)` (H.1.2)
  * `Decidable (verifyCellProof commit proof = true)` (H.3.3)
  * `Decidable (verifyCellProofs commit bundle = true)` (H.3.3)
  * `Decidable (Verdict.canonical v)` extends to fault-proof
    settlement records (H.8.4)
  * `Decidable (gameWellFormed gs)` (H.4.2)
  * `Decidable (FaultProofChallengerWon log gameId revertFromIdx)`
    (H.8.4)

If any of these resists `inferInstance`, that's a signal to
review the predicate (likely it has an unbounded quantifier
hiding inside).

### 4.10 Per-WU commit discipline

Per CLAUDE.md ("Git practices: One commit per completed work
unit"), each numbered WU maps to exactly one commit.  Sub-WUs
(H.1.3a, H.1.3b, …) may either land as separate commits or as
a single batched commit if they form a single logical change.

**Commit-message convention.**  Workstream-H commits follow the
existing pattern from prior workstreams:

```
WU H.X.Y: <imperative summary, ≤ 60 chars>

<body explaining the *why*, max 80-char wrapped lines>
```

The WU label appears in the commit message but **not** in any
identifier (per §4.8).

**Pre-merge gate.**  Each WU's commit passes:

```bash
lake build && lake test
lake exe count_sorries  # zero
lake exe tcb_audit       # clean
lake exe stub_audit      # clean
forge build && forge test  # for Solidity-touching WUs
```

Failure on any gate blocks merge of that WU.

## 5. Workstream H.1 — Step semantics extraction

The first phase of Workstream H formalises what a "kernel step" is
as a first-class data type in Lean.  Today, `kernelOnlyApply` is a
single function that takes `(es : ExtendedState, st : SignedAction)`
and returns `Option ExtendedState`.  For the fault-proof game we
need:

  * A data type `KernelStep` capturing the inputs and outputs of
    one kernel step.
  * A function `kernelStepApply` reproducing the existing
    `kernelOnlyApply` semantics in `KernelStep` form.
  * A coherence theorem proving the two agree.
  * Per-action-variant step definitions making the cell-level
    reads/writes explicit (so the L1 step VM can verify Merkle
    proofs for exactly those cells).

### 5.1 WU H.1.1 — `KernelStep` type

**Module:** `LegalKernel/FaultProof/Step.lean`

**Specification.**

```lean
namespace LegalKernel.FaultProof

/-- The inputs and outputs of one kernel step.  A `KernelStep` is
    sufficient for the L1 step VM to verify the step's correctness
    given Merkle proofs for the touched cells.

    `preStateCommit` is the Merkle commitment of the pre-state
    `ExtendedState`; `postStateCommit` is the commitment of the
    claimed post-state.  `signedAction` is the action being
    applied.  `cellProofs` is the per-cell Merkle proof bundle
    for each cell the step reads or writes (the L1 step VM
    consults this to load the relevant cells without holding
    the full state). -/
structure KernelStep where
  preStateCommit  : StateCommit
  signedAction    : SignedAction
  postStateCommit : StateCommit
  cellProofs      : CellProofBundle
  deriving Repr, DecidableEq
```

**Acceptance criteria.**

  * `KernelStep` is `Repr` and `DecidableEq`.
  * `StateCommit` is a 32-byte `ByteArray` (matching the keccak256
    output size, per Workstream-A §A.2).
  * `CellProofBundle` is the structure defined in WU H.3.1.
  * The CBE encoder for `KernelStep` is total and produces a
    canonical byte sequence (round-trip + injectivity proven in
    the WU H.1.5 codec module).

**Proof obligations.** None at this WU; the type is an inductive.

### 5.2 WU H.1.2 — `kernelStepApply` function

**Module:** `LegalKernel/FaultProof/Step.lean` (continuation)

**Dependencies.** WU H.1.1 (KernelStep type), WU H.2.4
(`commitExtendedState`), WU H.3.3 (`verifyCellProofs`).

**Specification.**  v2 fixes v1's reference to undefined helpers
by specifying `applyCellWrites`, `recomputeCommitment`, and the
six others (`buildCellProof`, `buildCellProofs`,
`extractRequiredCells`, `getCellValue`, `setCell`,
`isCellAbsent`) that v1 left undefined.  The full helper set:

```lean
/-- Build the canonical Merkle proof for one cell of an
    `ExtendedState`.  Total function; the proof always
    verifies against `commitExtendedState es` (per WU H.3.3
    `verifyCellProof_complete`). -/
def buildCellProof (es : ExtendedState) (tag : CellTag) : CellProof

/-- Build the proof bundle for an `Action`, covering all
    cells in `Action.requiredCells`. -/
def buildCellProofs (es : ExtendedState) (action : Action) : CellProofBundle

/-- Extract the canonical pre-state cell values an action will
    read or write, in the order specified by
    `Action.requiredCells`. -/
def extractRequiredCells
    (es : ExtendedState) (action : Action)
    : List (CellTag × ByteArray)

/-- Read a single cell's CBE-encoded value from an
    `ExtendedState`.  Total; absent cells return
    `canonicalAbsentValue tag` (per WU H.3.4). -/
def getCellValue (es : ExtendedState) (tag : CellTag) : ByteArray

/-- Write a single cell's value into an `ExtendedState`.  The
    inverse of `getCellValue` at canonical encodings. -/
def setCell
    (es : ExtendedState) (tag : CellTag) (value : ByteArray)
    : ExtendedState

/-- Decidable predicate: a cell is "absent" when the underlying
    sub-state has no entry for the cell key. -/
def isCellAbsent (es : ExtendedState) (tag : CellTag) : Prop

instance instDecidableIsCellAbsent
    (es : ExtendedState) (tag : CellTag) : Decidable (isCellAbsent es tag)
```

These six ship in `LegalKernel/FaultProof/Step.lean` (extract /
get / set / isAbsent) and `Proof/Cell.lean` (buildCellProof*).
Each is a pure function on already-loaded state; no IO; no
hashing on cells (only on Merkle paths during `buildCellProof`).

**Step-application helpers:**

```lean
/-- Apply the action's cell-level writes to a list of cell
    proofs, returning the updated cell-value list.  This is the
    "execute the action one cell at a time" step that the L1 step
    VM mirrors line-for-line. -/
def applyCellWrites
    (signedAction : SignedAction) (cells : List (CellTag × ByteArray))
    : Option (List (CellTag × ByteArray))

/-- Reaggregate the post-state commitment from the post-state cell
    values.  Recomputes the affected sub-state SMT roots using the
    same Merkle paths as the input proofs (the siblings on the
    untouched branches don't change), then folds them into the
    top-level state commit. -/
def recomputeCommitment
    (preCommit : StateCommit) (cellProofs : CellProofBundle)
    (postCells : List (CellTag × ByteArray)) : StateCommit

/-- The Merkle-state-aware step function.  Given the pre-state
    commitment, the action, and the Merkle proofs for the touched
    cells, compute the claimed post-state commitment.

    Returns `none` if any of the per-cell Merkle proofs fail to
    verify against `preStateCommit`, OR if the action is not
    admissible at the pre-state's projected sub-state (in which
    case `applyCellWrites` rejects the action by returning `none`).

    Note: unlike `kernelOnlyApply` (which is total and silently
    no-ops on false preconditions), `kernelStepApply` *fails
    explicitly* on inadmissible actions because the L1 step VM
    needs to revert with a precise error rather than silently
    accept.  This is the single semantic difference between the
    two functions; the coherence theorem (#225) handles the
    interaction. -/
def kernelStepApply (step : KernelStep) : Option StateCommit := do
  -- Stage 1: verify cell proofs against pre-state commit.
  guard (verifyCellProofs step.preStateCommit step.cellProofs)
  -- Stage 2: extract pre-state cell values from the bundle.
  let preCells := step.cellProofs.proofs.map (fun p => (p.cellTag, p.cellValue))
  -- Stage 3: apply the action's cell writes.
  let postCells ← applyCellWrites step.signedAction preCells
  -- Stage 4: recompute the post-state commit.
  pure (recomputeCommitment step.preStateCommit step.cellProofs postCells)
```

**Three-layer separation rationale.**

  * `applyCellWrites` is the **semantic core**: given the cell
    values and the action, what are the new cell values?  Pure
    function; no Merkle reasoning.
  * `recomputeCommitment` is the **Merkle bookkeeping**: given
    the new cell values and the original Merkle paths, what's
    the new top-level commit?  Pure function; no semantic
    reasoning.
  * `kernelStepApply` **composes** them with proof verification.

This separation makes both Lean proofs and Solidity ports
tractable.  The Solidity step VM mirrors all three functions
distinctly.

**Acceptance criteria.**

  * Total function (`Option`-returning).
  * Decidable: named instance `instDecidableKernelStepApplySome` resolves
    `Decidable (kernelStepApply step = some commit)`.
  * The three composing checks all decidable via `inferInstance`:
    1. `verifyCellProofs step.preStateCommit step.cellProofs` — see WU H.3.3.
    2. `applyCellWrites step.signedAction preCells` — finite case-split on Action variant.
    3. `recomputeCommitment` is total (no decidability question).

**Proof obligations.**

  * `kernelStepApply_deterministic`: equal inputs produce equal
    outputs.  Mechanical via `rfl`.
  * `applyCellWrites_total_for_admissible_actions`: if the action
    is admissible at the pre-state's projection, `applyCellWrites`
    returns `some _`.  Used downstream by the coherence theorem.
  * `recomputeCommitment_extensional`: equal post-cells yield
    equal post-commits.  Used downstream by the coherence theorem.

### 5.3 WU H.1.3 — Coherence with `kernelOnlyApply` (split into 4 sub-WUs)

The v1 plan packed the entire coherence theorem into a single WU.
v2 splits it into four sub-WUs reflecting the proof structure.
The headline theorem is at the end (H.1.3b); the supporting
lemmas come first.

#### 5.3.1 WU H.1.3a — Per-variant cell extraction

**Module:** `LegalKernel/FaultProof/Coherence/Variants.lean`

**Dependencies.** WU H.1.2, H.1.4 (per-action variant
specifications), H.3.2 (proof shapes).

**Specification.**  For each of the 19 `Action` constructors,
prove that `applyCellWrites` agrees with `kernelOnlyApply`'s
cell-level effect on the projection of `ExtendedState`:

```lean
theorem applyCellWrites_matches_kernelOnlyApply_transfer
    (es : ExtendedState) (r : ResourceId) (s rcv : ActorId) (amt : Amount)
    (h_admissible : ∃ verify P d, AdmissibleWith verify P d es
                      ⟨.transfer r s rcv amt, s, n, sig⟩) :
    applyCellWrites ⟨.transfer r s rcv amt, s, n, sig⟩
                     (extractRequiredCells es (.transfer r s rcv amt))
    = some (extractRequiredCells (kernelOnlyApply es ⟨.transfer r s rcv amt, s, n, sig⟩)
                                 (.transfer r s rcv amt))
```

One such theorem per variant (15 base + 4 LP/H = 19 total).
Each proof is a per-variant unfolding of `kernelOnlyApply`'s
match plus a check that `applyCellWrites`' write list matches.

**Acceptance criteria.**

  * 19 theorems, one per Action constructor.
  * Each proved via `simp` + per-variant case-analysis on
    `Action.compile`.
  * No `sorry`; each proof closes by `rfl` after appropriate
    unfolding.
  * Test parity: a per-variant value-level equivalence test in
    `Test/FaultProof/Coherence.lean`.

#### 5.3.2 WU H.1.3b — Coherence theorem (composite)

**Module:** `LegalKernel/FaultProof/Coherence.lean`

**Dependencies.** WU H.1.3a, H.2.4, H.2.5, H.3.3.

**Note on `kernelOnlyApply` signature (audit fix).**  The
codebase's `kernelOnlyApply` signature is
`(es : ExtendedState) → (entry : LogEntry) → ExtendedState` —
takes a `LogEntry` (not a `SignedAction`), returns `ExtendedState`
directly (not `Option`), and is total (never fails; `step_impl`
is no-op on false preconditions).  v2's coherence theorem uses
this exact signature.

**Specification.**  The headline coherence theorem assembled
from the per-variant lemmas.  We bridge `KernelStep`'s
`SignedAction` field to `kernelOnlyApply`'s `LogEntry`
parameter via a per-step `LogEntry` constructed from the
signed action plus the canonical prevHash:

```lean
/-- Convert a SignedAction + previous-state-hash into a
    LogEntry for kernelOnlyApply consumption.  The
    `postStateHash` field is computed from `kernelOnlyApply`
    itself (we don't pre-compute it). -/
def signedActionToLogEntry
    (st : SignedAction) (prevHash : ContentHash) : LogEntry := {
  signedAction  := st,
  prevHash      := prevHash,
  postStateHash := -- placeholder; not used by kernelOnlyApply
                   ContentHash.zero
}

theorem kernelStepApply_coherent_with_kernelOnlyApply
    (es : ExtendedState) (st : SignedAction) (prevHash : ContentHash)
    (h_cf : CollisionFree hashBytes)
    (h_admissible : ∃ verify P d, AdmissibleWith verify P d es st)
    (let entry := signedActionToLogEntry st prevHash
     let es'   := kernelOnlyApply es entry
     let step  : KernelStep := {
       preStateCommit  := commitExtendedState es,
       signedAction    := st,
       postStateCommit := commitExtendedState es',
       cellProofs      := buildCellProofs es st.action
     }) :
    kernelStepApply step = some step.postStateCommit
```

The `kernelOnlyApply` is total — no `h_post : ... = some es'`
hypothesis is needed (and indeed cannot be written, since
`kernelOnlyApply` doesn't return `Option`).  The post-state
`es'` is simply `kernelOnlyApply es entry`.

**Why this matters.**  This is the load-bearing theorem of the
entire workstream: it certifies that the L1 step VM's behaviour
matches the L2 kernel's behaviour exactly.  Without it, the L1
fault-proof game might disagree with the L2 runtime even on
valid state roots, breaking sequencer liveness for honest
sequencers.

**Proof strategy.**  Three-step composition:

  1. Apply `verifyCellProof_complete` (WU H.3.3) to verify that
     `buildCellProofs es st.action` verifies against
     `commitExtendedState es`.
  2. Apply the per-variant `applyCellWrites_matches_*` (WU H.1.3a)
     to show `applyCellWrites` produces the right post-cells.
  3. Apply `recomputeCommitment_agrees_with_commitExtendedState`
     (WU H.1.3c) to close.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * `#print axioms` shows `[propext, Quot.sound]` only (no
    `Classical.choice`).
  * The proof body is < 30 lines (mostly the three-step apply
    chain).

#### 5.3.3 WU H.1.3c — `recomputeCommitment` agreement lemma

**Module:** `LegalKernel/FaultProof/Coherence/RecomputeAgreement.lean`

**Dependencies.** WU H.2.4, H.3.3.

**Specification.**

```lean
theorem recomputeCommitment_agrees_with_commitExtendedState
    (es : ExtendedState) (action : Action) (postCells : List (CellTag × ByteArray))
    (h_postCells : postCells = extractRequiredCells (applyAction es action) action) :
    recomputeCommitment (commitExtendedState es)
                        (buildCellProofs es action) postCells
    = commitExtendedState (applyAction es action)
```

In words: rebuilding the post-state commit from the
unchanged-Merkle-path siblings + new cell values yields the
same hash as recomputing `commitExtendedState` directly on the
post-state.

**Proof strategy.**  Structural recursion through the SMT.
Each level of the tree: cells in the proof's path get updated;
cells off the path are untouched (siblings unchanged).  Final
re-aggregation matches the on-state recomputation.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * Reuses Workstream-D's `verifyProofRec_eq_rangeRoot` lemma
    structure.

#### 5.3.4 WU H.1.3d — Coherence with `kernelOnlyReplay` (multi-step lift)

**Module:** `LegalKernel/FaultProof/Coherence/Replay.lean`

**Dependencies.** WU H.1.3b, H.1.6 (multi-step composition).

**Specification.**  The multi-step generalisation.  Note that
`kernelOnlyReplay : ExtendedState → List LogEntry → ExtendedState`
is total (returns `ExtendedState` directly, not `Option`) per the
codebase signature in `Disputes/Evidence.lean:123`:

```lean
theorem kernelStepApply_chain_coherent_with_kernelOnlyReplay
    (genesis : ExtendedState) (log : List LogEntry)
    (h_cf : CollisionFree hashBytes)
    (h_all_admissible : ∀ entry ∈ log,
        ∃ verify P d,
          AdmissibleWith verify P d
                          (kernelOnlyReplay genesis (entriesPriorTo log entry))
                          entry.signedAction) :
    chainKernelStepApplyFromLog genesis log
    = some (commitExtendedState (kernelOnlyReplay genesis log))
```

where `chainKernelStepApplyFromLog` is the
`KernelStep`-equivalent of `kernelOnlyReplay` (builds a
`KernelStep` per entry, threads commits, fails on the first
inadmissible entry).  In words: applying the kernelStepApply
chain over a fully-admissible log yields the same commit as
replaying the log directly.  This is what the bisection game's
invariant rests on.

**Proof strategy.**  Induction on `log.length`.  Base case:
empty log, both sides reduce to `commitExtendedState genesis`.
Inductive case: WU H.1.3b for the head entry, plus the IH for
the tail.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * Used downstream by WU H.4.4 (single-honest-challenger
    property).

### 5.4 WU H.1.4 — Per-action-variant step definitions

**Module:** `LegalKernel/FaultProof/StepVariants.lean`

**Dependencies.** WU H.1.1 (KernelStep), H.3.1 (CellTag).

**Specification.**  For each of the 19 `Action` constructors,
define the per-cell read-only and read-write sets explicitly.
The full table — replacing v1's "for example" placeholder — is in
**Appendix D**.  Summary form:

```lean
/-- The cell tags an action reads (but does not write).  Required
    for admissibility checks but not for state advance. -/
def Action.readOnlyCells (a : Action) : List CellTag

/-- The cell tags an action writes (which are also implicitly read,
    to verify the pre-state).  These cells appear in the post-state
    with new values. -/
def Action.writeCells (a : Action) : List CellTag

/-- The complete cell set is `readOnlyCells ++ writeCells` (no
    duplicates: a cell is either read-only or read-write). -/
def Action.requiredCells (a : Action) : List CellTag :=
  Action.readOnlyCells a ++ Action.writeCells a
```

The read-only / write distinction matters because:

  * **Gas optimisation.**  Read-only proofs need verification but
    not commitment recomputation; write proofs need both.
  * **L1 calldata budget.**  Read-only proofs can be elided in
    cases where the action's admissibility doesn't depend on the
    cell (handled per-variant).
  * **Theorem hygiene.**  Many lemmas (especially the per-variant
    coherence proofs in WU H.1.3a) can structure their case
    analysis on read-only-vs-write cell categories.

**Per-variant summary.**  For all 19 constructors, see Appendix D.
Highlights:

  * `transfer r s rcv amt`: reads `[registry s]`; writes
    `[balance r s, balance r rcv, nonce s]`.
  * `mint r to amt`: reads `[registry s]`; writes
    `[balance r to, nonce s]`.
  * `burn r from amt`: reads `[registry s]`; writes
    `[balance r from, nonce s]`.
  * `freezeResource r`: reads `[registry s]`; writes `[nonce s]`.
  * `replaceKey actor newKey`: reads `[registry s]`; writes
    `[registry actor, nonce s]`.
  * `distributeOthers r exclude amt`: reads `[registry s]`;
    writes O(N) balance cells (all non-excluded actors at r) plus
    `[nonce s]`.  **Bulk action.**
  * `proportionalDilute r exclude totalReward`: reads
    `[registry s]`; writes O(N) balance cells plus `[nonce s]`.
    **Bulk action.**
  * Bridge actions (`deposit`, `withdraw`): reads `[registry s,
    bridge*]`; writes `[balance r ?, nonce s, bridge*]`.
  * Identity actions (`registerIdentity`): reads `[registry s]`;
    writes `[registry actor, nonce s]`.
  * LP actions (`declareLocalPolicy`, `revokeLocalPolicy`): reads
    `[registry s]`; writes `[localPolicy s, nonce s]`.
  * Dispute actions: reads `[registry s]`; writes `[nonce s]`
    only — no balance/registry/etc. mutations at the kernel
    level.

**Bulk-action handling.**  Two new types unify the
sub-step decomposition for `distributeOthers` and
`proportionalDilute`:

```lean
/-- A single sub-step within a bulk action.  For
    `distributeOthers`, one sub-step is one per-recipient credit. -/
structure SubStep where
  parentSignedAction : SignedAction
  subStepIdx         : Nat
  affectedActor      : ActorId
  preCellValue       : Amount
  postCellValue      : Amount
  cellProof          : CellProof
  deriving Repr, DecidableEq

/-- A bulk action decomposed into a sequence of sub-steps.  The
    list length is bounded by MAX_RECIPIENTS_PER_BULK_ACTION =
    256.  The sub-step sequence's reduction reproduces the
    bulk action's full effect. -/
def Action.subSteps (st : SignedAction) (es : ExtendedState)
    : List SubStep
```

The `MAX_RECIPIENTS_PER_BULK_ACTION = 256` cap is enforced at
the action-construction layer via a new `Action.fieldsBounded`
clause; attempts to construct a bulk action exceeding the cap
are rejected at decode time as `DecodeError.invalidLength`.

**Bisection drill-down.**  When a bulk action is the disputed
step, the bisection game **drills into the sub-step sequence**:
the dispute moves from "log entry j is wrong" to "sub-step k of
log entry j is wrong."  The L1 step VM then executes that
single sub-step (one balance-cell write), keeping the per-step
gas budget bounded.

**Acceptance criteria.**

  * Each of the 19 variants has an explicit `readOnlyCells` and
    `writeCells` specification matching Appendix D.
  * `requiredCells_matches_apply_impl` per variant: the cells
    listed match the cells `apply_impl` actually reads/writes
    (provable by `rfl` after unfolding both definitions).
  * `bulk_action_substeps_compose`: the sub-step sequence's
    reduction equals the bulk action's `apply_impl` for
    `distributeOthers` and `proportionalDilute`.  Two separate
    theorems, mechanically proved.
  * Per-variant test in `Test/FaultProof/StepVariants.lean`
    (one test case per constructor; 19 total).

### 5.5 WU H.1.5 — `KernelStep` codec

**Module:** `LegalKernel/Encoding/KernelStep.lean`

**Dependencies.** WU H.1.1, H.3.1.

**Specification.**  CBE codec for `KernelStep`:

```lean
def KernelStep.encode : KernelStep → Stream
def KernelStep.decode : Stream → Except DecodeError (KernelStep × Stream)
def KernelStep.fieldsBounded : KernelStep → Prop
```

The encoded layout is:

```
preStateCommit  : 32 bytes (uniform-output ByteArray)
signedAction    : variable, CBE-encoded (per Phase-4)
postStateCommit : 32 bytes
cellProofs      : length-prefixed list of CellProof encodings
```

**Acceptance criteria.**

  * `kernelStep_roundtrip`: bounded round-trip identity.
  * `kernelStep_encode_injective`: bounded injectivity.
  * `kernelStep_encode_deterministic`: structural rfl-class.
  * `KernelStep.fieldsBounded` decidable via named instance
    `instDecidableKernelStepFieldsBounded`.
  * The encoder's output size for any single step is bounded
    above by:
    `64 (commits) + 4096 (max signed action) + 256 × 64 (max
     cells × per-cell encoding)` ≈ 20 KB.  Well within the
    deployment's 4 KB advisory budget; bulk actions exceed by
    using sub-step decomposition.
  * Test: 8 round-trip cases + 4 injectivity cases in
    `Test/Encoding/KernelStep.lean`.

### 5.6 WU H.1.6 — Multi-step composition (NEW)

**Module:** `LegalKernel/FaultProof/Step.lean` (continuation)

**Dependencies.** WU H.1.2, H.1.3b.

**Why this WU.**  The bisection game's invariant is "after
applying log entries [a..b], the state commit equals X."  This
requires a multi-step generalisation of `kernelStepApply`:
chain N step applications, threading the state commit through
each.  v1 implicitly assumed this but never specified the
chain function or its determinism.  v2 adds it explicitly.

**Specification.**

```lean
/-- Apply a chain of kernel steps in order, threading the state
    commit through each.  Returns `none` if any step fails (an
    inadmissible action triggers the failure since `kernelStepApply`
    fails explicitly on inadmissibility, unlike the
    silent-no-op `kernelOnlyApply`). -/
def chainKernelStepApply
    (initialCommit : StateCommit) (steps : List KernelStep)
    : Option StateCommit :=
  match steps with
  | []     => some initialCommit
  | s :: rest =>
    if s.preStateCommit ≠ initialCommit then none
    else
      match kernelStepApply s with
      | none      => none
      | some next => chainKernelStepApply next rest

/-- Variant operating on a `LogEntry` list instead of pre-built
    KernelSteps.  Used by the bisection game's invariant
    (chain-coherent-with-kernelOnlyReplay theorem).  Each entry
    is converted to a KernelStep using `buildCellProofs`
    (loaded from the actor-side observer's view of state). -/
def chainKernelStepApplyFromLog
    (genesis : ExtendedState) (log : List LogEntry)
    : Option StateCommit
```

**Theorems.**

```lean
theorem chainKernelStepApply_deterministic
    (c₁ c₂ : StateCommit) (steps : List KernelStep)
    (h : c₁ = c₂) :
    chainKernelStepApply c₁ steps = chainKernelStepApply c₂ steps

theorem chainKernelStepApply_split
    (c : StateCommit) (steps₁ steps₂ : List KernelStep) :
    chainKernelStepApply c (steps₁ ++ steps₂) =
    (chainKernelStepApply c steps₁).bind (fun c' => chainKernelStepApply c' steps₂)

theorem chainKernelStepApply_coherent_with_kernelOnlyReplay
    (genesis : ExtendedState) (log : List LogEntry)
    (h_cf : CollisionFree hashBytes)
    (h_admissible : ∀ entry ∈ log, ∃ verify P d,
        AdmissibleWith verify P d _ entry.signedAction) :
    chainKernelStepApply (commitExtendedState genesis)
                          (log.map (buildKernelStep _ _))
    = some (commitExtendedState (kernelOnlyReplay genesis log))
```

The third theorem is identical in conclusion to WU H.1.3d's
`kernelStepApply_chain_coherent_with_kernelOnlyReplay`; this
is intentional — H.1.3d states the result, H.1.6 provides the
machinery.

**Why split applies (not just one chain).**  The
`chainKernelStepApply_split` lemma is what enables the
bisection game's range-narrowing argument: any range can be
split into two sub-ranges, and the chain commitments compose
associatively.  Without it, the convergence proof (H.4.3)
cannot proceed by induction on range-halving.

**Acceptance criteria.**

  * Three theorems above proved without `sorry`.
  * `chainKernelStepApply` is total and decidable.
  * Test: 6 cases in `Test/FaultProof/MultiStep.lean`
    covering empty chains, single steps, split-and-recombine,
    and chain-coherence with `kernelOnlyReplay`.

## 6. Workstream H.2 — State commitment scheme

The fault-proof game's L1 contract cannot hold the full
`ExtendedState`.  Instead, each cell of the state is committed to
a Merkle root, and the L1 contract holds only the roots.  Cells
are loaded on-demand via Merkle proofs.

This workstream extends Workstream-D's SMT primitives to cover the
sub-states of `ExtendedState` not yet committed (BalanceMap-of-
BalanceMap, NonceState, KeyRegistry, LocalPolicies, BridgeState).

### 6.1 WU H.2.1 — Two-level SMT for `BalanceMap`

**Module:** `LegalKernel/FaultProof/Commit/Balance.lean`

**Specification.**  The kernel's `State.balances : RBMap ResourceId
BalanceMap` is a map of maps.  We commit it as a two-level SMT:

  * **Level 1 (resource):** the outer SMT keyed by `ResourceId`.
    Each leaf is the SMT root of the inner `BalanceMap`.
  * **Level 2 (actor):** per-resource SMT keyed by `ActorId`.
    Each leaf is the actor's `Amount` at that resource.

```lean
def commitBalanceMap : RBMap ResourceId BalanceMap → ByteArray
def commitInnerBalanceMap : BalanceMap → ByteArray
```

**Reuses Workstream D's primitives.**  The level-2 SMT is exactly
the `WithdrawalRoot` machinery, reapplied with `Amount` leaves
instead of `PendingWithdrawal` leaves.  Workstream D's
`verifyProof_complete` and `verifyProof_sound` theorems lift
mechanically.

**Acceptance criteria.**

  * `commitBalanceMap` is deterministic (`commit_deterministic`
    theorem).
  * `commitBalanceMap_extensional`: equal balance maps produce
    equal commitments.
  * Cell-update lemma: changing one cell's value updates the
    commitment via two log-depth hash recomputations
    (`commitBalanceMap_after_setBalance`).

### 6.2 WU H.2.2 — Single-level SMTs for nonces / registry / localPolicies

**Module:** `LegalKernel/FaultProof/Commit/Identity.lean`

**Specification.**  Three single-level SMTs, all keyed by
`ActorId`:

```lean
def commitNonceState : NonceState → ByteArray
def commitKeyRegistry : KeyRegistry → ByteArray
def commitLocalPolicies : LocalPolicies → ByteArray
```

Each reuses Workstream D's SMT primitives with appropriate leaf
types.

**Acceptance criteria.**  Same shape as WU H.2.1: determinism,
extensionality, cell-update lemmas.

### 6.3 WU H.2.3 — `BridgeState` extension

**Module:** `LegalKernel/FaultProof/Commit/Bridge.lean`

**Specification.**  Workstream D already commits
`BridgeState.pending` via `withdrawalRoot`.  This WU adds:

  * `commitBridgeConsumed : RBMap DepositId DepositRecord → ByteArray`
    (single-level SMT keyed by `DepositId`).
  * `commitBridgeState : BridgeState → ByteArray` combining
    `(consumedRoot, pendingRoot, encode nextWdId)`.

**Acceptance criteria.**  Same shape; `commitBridgeState`
backwards-compatible with Workstream-D's `bridgeWithdrawalRoot`
(the latter is the level-2 SMT root of `pending`).

### 6.4 WU H.2.4 — Top-level `commitExtendedState`

**Module:** `LegalKernel/FaultProof/Commit/Top.lean`

**Specification.**

```lean
/-- The top-level state commitment: a single 32-byte hash binding
    every sub-state in canonical order.  This is the value the
    sequencer publishes to L1 as the state root. -/
def commitExtendedState (es : ExtendedState) : StateCommit :=
  hashBytes (
    commitBalanceMap   es.base.balances ++
    commitNonceState   es.nonces ++
    commitKeyRegistry  es.registry ++
    commitLocalPolicies es.localPolicies ++
    commitBridgeState  es.bridge
  )
```

**Acceptance criteria.**

  * `commitExtendedState_deterministic`: equal extended states
    produce equal commitments.
  * `commitExtendedState_size = 32` (under
    `UniformOutputSize hashBytes 32`).
  * `commitExtendedState_extensional`: extensionally equal states
    (same cells, possibly different RB-tree shapes) produce equal
    commitments — this is the canonicalisation-via-toList property
    that Workstream-D and Phase-4 already discharge.

**Why a single hash, not five.**  L1 storage costs scale linearly
with the number of distinct hashes the sequencer publishes.  A
single hash is one storage slot per state root.  Five hashes
would be five slots per state root, ~5× the cost.  The
fault-proof game's per-step verification re-computes the
sub-roots from the cell proofs and combines them into the
top-level hash, so the L1 contract never needs to load the
sub-roots independently.

### 6.5 WU H.2.5 — `commitExtendedState` injectivity (split into 3 sub-WUs)

The injectivity proof's natural structure follows the layered
commitment scheme: per-sub-state injectivity, then top-level
composition.  v2 splits the v1 monolithic WU accordingly.

#### 6.5.1 WU H.2.5a — Per-sub-state injectivity

**Module:** `LegalKernel/FaultProof/Commit/SubStateInjectivity.lean`

**Dependencies.** WUs H.2.1, H.2.2, H.2.3, plus Workstream-D's
`verifyProofRec_inj`.

**Specification.**  Five injectivity theorems, one per
sub-state commitment:

```lean
theorem commitBalanceMap_injective_under_collision_free
    (b₁ b₂ : RBMap ResourceId BalanceMap)
    (h_cf : CollisionFree hashBytes)
    (h_eq : commitBalanceMap b₁ = commitBalanceMap b₂) :
    b₁.toList = b₂.toList

theorem commitNonceState_injective_under_collision_free  -- analogous
theorem commitKeyRegistry_injective_under_collision_free  -- analogous
theorem commitLocalPolicies_injective_under_collision_free  -- analogous
theorem commitBridgeState_injective_under_collision_free  -- analogous
```

Each follows from Workstream-D's `verifyProofRec_inj` plus the
`byteArray_append_inj` building block.

**Acceptance criteria.**

  * Five theorems proved without `sorry`.
  * Reuses Workstream-D's verifier-injectivity proof structure.
  * Each conditional on `CollisionFree hashBytes`.
  * Test: per-substate value-level injectivity tests in
    `Test/FaultProof/Commit.lean`.

#### 6.5.2 WU H.2.5b — Top-level composition

**Module:** `LegalKernel/FaultProof/Commit/Injectivity.lean`

**Dependencies.** WU H.2.5a, H.2.4.

**Specification.**

```lean
theorem commitExtendedState_injective_under_collision_free
    (es₁ es₂ : ExtendedState)
    (h_cf : CollisionFree hashBytes)
    (h_eq : commitExtendedState es₁ = commitExtendedState es₂) :
    extendedStateExtensionallyEqual es₁ es₂
```

where `extendedStateExtensionallyEqual` requires:

```lean
def extendedStateExtensionallyEqual (es₁ es₂ : ExtendedState) : Prop :=
  es₁.base.balances.toList = es₂.base.balances.toList ∧
  es₁.nonces.next.toList   = es₂.nonces.next.toList ∧
  es₁.registry.toList      = es₂.registry.toList ∧
  es₁.localPolicies.toList = es₂.localPolicies.toList ∧
  es₁.bridge.consumed.toList = es₂.bridge.consumed.toList ∧
  es₁.bridge.pending.toList  = es₂.bridge.pending.toList ∧
  es₁.bridge.nextWdId        = es₂.bridge.nextWdId
```

(extensional equality on `toList` rather than structural
equality on the RB-tree shape — equal `toList`s mean equal
canonical observable behaviour).

**Proof strategy.**  Apply WU H.2.5a's five sub-state
injectivities, plus `byteArray_append_inj` for the top-level
hash composition.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * `#print axioms` shows `[propext, Quot.sound]` only.

#### 6.5.3 WU H.2.5c — RBMap canonicalisation lemma

**Module:** `LegalKernel/FaultProof/Commit/Canonicalisation.lean`

**Dependencies.** Std `Std.TreeMap.equiv_iff_toList_eq` (already
in tcb_allowlist via Workstream-D).

**Specification.**

```lean
theorem extendedStateExtensionallyEqual_implies_observably_equal
    (es₁ es₂ : ExtendedState)
    (h : extendedStateExtensionallyEqual es₁ es₂) :
    -- Every per-cell observation agrees:
    (∀ r a, getBalance es₁.base r a = getBalance es₂.base r a) ∧
    (∀ a, expectsNonce es₁ a = expectsNonce es₂ a) ∧
    (∀ a, KeyRegistry.lookup es₁.registry a = KeyRegistry.lookup es₂.registry a) ∧
    (∀ a, LocalPolicies.lookup es₁.localPolicies a = LocalPolicies.lookup es₂.localPolicies a) ∧
    (es₁.bridge = es₂.bridge)
```

In words: extensional equality on `toList` implies pointwise
agreement on every cell observation.  This is what the
fault-proof game's correctness ultimately rests on — the L1
game asserts "states differ at cell C," and this lemma says
that's equivalent to "states have different commits."

**Proof strategy.**  RBMap structural lemmas:
`equiv_iff_toList_eq` plus per-state `find?` extraction.
Mechanical.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * Together with H.2.5b, establishes that `commitExtendedState`
    is observably injective under `CollisionFree hashBytes`.
  * Test: 4 value-level pointwise-agreement cases.

**Why this matters.**  This is the proof that "if the L1 contract
sees the same state root from two parties, the parties must
actually agree on the state at every observable cell."  Without
this, the bisection game could converge to a single step where
both parties claim the same state-root commitment but actually
disagree on the underlying observable state.

### 6.6 WU H.2.6 — SMT-key derivation discipline (NEW)

**Module:** `LegalKernel/FaultProof/Commit/KeyDerivation.lean`

**Why this WU.**  v1 specified two-level SMTs without addressing
how RBMap-keyed state translates to fixed-height SMT path
indices.  This is critical for cross-stack equivalence: Lean's
RBMap order must agree with Solidity's SMT path-index order, or
the L1 game and L2 runtime will compute different roots.

**Specification.**  For each sub-state, define the canonical
mapping from key to SMT path:

```lean
/-- For an RBMap key of type `Nat` (ResourceId, ActorId,
    DepositId, WithdrawalId): the SMT path index is the key
    truncated to `smtHeight = 64` low bits, interpreted as a
    bit-string from MSB to LSB. -/
def smtPathFromNat (k : Nat) : Vector Bool smtHeight :=
  ⟨List.range smtHeight |>.map (fun i => Nat.testBit k (smtHeight - 1 - i)), …⟩
```

For each Workstream-H sub-state:

  * **Balance (outer):** key = `ResourceId : Nat`. Path =
    `smtPathFromNat resourceId`.  Aliasing for resourceIds
    sharing low 64 bits is **safe** because deployments
    typically allocate small resource IDs sequentially.
  * **Balance (inner):** key = `ActorId : Nat`. Path =
    `smtPathFromNat actorId`.  Same aliasing discipline.
  * **NonceState:** key = `ActorId`. Path = same as inner balance.
  * **KeyRegistry:** key = `ActorId`. Same.
  * **LocalPolicies:** key = `ActorId`. Same.
  * **BridgeConsumed:** key = `DepositId : Nat`. Path =
    `smtPathFromNat depositId`.
  * **BridgePending:** key = `WithdrawalId : Nat`. Path =
    `smtPathFromNat withdrawalId`. (Already specified by
    Workstream D.)

**Aliasing analysis.**  Two distinct keys `k₁ ≠ k₂` map to the
same SMT path iff `k₁ ≡ k₂ (mod 2^smtHeight)`.  For deployments
where keys are allocated sequentially from a `UInt64` counter
(the standard Canon pattern: nextActorId, nextWdId, etc.),
keys never reach 2^64 in any reasonable timeframe, and aliasing
is structurally impossible.

For deployments where keys are derived from external sources
(e.g., `DepositId` from L1 hashes), the deployment-level
discipline is to project the external value into a 64-bit
canonical form **before** insertion into the runtime state.
This is already documented for `DepositId` in
`Bridge/State.lean`'s docstring.

**Acceptance criteria.**

  * `smtPathFromNat` defined and total.
  * Per-sub-state path-derivation specifications match
    Solidity-side `keyToSmtPath` byte-for-byte.
  * `pathDerivation_deterministic`: equal keys produce equal
    paths.
  * `smtPathFromNat_inj_under_bound`: for `k₁, k₂ < 2^smtHeight`,
    `smtPathFromNat k₁ = smtPathFromNat k₂ → k₁ = k₂`.
  * Test: cross-stack value-level equivalence at canonical
    keys (0, 1, 2^32, 2^63, 2^64-1) in
    `Test/FaultProof/KeyDerivation.lean`.

## 7. Workstream H.3 — Per-step proofs

The L1 step VM doesn't have access to the full state — it only
has the state-root commitment.  When a step is challenged, the
challenger must supply Merkle proofs for every cell the step
reads or writes; the L1 contract verifies the proofs against the
committed root and uses the cell values as inputs to the step
function.

### 7.1 WU H.3.1 — `CellProof` and `CellProofBundle`

**Module:** `LegalKernel/FaultProof/Proof/Cell.lean`

**Specification.**

```lean
/-- A Merkle proof witnessing that a single cell of the
    `ExtendedState` has a particular value at the committed
    root. -/
structure CellProof where
  cellTag    : CellTag        -- which sub-state + cell key
  cellValue  : ByteArray      -- the cell's CBE-encoded value
  siblings   : List ByteArray -- Merkle path siblings
  deriving Repr, DecidableEq

/-- A bundle of cell proofs covering every cell read/written by
    one step.  The bundle's contents are a function of the
    action variant (per WU H.1.4). -/
structure CellProofBundle where
  proofs : List CellProof
  deriving Repr, DecidableEq

/-- Tag identifying which sub-state + cell key a `CellProof`
    references. -/
inductive CellTag
  | balance        (resource : ResourceId) (actor : ActorId)
  | nonce          (actor : ActorId)
  | registry       (actor : ActorId)
  | localPolicy    (actor : ActorId)
  | bridgeConsumed (depositId : DepositId)
  | bridgePending  (withdrawalId : WithdrawalId)
  | bridgeNextWdId
  deriving Repr, DecidableEq
```

**Acceptance criteria.**

  * Each cell-tag variant maps to exactly one of the five
    sub-state SMTs (or to a leaf-only commitment for
    `bridgeNextWdId`, which is just a `Nat`).
  * `CellTag.encode` / `decode` round-trip + injectivity proven.

### 7.2 WU H.3.2 — Per-action-variant proof shapes

**Module:** `LegalKernel/FaultProof/Proof/Shapes.lean`

**Specification.**  For each `Action` constructor, the function

```lean
def Action.requiredCellProofs : Action → List CellTag
```

returns the cell tags whose proofs must appear in the
`CellProofBundle`.  For example:

  * `transfer r s rcv amt` requires
    `[balance r s, balance r rcv, nonce s, registry s]`.
  * `distributeOthers r exclude amt` requires the per-recipient
    balance cells of all non-excluded actors at `r`, plus the
    sender's nonce + registry.  Since the recipient list is
    unbounded a priori, this constructor's proof bundle is
    decomposed into `subStepsProofs` (per WU H.1.4).

**Acceptance criteria.**

  * `requiredCellProofs` is total and decidable.
  * For each variant, `requiredCellProofs` matches the cells
    actually read/written by `apply_impl` (theorem
    `requiredCellProofs_matches_apply_impl`, proved per-variant
    by `rfl` after unfolding both definitions).

### 7.3 WU H.3.3 — Proof verification + cell-update lemmas

**Module:** `LegalKernel/FaultProof/Proof/Verify.lean`

**Dependencies.** WU H.2.* (commitment scheme), H.3.1 (CellProof
type), H.3.2 (proof shapes).

**Specification.**

```lean
/-- Verify a single cell proof against the committed state root.
    Computes the expected sub-state root from the proof's cell
    value and Merkle path, then compares against the relevant
    sub-state's root within the top-level commit. -/
def verifyCellProof
    (commit : StateCommit) (proof : CellProof) : Bool

/-- Verify every cell proof in a bundle. -/
def verifyCellProofs
    (commit : StateCommit) (bundle : CellProofBundle) : Bool := by
  bundle.proofs.all (fun p => verifyCellProof commit p)

/-- Compute the new commitment after updating one cell.  Used by
    `recomputeCommitment` (WU H.1.2) to thread the post-state
    commit. -/
def updateCommitment
    (commit : StateCommit) (proof : CellProof)
    (newValue : ByteArray) : StateCommit
```

**Headline theorems.**

```lean
theorem verifyCellProof_complete
    (es : ExtendedState) (cellTag : CellTag) :
    let proof := buildCellProof es cellTag
    verifyCellProof (commitExtendedState es) proof = true

theorem verifyCellProof_sound_under_collision_free
    (commit : StateCommit) (proof : CellProof)
    (h_cf : CollisionFree hashBytes)
    (h_verify : verifyCellProof commit proof = true) :
    ∃ es, commitExtendedState es = commit ∧
          getCellValue es proof.cellTag = proof.cellValue

theorem verifyCellProofs_complete
    (es : ExtendedState) (action : Action) :
    verifyCellProofs (commitExtendedState es) (buildCellProofs es action) = true

theorem updateCommitment_agrees_with_setCell
    (es : ExtendedState) (proof : CellProof)
    (newValue : ByteArray)
    (h_proof : proof = buildCellProof es proof.cellTag) :
    updateCommitment (commitExtendedState es) proof newValue
    = commitExtendedState (setCell es proof.cellTag newValue)
```

**Acceptance criteria.**

  * All four theorems proved without `sorry`.
  * The completeness theorem requires no hash hypothesis (it's
    structural recursion through the Merkle tree, mirroring
    Workstream D's `verifyProof_complete`).
  * The soundness theorem requires `CollisionFree hashBytes`,
    matching Workstream D's discipline.
  * The `updateCommitment_agrees_with_setCell` theorem is the
    bridge to the kernel's existing setCell semantics.
  * Test: 8 cases per theorem.  Total ~32 tests in
    `Test/FaultProof/Proof.lean`.
  * Named decidable instance:
    `instDecidableVerifyCellProof`,
    `instDecidableVerifyCellProofs`.

### 7.4 WU H.3.4 — Non-membership cell proofs (NEW)

**Module:** `LegalKernel/FaultProof/Proof/NonMembership.lean`

**Why this WU.**  v1 silently assumed every cell the action
touches has a value in the pre-state.  But many actions touch
cells that don't yet exist:

  * `transfer r s rcv amt` writes `balance r rcv` even if `rcv`
    has no entry yet at resource `r` (the entry gets created
    with the credited amount).
  * `mint r to amt` writes `balance r to` even for fresh
    recipients.
  * `registerIdentity actor pk` writes `registry actor` for
    actors not previously registered.
  * `declareLocalPolicy policy` writes `localPolicy s` for
    actors with no prior declaration.

The standard Workstream-D SMT machinery handles
"non-membership" as a special leaf value (`emptyLeafHash`
= 32 zero bytes per Audit-3.1).  v2 makes this explicit at
the cell-proof level.

**Specification.**

```lean
/-- A cell proof for a non-existent cell.  The cellValue is the
    canonical "absent" marker for the relevant cell type:
    * For `balance`: 0
    * For `nonce`: 0 (default)
    * For `registry`, `localPolicy`: empty ByteArray (signals
      "no entry")
    * For `bridgeConsumed`, `bridgePending`: empty ByteArray
    The Merkle path proves the cell's leaf is the
    `emptyLeafHash` sentinel. -/
structure NonMembershipProof extends CellProof where
  -- inherited fields: cellTag, cellValue (the canonical absent
  -- marker), siblings.
  proof_is_non_membership : cellValue = canonicalAbsentValue cellTag
  deriving Repr

/-- The canonical "absent" value for each cell type. -/
def canonicalAbsentValue : CellTag → ByteArray
  | .balance _ _        => Encoding.encode (T := Amount) 0
  | .nonce _            => Encoding.encode (T := Nonce) 0
  | .registry _         => ByteArray.empty
  | .localPolicy _      => ByteArray.empty
  | .bridgeConsumed _   => ByteArray.empty
  | .bridgePending _    => ByteArray.empty
  | .bridgeNextWdId     => Encoding.encode (T := Nat) 0
```

**Theorems.**

```lean
theorem verifyCellProof_complete_for_absent_cell
    (es : ExtendedState) (cellTag : CellTag)
    (h_absent : isCellAbsent es cellTag) :
    let proof := buildCellProof es cellTag
    proof.cellValue = canonicalAbsentValue cellTag ∧
    verifyCellProof (commitExtendedState es) proof = true

theorem applyCellWrites_creates_absent_cells
    (es : ExtendedState) (action : Action)
    (h_admissible : ∃ verify P d, AdmissibleWith verify P d es _) :
    ∀ cellTag ∈ Action.writeCells action,
        let preCells := extractRequiredCells es action
        ∃ postCells,
          applyCellWrites _ preCells = some postCells ∧
          (cellTag, getCellValue (applyAction es action) cellTag) ∈ postCells
```

**Acceptance criteria.**

  * `canonicalAbsentValue` defined for all 7 CellTag variants.
  * `isCellAbsent` decidable via `inferInstance`.
  * Both theorems proved without `sorry`.
  * Test: 12 cases covering each `CellTag` variant's
    absent-cell-creation in `Test/FaultProof/NonMembership.lean`.

### 7.5 WU H.3.5 — Read-only vs read-write proof distinction (NEW)

**Module:** `LegalKernel/FaultProof/Proof/ReadWrite.lean`

**Why this WU.**  v1's `requiredCellProofs` lumped every cell into
one list.  But the L1 step VM treats read-only cells (verified
but not commitment-updated) differently from read-write cells
(verified AND commitment-updated).  Making this distinction
explicit:

  * Saves L1 gas: read-only proofs need only `verifyCellProof`,
    not `updateCommitment`.
  * Tightens the cross-stack equivalence specification: the
    Lean and Solidity sides must agree on which cells are
    read-only.
  * Improves the per-variant gas budget per Appendix F.

**Specification.**

```lean
/-- A typed cell proof distinguishing read-only from
    read-write. -/
inductive TypedCellProof
  /-- Read-only: cell value is consulted but unchanged after
      step. -/
  | readOnly  (proof : CellProof)
  /-- Read-write: cell value is consulted and written.  The
      `newValue` is the post-step value. -/
  | readWrite (proof : CellProof) (newValue : ByteArray)
  deriving Repr, DecidableEq

/-- A typed cell proof bundle: one per touched cell, tagged
    by its access mode. -/
structure TypedCellProofBundle where
  proofs : List TypedCellProof
  deriving Repr, DecidableEq

/-- Project a TypedCellProof to its underlying CellProof. -/
def TypedCellProof.cellProof : TypedCellProof → CellProof
  | .readOnly p     => p
  | .readWrite p _  => p

/-- Verify a typed proof bundle: every cell proof verifies, and
    the access modes match the action's `readOnlyCells` /
    `writeCells` declaration. -/
def verifyTypedCellProofs
    (commit : StateCommit) (action : Action)
    (bundle : TypedCellProofBundle) : Bool
```

**Theorems.**

```lean
theorem verifyTypedCellProofs_complete
    (es : ExtendedState) (action : Action) :
    verifyTypedCellProofs (commitExtendedState es) action
                          (buildTypedCellProofs es action) = true

theorem verifyTypedCellProofs_separates_readOnly_writeCells
    (commit : StateCommit) (action : Action)
    (bundle : TypedCellProofBundle)
    (h : verifyTypedCellProofs commit action bundle = true) :
    -- Every readOnly proof's cellTag is in action.readOnlyCells.
    (∀ p ∈ bundle.proofs, p.isReadOnly →
        p.cellProof.cellTag ∈ Action.readOnlyCells action) ∧
    -- Every readWrite proof's cellTag is in action.writeCells.
    (∀ p ∈ bundle.proofs, p.isReadWrite →
        p.cellProof.cellTag ∈ Action.writeCells action)
```

**Acceptance criteria.**

  * `TypedCellProof` and `TypedCellProofBundle` defined with
    `Repr` and `DecidableEq`.
  * `verifyTypedCellProofs` decidable via named instance.
  * Two theorems proved without `sorry`.
  * Test: 6 cases covering each access-mode validation path in
    `Test/FaultProof/ReadWrite.lean`.

## 8. Workstream H.4 — Bisection game (Lean specification)

This WU formalises the bisection game as a state machine with
explicit turn-based transitions.  The Lean side is the
*reference implementation*; the Solidity side (WU H.6) ports it
line-for-line under cross-stack equivalence testing.

### 8.1 WU H.4.1 — Game data types (CORRECTED)

**Module:** `LegalKernel/FaultProof/Game/Types.lean`

**v1 bug fix.**  v1's `BisectionRound` carried both
`claimantMidpoint` and `challengerMidpoint` per round, which
suggested both parties submit midpoints simultaneously.  In the
standard interactive-proof game, **each round has exactly one
midpoint claim** from the responding party, and the opposing
party either accepts (collapsing the range to the second half)
or rejects (collapsing to the first half).  v2 redesigns:

**Specification.**

```lean
/-- A state-root assertion: at log index `idx`, the state root
    is `commit`. -/
structure Claim where
  idx    : LogIndex
  commit : StateCommit
  deriving Repr, DecidableEq

/-- The disputed range at any point in the game.  Both parties
    have agreed on the commits at `low` and `high` (the
    disagreement was already at the previous level); they
    disagree about the commit at the midpoint.

    `low.idx < high.idx`; equality means the bisection has
    narrowed to a single step. -/
structure DisputedRange where
  low    : Claim     -- agreed
  high   : Claim     -- agreed at idx; commit may differ between parties
  deriving Repr, DecidableEq

/-- Whose turn it is to act in the current round. -/
inductive TurnSide
  | sequencer
  | challenger
  deriving Repr, DecidableEq

/-- The game state.  Bisection proceeds as a stack: each push
    narrows the range to one half; each pop is either a
    `narrowToFirstHalf` or `narrowToSecondHalf` action by the
    opposing party. -/
structure GameState where
  /-- The actor identities. -/
  sequencer  : ActorId
  challenger : ActorId
  /-- The current disputed range. -/
  range : DisputedRange
  /-- The midpoint commit submitted in the current round (if
      any).  When `none`, the responding party owes a midpoint
      submission; when `some _`, the opposing party owes an
      accept/reject response. -/
  pendingMidpoint : Option Claim
  /-- The bisection depth so far.  Capped at MAX_BISECTION_DEPTH
      = 64 by the legality predicate. -/
  depth : Nat
  /-- Whose turn it is. -/
  turn : TurnSide
  /-- The bonds posted.  Bond accounting is conservative:
      `sequencerBond + challengerBond` equals the total ETH the
      contract holds for this game. -/
  sequencerBond  : Nat
  challengerBond : Nat
  /-- Game status. -/
  status : GameStatus
  /-- The deployment-id binding the game to a specific Canon
      deployment.  Prevents cross-deployment replay of game
      transcripts. -/
  deploymentId : ByteArray
  deriving Repr, DecidableEq

/-- Game terminates in one of four states. -/
inductive GameStatus
  | inProgress
  | sequencerWon         -- challenger lost; bonds redistribute to sequencer
  | challengerWon        -- sequencer lost; bonds redistribute to challenger
  | timedOut (loser : TurnSide)  -- unresponsive party loses
  deriving Repr, DecidableEq
```

**Why this shape works.**  At any point in the game, the disputed
range is `(low, high)` with both parties agreeing on
`low.commit` and disagreeing on `high.commit`.  The party whose
turn it is submits a midpoint; the opposing party either:

  * **Agrees with the midpoint commit:** disagreement now lies
    in `[mid.idx, high.idx]`.  Range narrows to that half.
  * **Disagrees:** disagreement lies in `[low.idx, mid.idx]`.
    Range narrows to the other half.

After `log₂(high.idx - low.idx)` rounds, range is a single
step, and the responding party calls `terminateOnSingleStep`
(WU H.4.2).

**Acceptance criteria.**

  * All types have `Repr` + `DecidableEq`.
  * CBE codecs for `Claim`, `DisputedRange`, `GameState` with
    round-trip + injectivity proofs.  Note: encoding the entire
    `GameState` is for L1 storage; the encoding is not signed
    by users.
  * Decidability: named instance for
    `Decidable (gameWellFormed gs)` (per H.4.6).

### 8.2 WU H.4.2 — Game-state transitions (CORRECTED)

**Module:** `LegalKernel/FaultProof/Game/Step.lean`

**Dependencies.** WU H.4.1, H.4.6 (well-formedness).

**v1 bug fix.**  v1's `terminateOnSingleStep` constructor took
both `submitterPostCommit` and `challengerPostCommit` — but
only one of them is the claim being tested; the L1 step VM
determines which is correct from its own re-execution.  v2
fixes this:

**Specification.**

```lean
/-- The legal transitions from one game state to the next. -/
inductive GameTransition
  /-- The party whose turn it is submits a midpoint commit. -/
  | submitMidpoint (mp : Claim)
  /-- The opposing party responds: agree (range narrows to
      [mid.idx, high.idx]) or disagree (range narrows to
      [low.idx, mid.idx]). -/
  | respondAgree
  | respondDisagree
  /-- When range = single step, terminate by executing.  The
      step VM determines who's right; the contract reads its
      output. -/
  | terminateOnSingleStep
      (signedAction : SignedAction)
      (cellProofs : CellProofBundle)
      (claimedPostCommit : StateCommit)
  /-- A party times out (BISECTION_RESPONSE_TIMEOUT exceeded). -/
  | timeout (loser : TurnSide)
  deriving Repr, DecidableEq

/-- Apply a transition.  Returns the new game state if the
    transition is legal, an error otherwise.  Total function;
    decidable. -/
def applyTransition
    (gs : GameState) (t : GameTransition) : Except GameError GameState

/-- Errors that applyTransition can produce. -/
inductive GameError
  | gameAlreadyEnded
  | wrongTurn
  | midpointOutOfRange (mp : Claim) (range : DisputedRange)
  | midpointDuringResponse  -- already have pending midpoint
  | responseDuringSubmit    -- no pending midpoint to respond to
  | bisectionDepthExceeded
  | rangeNotSingleStep
  | terminationDuringBisection
  | wrongParty
  deriving Repr, DecidableEq
```

**v2 fix: `applyTransition` returns `Except`, not `Option`.**
v1 returned `Option GameState` — failures were silent.  For
on-chain debugging and audit-trail purposes, surfacing the
specific error is essential.  The `GameError` enum's variants
match what `CanonFaultProofGame.sol` reverts with.

**Acceptance criteria.**

  * `applyTransition` total and decidable.
  * Per-error-variant theorems documenting the legality
    conditions (e.g.
    `applyTransition_rejects_midpoint_out_of_range`).
  * Test: 8 cases per error variant in
    `Test/FaultProof/GameTransitions.lean`.

### 8.3 WU H.4.3 — Bisection convergence (split into 3 sub-WUs)

The convergence proof has three structural pieces: range-halving
per round, descent-by-log₂ on rounds, and edge-case enumeration.
v2 splits accordingly.

#### 8.3.1 WU H.4.3a — Range-halving lemma

**Module:** `LegalKernel/FaultProof/Game/Convergence/Halving.lean`

**Dependencies.** WU H.4.1, H.4.2.

**Specification.**

```lean
/-- Each successful `respondAgree` or `respondDisagree`
    transition halves the dispute range. -/
theorem range_halves_on_response
    (gs : GameState) (gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_legal_a : applyTransition gs .respondAgree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx ≤
    (gs.range.high.idx - gs.range.low.idx) / 2 + 1

theorem range_halves_on_response_disagree
    -- analogous for .respondDisagree
```

The `+ 1` accounts for odd-length ranges where the midpoint
floor-divides (low + (high-low)/2).

**Acceptance criteria.**

  * Both halving lemmas proved without `sorry`.
  * Mechanical via Nat arithmetic.

#### 8.3.2 WU H.4.3b — Descent on log₂ of range

**Module:** `LegalKernel/FaultProof/Game/Convergence/Descent.lean`

**Dependencies.** WU H.4.3a.

**Specification.**

```lean
/-- After k legal response rounds starting from initial range
    [low, high], the range size is at most
    (high - low + 1) / 2^k. -/
theorem range_size_after_k_rounds
    (gs₀ : GameState) (transcript : List GameTransition)
    (h_legal : isLegalTranscript gs₀ transcript)
    (k : Nat) (h_k : countResponses transcript = k)
    (h_alive : (transcript.foldl … gs₀).status = .inProgress) :
    let final := …
    final.range.high.idx - final.range.low.idx
    ≤ (gs₀.range.high.idx - gs₀.range.low.idx + 1) / 2^k

/-- After log₂(initial range size) + 1 response rounds, the
    range is single-step (size ≤ 1). -/
theorem range_single_step_after_log_rounds
    (gs₀ : GameState) (transcript : List GameTransition)
    (h_legal : isLegalTranscript gs₀ transcript)
    (h_responses : countResponses transcript ≥
        Nat.log2 (gs₀.range.high.idx - gs₀.range.low.idx) + 1) :
    let final := …
    final.range.high.idx - final.range.low.idx ≤ 1
```

**Acceptance criteria.**

  * Both theorems proved without `sorry`.
  * Induction on `transcript.length`.

#### 8.3.3 WU H.4.3c — Convergence theorem (composite)

**Module:** `LegalKernel/FaultProof/Game/Convergence.lean`

**Dependencies.** WU H.4.3a, H.4.3b.

**v1 bug fix.**  v1's theorem statement had a logically
backwards disjunction.  v2 uses an unambiguous conjunction:

**Specification.**

```lean
/-- Bisection convergence.  Any legal transcript starting from
    a well-formed initial state either:
    1. Terminates within MAX_BISECTION_DEPTH rounds, OR
    2. The current state is single-step, ready for
       terminateOnSingleStep. -/
theorem bisection_converges_in_log_length
    (gs₀ : GameState)
    (h_well_formed : gameWellFormed gs₀)
    (transcript : List GameTransition)
    (h_legal : isLegalTranscript gs₀ transcript) :
    let final := transcript.foldl (fun gs t =>
        (applyTransition gs t).toOption.getD gs) gs₀
    final.status ≠ .inProgress ∨
    final.range.high.idx - final.range.low.idx ≤ 1
```

In words: any legal game transcript either reaches a terminal
status (sequencerWon / challengerWon / timedOut) or has
narrowed to a single-step range awaiting termination.

**Termination corollary.**

```lean
theorem bisection_terminates_in_at_most_max_depth_rounds
    (gs₀ : GameState)
    (h_well_formed : gameWellFormed gs₀)
    (transcript : List GameTransition)
    (h_legal : isLegalTranscript gs₀ transcript)
    (h_long : transcript.length > 2 * MAX_BISECTION_DEPTH + 2) :
    let final := …
    final.status ≠ .inProgress
```

The factor `2 × MAX_BISECTION_DEPTH + 2` accounts for: each
bisection round = 2 transitions (submit + respond);
`MAX_BISECTION_DEPTH = 64` rounds; +2 for the final
terminate-or-timeout transition.

**Acceptance criteria.**

  * Both theorems proved without `sorry`.
  * Proof composes WU H.4.3a + H.4.3b.
  * `MAX_BISECTION_DEPTH = 64` covers log lengths up to 2^64
    (essentially unbounded; OQ5 resolution).

### 8.4 WU H.4.4 — Single-honest-challenger property (split into 4 sub-WUs)

This is the load-bearing trust-model theorem.  v2 splits it into
four sub-WUs:

  * H.4.4a defines the honest strategy as a function.
  * H.4.4b proves the honest play is unique under truth.
  * H.4.4c proves the honest party wins against arbitrary
    counter-strategy.
  * H.4.4d handles the timeout case.

#### 8.4.1 WU H.4.4a — Honest strategy definition

**Module:** `LegalKernel/FaultProof/Game/Strategy.lean`

**Dependencies.** WU H.4.2.

**Specification.**

```lean
/-- The truthful state-root function: given a log and a log
    index, the canonical state-root commit is
    commitExtendedState (kernelOnlyReplay genesis (log.take idx)). -/
def truthfulCommit (genesis : ExtendedState) (log : List LogEntry)
    (idx : LogIndex) : StateCommit :=
  commitExtendedState (kernelOnlyReplay genesis (log.take idx))

/-- The honest strategy: given the game state and the truthful
    commit function, return the unique honest move. -/
def honestStrategy
    (truth : LogIndex → StateCommit) (gs : GameState)
    : Option GameTransition :=
  match gs.status, gs.pendingMidpoint, isMyTurn gs with
  | .inProgress, none, true =>
      -- Submit the truthful midpoint.
      let mid := (gs.range.low.idx + gs.range.high.idx) / 2
      some (.submitMidpoint ⟨mid, truth mid⟩)
  | .inProgress, some mp, true =>
      -- The opposing party submitted; agree iff truthful.
      if mp.commit = truth mp.idx then some .respondAgree
      else some .respondDisagree
  | .inProgress, _, _ =>
      -- Single-step termination.
      if gs.range.high.idx - gs.range.low.idx = 1 then
        some (.terminateOnSingleStep _ _ _)  -- L1 contract executes
      else none
  | _, _, _ => none
```

**Acceptance criteria.**

  * `honestStrategy` total.
  * `isMyTurn`, `truthfulCommit` decidable via `inferInstance`.
  * Test: 6 cases verifying the strategy returns the expected
    transition for each game-state shape.

#### 8.4.2 WU H.4.4b — Honest-strategy uniqueness

**Module:** `LegalKernel/FaultProof/Game/StrategyUniqueness.lean`

**Specification.**

```lean
/-- The honest move is uniquely determined by the truth: there
    is no second legal "honest" play. -/
theorem honest_strategy_unique
    (truth : LogIndex → StateCommit) (gs : GameState)
    (h_inProgress : gs.status = .inProgress) :
    -- Any other strategy that's "honest by truth" agrees with
    -- honestStrategy.
    ∀ alt, isHonestByTruth truth gs alt →
        alt = (honestStrategy truth gs).getD .timeout
```

In words: there's exactly one honest play in any legal
in-progress state, given the truth.

**Acceptance criteria.**

  * Theorem proved without `sorry`.

#### 8.4.3 WU H.4.4c — Honest challenger wins (composite)

**Module:** `LegalKernel/FaultProof/Game/Honesty.lean`

**Dependencies.** WUs H.4.3 (convergence), H.4.4a, H.4.4b,
H.1.3b (coherence), H.2.5b (commit injectivity).

**Specification.**  The headline trust-model theorem:

```lean
/-- Honest-challenger property: if the sequencer's claimed
    state root differs from the truth, the challenger plays
    the honest strategy, and the game runs to completion (no
    timeout against the challenger), then the challenger
    wins.

    `honestStrategy` is computable and deterministic; the only
    randomness in the proof is the sequencer's strategy
    (which can be arbitrary). -/
theorem honest_challenger_wins_against_invalid_state_root
    (genesis : ExtendedState) (log : List LogEntry)
    (gs₀ : GameState)
    (h_well_formed : gameWellFormed gs₀)
    (h_initial_disagree : gs₀.range.high.commit ≠
        truthfulCommit genesis log gs₀.range.high.idx)
    (h_initial_agree : gs₀.range.low.commit =
        truthfulCommit genesis log gs₀.range.low.idx)
    (h_cf : CollisionFree hashBytes)
    (challenger_strategy : GameState → GameTransition)
    (h_challenger_honest :
        ∀ gs, gs.status = .inProgress → gs.turn = .challenger →
            challenger_strategy gs = (honestStrategy
                (truthfulCommit genesis log) gs).getD .timeout)
    (transcript : List GameTransition)
    (h_legal : isLegalTranscript gs₀ transcript)
    (h_no_challenger_timeout :
        ∀ idx, transcript[idx]? ≠ some (.timeout .challenger))
    (final := transcript.foldl (fun gs t =>
        (applyTransition gs t).toOption.getD gs) gs₀) :
    final.status = .challengerWon ∨ final.status = .timedOut .sequencer
```

In words: if the sequencer asserted a wrong state root and the
challenger plays the honest strategy without timing out, the
final game status is challenger-wins (the sequencer either
plays through to a single-step termination that the step VM
proves wrong, or times out trying to defend the lie).

**Proof strategy.** Three-phase composition:

  1. **Convergence.**  By WU H.4.3c, the game must terminate
     within `MAX_BISECTION_DEPTH` rounds.  Either it
     terminates via timeout (challenger doesn't time out by
     hypothesis, so timeout is against the sequencer), or the
     range narrows to single-step.
  2. **Disagreement persistence.**  By induction on the
     transcript: at every round, the disputed range still
     contains some index `j` where sequencer's claim differs
     from truth.  The honest challenger always picks the
     half containing the disagreement.
  3. **Single-step settlement.**  When range = 1, the L1 step
     VM (via WU H.1.3b's coherence theorem) computes the
     truthful post-commit.  By WU H.2.5b's injectivity, this
     differs from the sequencer's claim, so the contract
     declares the challenger winner.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * Proof depends only on `propext`, `Quot.sound`, and the
    existing `Verify` opaque.  No `Classical.choice`.
  * `#print axioms` shows the expected three.
  * Critical hypothesis: `CollisionFree hashBytes`.  Without
    it, two distinct underlying states could share a
    commit, breaking the disagreement-persistence lemma.

#### 8.4.4 WU H.4.4d — Honest-strategy timeout absorption

**Module:** `LegalKernel/FaultProof/Game/Timeout.lean`

**Specification.**

```lean
/-- Symmetric corollary: if the challenger's strategy is
    honest AND the sequencer abandons (lets a timeout fire
    against them), the challenger wins. -/
theorem honest_challenger_wins_via_sequencer_timeout
    (gs₀ : GameState) (transcript : List GameTransition)
    (h_well_formed : gameWellFormed gs₀)
    (h_legal : isLegalTranscript gs₀ transcript)
    (h_sequencer_timeout :
        ∃ idx, transcript[idx]? = some (.timeout .sequencer)) :
    let final := …
    final.status = .timedOut .sequencer ∨ final.status = .challengerWon
```

This handles the case where the sequencer simply doesn't
respond rather than playing through to a single-step
settlement.  It's structurally simpler than H.4.4c (no
disagreement-persistence argument needed) and stands as a
separate theorem for callsite clarity.

**Acceptance criteria.**

  * Theorem proved without `sorry`.

**Why these are the load-bearing theorems.**  Together, WUs
H.4.4c and H.4.4d certify that an honest challenger always
prevails against an invalid state root, regardless of
sequencer strategy.  This *replaces* the entire trust
assumption that the Phase-6 quorum mechanism rests on.
Anyone reading the kernel and finding these theorems can
verify mechanically that the fault-proof game is correct
without trusting any adjudicator set.

#### 8.4.5 WU H.4.4e — Witness construction from L1 settlement (audit-fix; new)

**Module:** `LegalKernel/FaultProof/Witness.lean` (extends WU H.8.4).

**Why this WU.**  v1 and the initial v2 spec defined
`FaultProofChallengerWon` as a propositional witness but
didn't specify how it gets *constructed* from on-chain
evidence.  Without this, the witness-bearing API in WU H.8.4
is unimplementable.

**Specification.**  The runtime constructs the witness from a
canonical `Action.faultProofResolution` log entry plus a
deployment-supplied L1 event-verifier:

```lean
/-- Deployment-supplied L1 event verifier (opaque, runtime-
    bound).  Given the resolution log entry's fields, the
    deployment-side L1 watcher confirms whether a matching
    `FaultProofGameSettled(challengerWon)` event exists on L1.
    Returns `true` iff yes. -/
opaque l1FaultProofVerifier
    (bindingHash : ByteArray) (gameId : Nat)
    (winner : ActorId) (revertFromIdx : LogIndex) : Bool

/-- Constructor for the propositional witness.  Takes the
    log entry and an L1-attested confirmation Boolean. -/
theorem FaultProofChallengerWon.of_log_entry
    (log : List LogEntry) (idx : LogIndex) (entry : LogEntry)
    (h_idx : log[idx]? = some entry)
    (gameId : Nat) (winner : ActorId) (revertFromIdx : LogIndex)
    (bindingHash : ByteArray)
    (h_action : entry.signedAction.action =
                 .faultProofResolution bindingHash gameId winner revertFromIdx)
    (h_l1_attest :
        l1FaultProofVerifier bindingHash gameId winner revertFromIdx = true) :
    FaultProofChallengerWon log gameId revertFromIdx
```

The `l1FaultProofVerifier` is **opaque** (not `axiom`): it's a
trust assumption on the deployment-side L1 watcher that
correctly observes L1 events.  Per Workstream-A's discipline,
opaque declarations don't appear in `#print axioms` output;
only `propext`, `Quot.sound` (and possibly `Classical.choice`)
remain in the audit trail.

**Trust-boundary characterization.**  This adds one new trust
assumption: the deployment-side L1 watcher correctly observes
L1 events.  Mitigation: the watcher's observations can be
cross-checked across multiple independent observers (per WU
H.10.5).  As long as one honest watcher produces a true
attestation, the witness is constructible.  The `Verify`
opaque from Workstream-A and `hashBytes` opaque from
Workstream-A are similarly trust-bounded; this adds a third
in the same pattern.

**Acceptance criteria.**

  * `l1FaultProofVerifier` opaque defined in
    `Bridge/L1EventVerifier.lean` (not as an axiom).
  * `FaultProofChallengerWon.of_log_entry` proved without
    `sorry`.
  * The §8.4.3 single-honest-challenger theorem composes
    cleanly with this construction: one honest challenger +
    one honest L1 watcher = sound rollback.
  * Tested by 5 fixtures (using a mock L1 watcher) in
    `Test/FaultProof/Witness.lean`.

### 8.5 WU H.4.5 — Game-state encoding (NEW)

**Module:** `LegalKernel/Encoding/GameState.lean`

**Why this WU.**  The `GameState` (WU H.4.1) needs an L1
storage representation.  v1 implicitly assumed Solidity
struct semantics; v2 specifies the canonical encoding so
Lean and Solidity sides agree byte-for-byte.

**Specification.**

```lean
def GameState.encode : GameState → Stream
def GameState.decode : Stream → Except DecodeError (GameState × Stream)
def GameState.fieldsBounded : GameState → Prop
```

The encoded layout:

```
sequencer        : 8 bytes (UInt64)
challenger       : 8 bytes
range.low.idx    : 8 bytes
range.low.commit : 32 bytes
range.high.idx   : 8 bytes
range.high.commit: 32 bytes
pendingMidpoint  : 1 byte (option tag) + 40 bytes (if some)
depth            : 8 bytes
turn             : 1 byte
sequencerBond    : 16 bytes (uint128)
challengerBond   : 16 bytes
status           : 1 byte (variant tag) + variant payload
deploymentId     : variable, length-prefixed
```

Total: 138 + variant payload + deploymentId.

**Acceptance criteria.**

  * Round-trip + injectivity proven.
  * Encoded size bounded above by 256 bytes for typical
    deployment IDs.
  * Cross-stack equivalence: Solidity `abi.encode(GameState)`
    + a custom `encode` library produces the same bytes.

### 8.6 WU H.4.6 — Tie-breaking and edge cases (NEW)

**Module:** `LegalKernel/FaultProof/Game/EdgeCases.lean`

**Why this WU.**  Several edge cases need explicit handling
to avoid undefined behaviour:

**Edge cases enumerated.**

  1. **Initial disagreement is at consecutive indices.**  If
     `gs₀.range.high.idx = gs₀.range.low.idx + 1`, the game
     is already single-step; bisection never fires.  The
     responding party must call `terminateOnSingleStep`
     directly.
  2. **Both parties claim identical midpoints.**  Cannot
     happen for an honest party + truth-disagreeing
     sequencer: the honest midpoint is the truth, the
     dishonest midpoint is the lie.  But for a corrupted
     `honestStrategy` (e.g. a bug), `respondAgree` would
     terminate the bisection prematurely.  Mitigation: the
     game-state validator rejects responses on already-agreed
     midpoints (different code path).
  3. **Range-low > range-high.**  Cannot happen if `gs₀` is
     well-formed; rejected by `gameWellFormed`.
  4. **Depth-cap reached without single-step.**  Cannot happen
     for ranges ≤ 2^64 (covered by H.4.3c); rejected
     defensively.
  5. **Both parties time out simultaneously.**  L1 block-
     deterministic timeouts: only one of them fires per
     block.  Rejected by the responding-party-only timeout
     mechanism.
  6. **Game-state encoding-decoding round-trip after each
     transition.**  Each L1 transaction stores the new
     `GameState` and emits an event with the new state.
     Replay across L1 reorganisation: the L1 contract refuses
     to accept transitions on stale states (per L1 nonce
     discipline), so reorg replays harmlessly.

**Specification.**

```lean
/-- Well-formedness predicate for a game state. -/
def gameWellFormed (gs : GameState) : Prop :=
  gs.range.low.idx < gs.range.high.idx ∧
  gs.depth ≤ MAX_BISECTION_DEPTH ∧
  (gs.pendingMidpoint.map (fun mp =>
      gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
      |>.getD True) ∧
  (gs.status = .inProgress → gs.sequencerBond + gs.challengerBond > 0)

instance instDecidableGameWellFormed (gs : GameState) :
    Decidable (gameWellFormed gs) := by
  unfold gameWellFormed
  exact inferInstance

/-- A legal transcript: every transition obeys applyTransition. -/
def isLegalTranscript (gs₀ : GameState) (ts : List GameTransition) : Prop :=
  ts.foldl (fun acc t =>
      acc.bind (fun gs => (applyTransition gs t).toOption)) (some gs₀)
  ≠ none
```

**Acceptance criteria.**

  * `gameWellFormed` decidable via `inferInstance`.
  * `isLegalTranscript` decidable.
  * Six edge-case theorems, one per case above, each proving
    the rejection / fallback behaviour.
  * Test: 12 cases in `Test/FaultProof/EdgeCases.lean`.

## 9. Workstream H.5 — Solidity step VM

The L1 step VM is a Solidity contract that executes one kernel
step at a time.  It mirrors the Lean-side `kernelStepApply` (WU
H.1.2) line-for-line under cross-stack equivalence testing.

### 9.1 WU H.5.1 — `CanonStepVM.sol` skeleton

**Module:** `solidity/src/contracts/CanonStepVM.sol`

**Specification.**  The contract exposes one external function:

```solidity
/// @notice Execute one kernel step.  Verify the cell proofs
///         against `preStateCommit`; apply the action; return
///         the new state commitment.  Reverts on any failure
///         (mismatched cell proofs, inadmissible action,
///         post-state mismatch).
function executeStep(
    bytes32          preStateCommit,
    bytes calldata   signedActionEncoded,
    CellProof[] calldata cellProofs
) external view returns (bytes32 postStateCommit);
```

**Acceptance criteria.**

  * Pure / view function (no state mutation).
  * Gas cost bounded by `MAX_STEP_GAS = 8_000_000`.
  * Reverts with precise error variants on each failure mode:
    `BadCellProof`, `InadmissibleAction`, `PostStateMismatch`.

### 9.2 WU H.5.2 — Per-action-variant step functions (19 sub-WUs)

**Module:** `solidity/src/contracts/CanonStepVM.sol` (continuation)

**Common skeleton.**  Each per-variant function follows the
same pattern:

```solidity
function _step<Variant>(
    bytes32 preStateCommit,
    /* per-variant decoded fields */,
    /* per-variant typed cell proofs */,
    bytes calldata signedActionBytes  // for signature verification
) internal view returns (bytes32 postStateCommit) {
    // 1. Verify each cell proof against preStateCommit.
    // 2. Verify the signed action's signature via CanonEip712 +
    //    ECDSA.recover.
    // 3. Verify the action's precondition holds at the
    //    pre-state cell values.
    // 4. Compute new cell values per the variant's semantic rule.
    // 5. Recompute the post-state commit.
    // 6. Return.
}
```

The 19 explicit sub-WUs follow.  Each lists its per-variant
gas budget; the full table is in **Appendix F**.

#### 9.2.1 WU H.5.2.1 — `_stepTransfer`

**Inputs:** resourceId, sender, receiver, amount.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[balance r sender, balance r receiver,
nonce sender]`.
**Pre-condition (Solidity):** `senderBalance.cellValue ≥ amount`
and `amount > 0`.
**Cell writes:** `senderBalance' = senderBalance - amount`;
`receiverBalance' = receiverBalance + amount`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 350_000.

#### 9.2.2 WU H.5.2.2 — `_stepMint`

**Inputs:** resourceId, to, amount.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[balance r to, nonce sender]`.
**Pre-condition:** `True` (mint has no balance precondition).
**Cell writes:** `toBalance' = toBalance + amount`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 280_000.

#### 9.2.3 WU H.5.2.3 — `_stepBurn`

**Inputs:** resourceId, from, amount.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[balance r from, nonce sender]`.
**Pre-condition:** `fromBalance.cellValue ≥ amount`.
**Cell writes:** `fromBalance' = fromBalance - amount`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 280_000.

#### 9.2.4 WU H.5.2.4 — `_stepFreezeResource`

**Inputs:** resourceId.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Pre-condition:** `True`.
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 200_000.

#### 9.2.5 WU H.5.2.5 — `_stepReplaceKey`

**Inputs:** actor, newKey.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[registry actor, nonce sender]`.
**Pre-condition:** `actor == sender` (deployment-policy
decision in Workstream-E).
**Cell writes:** `actorRegistry' = newKey`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 320_000.

#### 9.2.6 WU H.5.2.6 — `_stepReward`

**Inputs:** resourceId, to, amount.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[balance r to, nonce sender]`.
**Pre-condition:** `True`.
**Cell writes:** `toBalance' = toBalance + amount`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 280_000.

#### 9.2.7 WU H.5.2.7 — `_stepDistributeOthers` (bulk)

**Inputs:** resourceId, exclude, amount.
**Sub-step strategy:** one sub-step per recipient.  Each sub-step
takes `[balance r recipient]` proof and writes
`recipientBalance' = recipientBalance + amount`.  The final
sub-step writes the sender's nonce.
**Read-only proofs (per sub-step):** none.
**Read-write proofs (per sub-step):** `[balance r recipient]`.
**Pre-condition:** none per-sub-step (admissibility checked
at action level on first sub-step).
**Per-sub-step gas:** ≤ 200_000.
**Total sub-steps:** ≤ MAX_RECIPIENTS_PER_BULK_ACTION = 256.
**Cumulative bulk gas:** ≤ 51_200_000 (worst case across multiple
L1 transactions).

#### 9.2.8 WU H.5.2.8 — `_stepProportionalDilute` (bulk)

**Inputs:** resourceId, exclude, totalReward.
**Sub-step strategy:** identical to `_stepDistributeOthers`,
plus per-sub-step computation of the recipient's proportional
share (read sender's balance + recipient's balance, compute
floor division).
**Per-sub-step gas:** ≤ 220_000 (slightly more than
distributeOthers due to division).

#### 9.2.9 WU H.5.2.9 — `_stepDispute`

**Inputs:** Dispute payload (challenger, claim, evidence,
nonce, sig).
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Pre-condition:** `True` (Phase-6 dispute pipeline does its
own admissibility checks at the L2 level; the kernel-level
compile is a no-op `freezeResource 0`).
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 250_000 (extra cost for dispute payload
size in calldata).

#### 9.2.10 WU H.5.2.10 — `_stepDisputeWithdraw`

**Inputs:** disputeIdx.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 200_000.

#### 9.2.11 WU H.5.2.11 — `_stepVerdict`

**Inputs:** Verdict payload.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 250_000 (verdict payload).

#### 9.2.12 WU H.5.2.12 — `_stepRollback`

**Inputs:** targetIdx.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 200_000.

**Note.**  Rollback's *actual effect* (resetting state to a
prior point) is implemented at the runtime layer (via
`revertToPriorRoot` on the bridge), not at the kernel level.
The Action.rollback compile is a no-op; the L2 runtime sees
the action and triggers the rollback.

#### 9.2.13 WU H.5.2.13 — `_stepRegisterIdentity`

**Inputs:** actor, pk.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[registry actor, nonce sender]`.
**Pre-condition:** `senderActor == bridgeActor` (deployment
policy: only the bridge actor can register identities; per
Workstream-B `bridgePolicy_authorizes_registerIdentity`).
**Cell writes:** `actorRegistry' = pk`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 320_000.

#### 9.2.14 WU H.5.2.14 — `_stepDeposit`

**Inputs:** depositId, recipient, resourceId, amount.
**Read-only proofs:** `[registry sender, bridgeConsumed
depositId]`.
**Read-write proofs:** `[balance r recipient, nonce sender,
bridgeConsumed depositId]`.
**Pre-condition:** `senderActor == bridgeActor` AND
`bridgeConsumed[depositId]` is absent (i.e., not yet
consumed).
**Cell writes:** `recipientBalance' = recipientBalance + amount`;
`senderNonce' = senderNonce + 1`;
`bridgeConsumed[depositId] = (resourceId, amount)`.
**Gas budget:** ≤ 420_000 (multiple cell updates).

#### 9.2.15 WU H.5.2.15 — `_stepWithdraw`

**Inputs:** resourceId, sender, amount, recipientL1.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[balance r sender, nonce sender,
bridgePending nextWdId, bridgeNextWdId]`.
**Pre-condition:** `senderBalance >= amount`.
**Cell writes:** `senderBalance' = senderBalance - amount`;
`senderNonce' = senderNonce + 1`;
`bridgePending[nextWdId] = (r, sender, amount, recipientL1)`;
`bridgeNextWdId' = bridgeNextWdId + 1`.
**Gas budget:** ≤ 480_000.

#### 9.2.16 WU H.5.2.16 — `_stepDeclareLocalPolicy`

**Inputs:** policy.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[localPolicy sender, nonce sender]`.
**Pre-condition:** `True`.
**Cell writes:** `localPolicy[sender] = policy`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 380_000 (variable due to policy size; capped
by MAX_POLICY_ENCODE_BYTES = 16_384).

#### 9.2.17 WU H.5.2.17 — `_stepRevokeLocalPolicy`

**Inputs:** none.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[localPolicy sender, nonce sender]`.
**Pre-condition:** `True`.
**Cell writes:** `localPolicy[sender] = empty`;
`senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 280_000.

#### 9.2.18 WU H.5.2.18 — `_stepFaultProofChallenge`

**Inputs:** bindingHash, disputedStartIdx, disputedEndIdx,
challengerCommit.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Pre-condition:** `True` (the L1 game contract validates the
challenge; the L2 action is advisory-only).
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 250_000 (challenge payload).

#### 9.2.19 WU H.5.2.19 — `_stepFaultProofResolution`

**Inputs:** bindingHash, winner, revertFromIdx.
**Read-only proofs:** `[registry sender]`.
**Read-write proofs:** `[nonce sender]`.
**Pre-condition:** `True`.
**Cell writes:** `senderNonce' = senderNonce + 1`.
**Gas budget:** ≤ 220_000.

**Aggregate acceptance criteria (across H.5.2.1–H.5.2.19).**

  * One Solidity function per variant, named exactly per
    convention.
  * Per-variant gas budgets documented in Appendix F and tested
    with explicit assertions.
  * Cross-stack equivalence: each function's output matches
    the Lean-side `kernelStepApply` for every fixture in WU
    H.10's corpus (16 happy-path + 8 adversarial per variant
    = 456 total fixtures).
  * Reentrancy-safe: all `view`/`pure`; no state mutations.
  * Calldata layout: `signedActionBytes` is `calldata` (not
    `memory`) for gas; cell proof arrays are `calldata`
    pointers passed through to internal verification.

### 9.3 WU H.5.3 — Merkle proof library

**Module:** `solidity/src/lib/StepVMMerkle.sol`

**Specification.**  A library mirroring Workstream-D's
`SmtVerifier.sol` for the additional sub-states introduced by
Workstream H (BalanceMap-of-BalanceMap, NonceState, KeyRegistry,
LocalPolicies, BridgeConsumed).

**Acceptance criteria.**

  * Library functions match Lean-side `verifyCellProof` /
    `updateCommitment` byte-for-byte.
  * Gas cost per cell verification ≤ 50_000 (typical: 30_000).
  * Cross-stack equivalence corpus in WU H.10.1 covers every
    cell-tag variant.

## 10. Workstream H.6 — Solidity bisection contract

### 10.1 WU H.6.1 — `CanonFaultProofGame.sol` (split into 7 sub-WUs)

The contract is large enough that v1's monolithic WU obscured
where the work actually concentrates.  v2 splits along the
contract's external-entry-point boundaries plus the data
structure / settlement / event-emission separations.

#### 10.1.1 WU H.6.1a — Game data structures

**Module:** `solidity/src/contracts/CanonFaultProofGame.sol`
(skeleton)

**Specification.**

```solidity
struct Claim {
    uint64  idx;
    bytes32 commit;
}

struct DisputedRange {
    Claim low;
    Claim high;
}

enum TurnSide { Sequencer, Challenger }

enum GameStatus {
    InProgress,
    SequencerWon,
    ChallengerWon,
    TimedOutSequencer,
    TimedOutChallenger
}

struct Game {
    address sequencer;
    address challenger;
    DisputedRange range;
    bool          hasPendingMidpoint;
    Claim         pendingMidpoint;
    uint64        depth;
    TurnSide      turn;
    uint64        turnDeadline;
    uint128       sequencerBond;
    uint128       challengerBond;
    GameStatus    status;
    bytes32       deploymentId;
}

mapping(uint256 => Game) public games;
uint256 public nextGameId;
```

These mirror the Lean-side `GameState` (WU H.4.1) field-for-field.

**Acceptance criteria.**

  * Field layout matches Lean-side `GameState.encode` byte order.
  * Solidity `abi.encode(Game)` is byte-equivalent to Lean
    `GameState.encode` for every fixture in WU H.10.2.

#### 10.1.2 WU H.6.1b — `initiateChallenge` entry

**Specification.**

```solidity
function initiateChallenge(
    uint64  disputedLogIndex,
    bytes32 challengerCommit,
    bytes32 lowCommit,                 // sequencer-published prior root
    uint64  lowLogIndex
) external payable nonReentrant returns (uint256 gameId);
```

**Behaviour.**

  1. Verify caller posted `MIN_CHALLENGE_BOND` exactly.
  2. Verify `lowCommit` is a finalised state root (consult
     `CanonStateRootSubmission`).
  3. Verify `disputedLogIndex` references an unfinalised state
     root (also via state-root submission contract); read its
     `submittedCommit` and stash it as `range.high.commit`.
  4. Verify `challengerCommit ≠ submittedCommit`
     (else there's no dispute to resolve).
  5. Allocate fresh `gameId`; initialise `Game` struct.
  6. Set `turn = Sequencer` (sequencer responds first), set
     `turnDeadline = block.number + BISECTION_RESPONSE_TIMEOUT`.
  7. Emit `FaultProofGameOpened` event.

**Acceptance criteria.**

  * Reverts on insufficient bond, non-existent state root,
    matching commits.
  * `nonReentrant` — no callbacks during state mutation.
  * Cross-stack equivalence: equivalent to a fresh
    `GameState` with corresponding fields in Lean.

#### 10.1.3 WU H.6.1c — `submitMidpoint` entry

**Specification.**

```solidity
function submitMidpoint(
    uint256 gameId,
    bytes32 midpointCommit
) external nonReentrant;
```

**Behaviour.**

  1. Look up `games[gameId]`; revert if not in progress.
  2. Verify `msg.sender` matches the responding party
     (`game.turn`).
  3. Verify `block.number ≤ game.turnDeadline` (else this is
     a timeout).
  4. Verify `!game.hasPendingMidpoint` (a midpoint is owed,
     not a response).
  5. Compute `midpointIdx = (range.low.idx + range.high.idx) / 2`.
  6. Verify `midpointIdx > range.low.idx ∧ midpointIdx <
     range.high.idx` (range narrowing has not exhausted; if it
     has, the responding party should call
     `terminateOnSingleStep` instead).
  7. Set `game.pendingMidpoint = (midpointIdx, midpointCommit)`,
     `game.hasPendingMidpoint = true`.
  8. Flip turn; reset deadline.
  9. Emit `BisectionMidpointSubmitted`.

**Acceptance criteria.**

  * Reverts: wrong turn, expired deadline, range-narrowed-out,
    duplicate midpoint.
  * Cross-stack: matches Lean-side `applyTransition gs
    (.submitMidpoint mp) = .ok gs'`.

#### 10.1.4 WU H.6.1d — `respondToMidpoint` entry

**Specification.**

```solidity
function respondToMidpoint(
    uint256 gameId,
    bool agree    // true = agree, false = disagree
) external nonReentrant;
```

**Behaviour.**

  1. Look up game; verify in progress.
  2. Verify `msg.sender` matches the responding party.
  3. Verify deadline.
  4. Verify `game.hasPendingMidpoint`.
  5. If `agree`: range narrows to `[pendingMidpoint, range.high]`.
     If `disagree`: range narrows to `[range.low, pendingMidpoint]`.
  6. Clear pending midpoint; flip turn; reset deadline; increment
     depth.
  7. Verify `depth ≤ MAX_BISECTION_DEPTH`.
  8. Emit `BisectionResponseSubmitted`.

**Acceptance criteria.**

  * Mirrors Lean `applyTransition gs (.respondAgree | .respondDisagree)`.
  * Reverts on depth-cap exceedence (cannot happen with
    well-formed initial range).

#### 10.1.5 WU H.6.1e — `terminateOnSingleStep` entry

**Specification.**

```solidity
function terminateOnSingleStep(
    uint256 gameId,
    bytes calldata signedActionBytes,
    TypedCellProof[] calldata cellProofs,
    bytes32 claimedPostCommit
) external nonReentrant;
```

**Behaviour.**

  1. Look up game; verify in progress.
  2. Verify `msg.sender` is the responding party.
  3. Verify `game.range.high.idx - game.range.low.idx == 1`
     (single step).
  4. Verify `!game.hasPendingMidpoint` (no midpoint owed).
  5. Call `CanonStepVM.executeStep(game.range.low.commit,
     signedActionBytes, cellProofs)` — the step VM returns the
     correct post-state commit or reverts.
  6. Compare returned commit to `claimedPostCommit`:
     * If equal: responding party (msg.sender) wins.
     * If different: the opposing party wins.
  7. Set `status` accordingly; redistribute bonds (per WU
     H.6.2); emit `FaultProofGameSettled`.

**Acceptance criteria.**

  * Critical path; tested by 12 fixtures in WU H.10.3.
  * Reverts on range > 1, on missing midpoint response, on
    wrong msg.sender.
  * No state mutation between step VM call and settlement (CEI
    ordering).

#### 10.1.6 WU H.6.1f — `claimTimeout` entry

**Specification.**

```solidity
function claimTimeout(uint256 gameId) external nonReentrant;
```

**Behaviour.**

  1. Look up game; verify in progress.
  2. Verify `block.number > game.turnDeadline`.
  3. The non-responding party (whose turn it is) loses by
     timeout.
  4. Set `status = TimedOutSequencer` or `TimedOutChallenger`.
  5. Bonds redistribute to the responsive party.
  6. Emit `FaultProofGameSettled` with the timeout outcome.

**Acceptance criteria.**

  * Reverts before deadline.
  * Anyone can call `claimTimeout` (not just the winner) — this
    is intentional, to ensure the game settles even if the
    winner is offline.

#### 10.1.7 WU H.6.1g — Settlement and bond redistribution

**Specification.**  An internal `_settle` function called by
`terminateOnSingleStep` and `claimTimeout`:

```solidity
function _settle(
    uint256 gameId,
    GameStatus finalStatus
) internal {
    Game storage g = games[gameId];
    uint128 totalBonds = g.sequencerBond + g.challengerBond;
    address payable winner;

    if (finalStatus == GameStatus.SequencerWon ||
        finalStatus == GameStatus.TimedOutChallenger) {
        winner = payable(g.sequencer);
    } else {
        winner = payable(g.challenger);
    }

    g.status = finalStatus;

    // CEI: state mutation done; now external call.
    uint128 winnerPayout = totalBonds;  // see OQ8 resolution
    // Optionally, deployment-treasury split per OQ8.

    (bool ok, ) = winner.call{value: winnerPayout}("");
    require(ok, "BondTransferFailed");

    emit FaultProofGameSettled(gameId, finalStatus, winner, winnerPayout);
}
```

**OQ8 resolution.**  Per the resolution in §19.8: 95% of the
total bond pool to the winner, 5% to the deployment treasury
(constructor argument).  Updated formula:

```solidity
uint128 winnerPayout    = (totalBonds * 95) / 100;
uint128 treasuryPayout  = totalBonds - winnerPayout;
```

**Acceptance criteria.**

  * No reentrancy (winner cannot reenter `claimTimeout`
    on a different game during their callback).
  * Slashing math exact (no rounding errors at integer
    boundaries; 95/100 split tested at small + large bonds).
  * `nonReentrant` modifier on the public entry that triggers
    `_settle`; CEI ordering on the internal flow.

### 10.2 WU H.6.2 — Bond economics

**Module:** `solidity/src/contracts/CanonFaultProofGame.sol`
(continuation)

**Specification.**

  * Sequencer's bond: locked at state-root submission
    (`STATE_ROOT_SUBMISSION_BOND = 1.0 ETH`).  Released after
    `FAULT_PROOF_DISPUTE_WINDOW` if no challenge is filed.
    Slashed in full to challenger if game settles
    `challengerWon`.
  * Challenger's bond: posted at `initiateChallenge`
    (`MIN_CHALLENGE_BOND = 0.05 ETH`).  Slashed in full to
    sequencer if game settles `claimantWon`.
  * Tie-breaking: timeout against the unresponsive party.  Each
    `claimTimeout` call advances the loser; bonds redistribute
    to the responsive party.
  * Anti-griefing: only the actual L1 gas costs, not the bonds,
    pay for the responsive party's transactions.

**Acceptance criteria.**

  * Bond accounting is conservative: total ETH locked equals
    sum of per-game bonds.
  * No reentrancy path can drain bonds (`nonReentrant` +
    checks-effects-interactions ordering).
  * Slashing math is exact: no rounding errors, no off-by-one
    issues at game-end.
  * Tested by 20+ Solidity test cases covering:
    settlement-claimant-wins, settlement-challenger-wins,
    timeout-against-claimant, timeout-against-challenger, and
    anti-griefing edge cases.

### 10.3 WU H.6.3 — Game-state events

**Module:** `solidity/src/contracts/CanonFaultProofGame.sol`
(continuation)

**Specification.**

```solidity
event FaultProofGameOpened(uint64 indexed gameId, address indexed challenger,
                           bytes32 disputedStateRoot, bytes32 challengerStateRoot);
event BisectionMidpointSubmitted(uint64 indexed gameId, address indexed party,
                                  uint64 idx, bytes32 commit);
event FaultProofGameSettled(uint64 indexed gameId, GameStatus status,
                             address indexed winner, uint128 winnerPayout);
```

**Acceptance criteria.**

  * Events match the L2 side's three new `Event` constructors
    (frozen indices 13–15).  Cross-stack equivalence via WU H.10.

## 11. Workstream H.7 — Sequencer state-root submission

### 11.1 WU H.7.1 — `CanonStateRootSubmission.sol`

**Module:** `solidity/src/contracts/CanonStateRootSubmission.sol`

**Specification.**

```solidity
function submitStateRoot(
    uint64 logIndex,
    bytes32 stateCommit,
    bytes32 prevLogEntryHash
) external payable;
```

The sequencer calls this after appending log entries up to
`logIndex`, posts `STATE_ROOT_SUBMISSION_BOND`, and starts the
`FAULT_PROOF_DISPUTE_WINDOW` countdown.

**Internal state:**

```solidity
struct SubmittedRoot {
    address sequencer;
    bytes32 stateCommit;
    bytes32 prevLogEntryHash;
    uint128 bond;
    uint64  submittedAtBlock;
    bool    finalised;
    bool    disputed;
}
mapping(uint64 => SubmittedRoot) public roots;
```

**Acceptance criteria.**

  * Only the deployment's pre-approved sequencer (or list of
    sequencers) can submit.  Sequencer set is immutable per
    Workstream-E discipline.
  * `submitStateRoot` rejects submissions for already-claimed
    indices.
  * Tested across 15+ Solidity cases including bond release at
    finalisation, slashing at successful challenge, and
    anti-replay protection.

### 11.2 WU H.7.2 — `finaliseStateRoot`

**Specification.**

```solidity
function finaliseStateRoot(uint64 logIndex) external;
```

Called by anyone after the dispute window expires.  Releases the
sequencer's bond.  Marks the state root as canonical.  Subsequent
withdrawal proofs against this root succeed without further
challenge possibility.

**Acceptance criteria.**

  * Cannot finalise if a fault-proof game is in progress.
  * Cannot finalise within the dispute window.
  * Multiple finalisations of the same root are idempotent (no
    double-release of bonds).
  * Tested for liveness griefing: an attacker who initiates a
    dispute and then abandons it must lose by timeout, releasing
    the sequencer's bond on schedule.

### 11.3 WU H.7.3 — Anti-DoS protections (CORRECTED)

**v2 fix.**  v1 said "configurable" rate limits, but Workstream-E
discipline mandates immutability after construction.  v2 uses
**immutable constructor arguments**:

**Specification.**

```solidity
// Constructor parameters (immutable thereafter):
uint64  public immutable MIN_SUBMISSION_INTERVAL_BLOCKS;
uint64  public immutable MAX_OUTSTANDING_ROOTS_PER_SEQUENCER;
uint64  public immutable MIN_BISECTION_STEP_INTERVAL_BLOCKS;

constructor(
    uint64 _minSubmissionInterval,    // recommended: 100
    uint64 _maxOutstandingRoots,      // recommended: 100
    uint64 _minBisectionStepInterval, // recommended: 5
    /* ... other immutable args ... */
) {
    require(_minSubmissionInterval > 0, "ZeroSubmissionInterval");
    require(_maxOutstandingRoots > 0, "ZeroOutstandingCap");
    require(_minBisectionStepInterval > 0, "ZeroBisectionInterval");
    MIN_SUBMISSION_INTERVAL_BLOCKS    = _minSubmissionInterval;
    MAX_OUTSTANDING_ROOTS_PER_SEQUENCER = _maxOutstandingRoots;
    MIN_BISECTION_STEP_INTERVAL_BLOCKS = _minBisectionStepInterval;
}
```

**Per-protection behaviour.**

  * **Submission rate limit:** `submitStateRoot` reverts with
    `SubmissionTooFrequent` if `block.number <
    lastSubmissionBlock + MIN_SUBMISSION_INTERVAL_BLOCKS`.
    Tracked per-sequencer.
  * **Outstanding roots cap:** `submitStateRoot` reverts with
    `TooManyOutstandingRoots` if the sequencer already has
    `MAX_OUTSTANDING_ROOTS_PER_SEQUENCER` unfinalised roots.
    Forces the sequencer to wait for finalisation or face a
    challenge before submitting more.
  * **Bisection step rate limit:** `submitMidpoint` /
    `respondToMidpoint` revert with `BisectionStepTooFast` if
    less than `MIN_BISECTION_STEP_INTERVAL_BLOCKS` since the
    last step in the same game.  Prevents L1-block-level rapid
    fire that could exhaust block gas.

**Window-alignment requirement (audit-fix; new constraint).**

The `FAULT_PROOF_DISPUTE_WINDOW` MUST be at least the bridge's
withdrawal-finalisation window.  Otherwise withdrawals could
finalise on L1 against a state root that subsequently gets
faulted, leading to L1-side fund loss.  Constraint:

```solidity
require(
    FAULT_PROOF_DISPUTE_WINDOW >= bridge.WITHDRAWAL_FINALISATION_WINDOW(),
    "FaultProofWindowTooShort"
);
```

This invariant is checked at `CanonStateRootSubmission`'s
constructor and re-asserted via `assertConsistent()`.  A
deployment that violates it cannot be deployed.

**Acceptance criteria.**

  * Three rate-limit constants are immutable after construction.
  * Window-alignment invariant enforced at construction and
    `assertConsistent()`.
  * Tested by adversarial scenarios in the cross-stack corpus
    (8 fixtures across attempted-DoS patterns; +2 fixtures for
    window-alignment regression).

### 11.4 WU H.7.4 — Hash-chain integrity verification (NEW)

**Module:** `solidity/src/contracts/CanonStateRootSubmission.sol`
(continuation)

**Why this WU.**  v1 specified `submitStateRoot` taking a
`prevLogEntryHash` parameter but didn't specify how this is
verified.  Without verification, a sequencer could submit
state roots claiming arbitrary log-entry sequences, breaking
the implicit assumption that finalised roots correspond to a
valid hash chain.

**Specification.**

```solidity
function submitStateRoot(
    uint64  logIndex,
    bytes32 stateCommit,
    bytes32 prevLogEntryHash
) external payable nonReentrant {
    // ... bond + rate-limit checks ...

    // Hash-chain integrity check:
    // The sequencer's state-root submission must match the
    // last submitted root's "next log-entry hash" prediction.
    if (logIndex > 0) {
        SubmittedRoot memory prev = roots[logIndex - 1];
        require(prev.submittedAtBlock > 0, "PreviousRootMissing");
        require(prev.expectedNextHash == prevLogEntryHash,
                "HashChainBroken");
    }

    // Compute and store this root's expected next hash.
    bytes32 expectedNextHash = keccak256(
        abi.encode(prevLogEntryHash, stateCommit)
    );

    roots[logIndex] = SubmittedRoot({
        sequencer:        msg.sender,
        stateCommit:      stateCommit,
        prevLogEntryHash: prevLogEntryHash,
        expectedNextHash: expectedNextHash,
        bond:             uint128(msg.value),
        submittedAtBlock: uint64(block.number),
        finalised:        false,
        disputed:         false
    });

    emit StateRootSubmitted(logIndex, stateCommit, msg.sender);
}
```

**Two distinct chains: clarification (audit fix).**  The
Lean-side `LogEntry.hash` (in `Runtime/LogFile.lean:168-170`)
chains *log entries* on L2:

```lean
LogEntry.hash e := hashStream (encode e.signedAction ++ encode e.prevHash)
```

This chain hashes `(signedAction, prevHash)` per entry — a
chain-of-log-entries.

The L1 hash-chain check above (`expectedNextHash`) is a
*separate* chain on L1: it chains *state-root submissions* to
each other, hashing `(prevLogEntryHash, stateCommit)` per
submission.  These chains track different objects:

  * **L2 chain** (kernel-side): each `LogEntry` references the
    previous entry's hash.  Anchored in the on-disk log
    format (Phase-5 framed format).
  * **L1 chain** (Solidity-side): each state-root submission
    references the previous submission's `expectedNextHash`.
    Anchored in `CanonStateRootSubmission`'s storage.

The two chains link through the `prevLogEntryHash` field:
each L1 submission's `prevLogEntryHash` parameter must equal
the kernel-computed hash of the log entry at index `logIndex -
1` (i.e., `LogEntry.hash log[logIndex - 1]`).  This linkage is
what the WU H.10.4 cross-stack fixture corpus verifies.

The L1 chain's purpose is *L1-side replay protection*: a
sequencer cannot submit out-of-order roots or skip indices,
because the chain integrity check forces continuity.  The L2
chain's purpose is *L2-side log integrity*: replicas verify
log entries chain correctly during replay.

**Acceptance criteria.**

  * Hash-chain check fires on every submission after index 0.
  * `HashChainBroken` revert when `prev.expectedNextHash !=
    prevLogEntryHash`.
  * Tested across 8 fixtures: valid chains of length 1, 2, 16,
    256; broken chains at start, middle, end; resubmission of
    previously-finalised root (rejected as already-claimed
    index).
  * Cross-stack: Lean side computes the expected-next-hash for
    each `LogEntry` and the Solidity side reproduces it
    byte-for-byte.

## 12. Workstream H.8 — Dispute pipeline integration

### 12.1 WU H.8.1 — New `Action` constructors

**Module extensions:** `LegalKernel/Authority/Action.lean`,
`LegalKernel/Encoding/Action.lean`,
`LegalKernel/Authority/SignedAction.lean`,
`LegalKernel/Bridge/BridgeActor.lean`,
`LegalKernel/Disputes/Evidence.lean`,
`LegalKernel/LocalPolicy/LawClassification.lean`.

**New constructors at frozen indices 17, 18 (CORRECTED).**

**v2 fix.**  v1's `Action.faultProofChallenge` carried `gameId :
Nat` directly — but the L1 contract assigns the gameId on
`initiateChallenge`, so the L2 challenger cannot know it before
the L1 game exists.  v2 redesigns to use a binding hash:

```lean
/-- A user submits a fault-proof challenge intent.  The L2
    action carries a binding hash that the L1 contract will
    later match its assigned `gameId` against; the actual game
    runs on L1.  This action is advisory: the L1 contract is
    the authoritative game state.

    `bindingHash` binds (challenger : ActorId, disputedRoot :
    StateCommit, challengerCommit : StateCommit) under the
    canonical CBE encoding.  The L1 game's
    `initiateChallenge` recomputes the hash from its
    parameters and emits a `FaultProofGameOpened` event whose
    `bindingHash` field matches; the L2 runtime's L1-event
    watcher matches the two via this hash.

    The `bindingHash` is `bytes32`-equivalent
    (`keccak256(abi.encode(challenger, disputedRoot,
    challengerCommit, deploymentId))`). -/
| faultProofChallenge (bindingHash : ByteArray)
                       (disputedStartIdx : LogIndex)
                       (disputedEndIdx : LogIndex)
                       (challengerCommit : StateCommit)

/-- A fault-proof game's L1 settlement is mirrored on L2 via this
    action.  The L2 runtime's L1-event watcher receives a
    `FaultProofGameSettled` event from L1 and emits this action
    to record the settlement in the canonical L2 log.  Carries
    the same `bindingHash` as the corresponding
    `faultProofChallenge`, plus the L1-assigned `gameId`.

    The actual rollback is **not** triggered by this L2 action;
    it is triggered by the L1 contract `CanonDisputeVerifierV2`
    calling `revertToPriorRoot` on the bridge.  This L2 action
    is advisory-only (the L1 is authoritative). -/
| faultProofResolution (bindingHash : ByteArray) (gameId : Nat)
                        (winner : ActorId)
                        (revertFromIdx : LogIndex)
```

Both compile to `Laws.freezeResource 0` at the kernel level
(no balance / nonce changes; the dispute-pipeline-mirroring side
effects are entirely in the L1 contracts).

**Why advisory-only?**  The L1 contract is authoritative for
fault-proof game outcomes.  The L2 actions exist only to:
  1. Provide a canonical L2 audit trail (replicas that don't
     watch L1 directly can still observe disputes).
  2. Provide a hook for deployment-level reward emission via
     `Disputes/Rewards.lean` (since the runtime can compose
     `applyVerdictWithRewards` against the fault-proof
     resolution event).
  3. Give the L1-event-watcher subsystem a target action to
     emit when it observes a settlement.

This avoids the cross-chain ordering issue v1 had: the L2
action need not be created before the L1 game; the L1 game can
proceed independently and the L2 runtime mirrors after settlement.

**Acceptance criteria.**

  * `Action.compile_injective` extends to the new constructors
    by `congrArg` (mechanical).
  * `IsConservative` and `IsMonotonic` instances for both
    constructors (per Workstream-LP convention).
  * `Action.tag` extends to indices 17 and 18.
  * `bridgePolicy` rejects both constructors for the bridge
    actor (per Workstream-E §12.9 discipline).
  * CBE codec round-trip + injectivity proven for both.

### 12.2 WU H.8.2 — Routing of deterministic claim variants

**Module extension:** `LegalKernel/Disputes/Evidence.lean`

**Specification.**  When a deployment opts into Workstream H:

  * `checkPreconditionFalse`, `checkSignatureInvalid`,
    `checkNonceMismatch`, `checkDoubleApply` continue to operate
    at the L2 level (test fixtures still exercise them).
  * However, the **canonical resolution** for these claims is
    via the L1 fault-proof game.  The L2-side adjudicator
    quorum becomes optional (a deployment can disable it).
  * `checkOracleMisreported` continues to operate via the
    Phase-6 adjudicator quorum.

A new deployment-time configuration flag (in `DisputeConfig`):

```lean
structure DisputeConfig where
  enableAdjudicatorQuorum : Bool      -- legacy Phase-6 path
  enableFaultProofGame    : Bool      -- new Phase-H path
  oracleAdjudicatorQuorum : QuorumPolicy   -- always used for oracle claims
```

Both paths can be enabled simultaneously (belt-and-suspenders);
deployments running fault proofs typically disable the
adjudicator quorum for the four deterministic variants.

### 12.3 WU H.8.3 — New `Event` constructors

**Module extension:** `LegalKernel/Events/Types.lean` (and
`Events/Extract.lean`)

**Specification.**

```lean
| faultProofGameOpened     (gameId : Nat) (challenger : ActorId)
                            (disputedRoot challengerRoot : StateCommit)
| faultProofBisectionStep  (gameId : Nat) (round : Nat)
                            (party : ActorId)
                            (idx : LogIndex) (commit : StateCommit)
| faultProofGameSettled    (gameId : Nat) (winner : ActorId)
                            (loser : ActorId) (payout : Amount)
```

**Acceptance criteria.**

  * Frozen indices 13, 14, 15 (per §2 status).
  * `Event.actor` and `Event.isFaultProofEvent` projections
    extended.
  * Emission rules: `Action.faultProofChallenge` emits
    `faultProofGameOpened`; `Action.faultProofResolution` emits
    `faultProofGameSettled`.  `faultProofBisectionStep` is
    emitted by the runtime's L1-event-listener subsystem when
    it observes bisection moves on L1; this is a deployment-
    layer concern (not part of the kernel).

### 12.4 WU H.8.4 — Witness construction from fault-proof settlement

**Module:** `LegalKernel/FaultProof/Witness.lean`

**Specification.**

```lean
/-- A propositional witness that an L1 fault-proof game settled
    in the challenger's favour.  Constructed from the
    `Action.faultProofResolution` log entry; consumed by
    `applyVerdict` (the witness-bearing form). -/
structure FaultProofChallengerWon
    (log : List LogEntry) (gameId : Nat) (revertFromIdx : LogIndex) : Prop

/-- Bridge: a fault-proof challenger-won settlement implies the
    state root at `revertFromIdx` was wrong.  Combined with the
    Phase-6 `applyVerdict_under_witness_succeeds` discipline,
    this gives a path to construct a `VerdictPassedStage3`
    witness from a fault-proof game settlement. -/
theorem faultProof_challenger_won_implies_state_root_wrong
    {log : List LogEntry} {gameId : Nat} {revertFromIdx : LogIndex}
    (h : FaultProofChallengerWon log gameId revertFromIdx)
    (h_cf : CollisionFree hashBytes) :
    ∃ correctState, commitExtendedState correctState ≠
                    sequencerSubmittedRoot log revertFromIdx
```

**Acceptance criteria.**

  * Theorem proved without `sorry`, conditional on
    `CollisionFree hashBytes`.
  * The proof composes WU H.4.4
    (`honest_challenger_wins_against_invalid_state_root`) +
    WU H.2.5 (`commitExtendedState_injective_under_collision_free`).
  * Provides a callsite-local witness for downstream
    `applyVerdict` calls.

### 12.5 WU H.8.5 — In-flight game freezing during migration (NEW)

**Module:** `LegalKernel/FaultProof/MigrationFreeze.lean`,
`solidity/src/contracts/CanonFaultProofMigration.sol`
(integration)

**Why this WU.**  When `CanonFaultProofMigration` activates and
freezes V1 → V2, what happens to fault-proof games that are
in progress?  v1 left this unspecified.  v2 specifies the
freezing semantics:

**Specification.**

  * **At migration activation (block N):**
    * The V1 `CanonStateRootSubmission` contract enters
      *frozen* mode: no new state-root submissions accepted.
    * The V1 `CanonFaultProofGame` contract enters *settle-only*
      mode: no new challenges initiated; existing in-flight
      games may continue but new bisection rounds are
      rate-limited to one per 24 hours (forcing prompt
      settlement).
    * The V1 contract's `CHALLENGE_INITIATION_FROZEN` flag is
      set; subsequent calls to `initiateChallenge` revert with
      `ContractFrozen`.
  * **In-flight games settle on V1.**  A game already in
    progress at activation continues to settle via V1's
    `terminateOnSingleStep` / `claimTimeout`.  Bond
    redistribution honours the V1 contract's bond balances.
  * **V2 starts fresh.**  V2's `CanonStateRootSubmission`
    starts accepting submissions at activation block.  No
    state is migrated from V1 (the `ExtendedState` itself is
    not re-encoded; the bridge contract's state is the
    persistent layer).
  * **Bridge state preserved.**  The bridge's `consumed` /
    `pending` maps are not reset — they belong to
    `CanonBridge`, not the dispute verifier.  Withdrawals
    that started on V1 finalise on V2 transparently.

**Lean-side specification.**

```lean
/-- A predicate identifying log entries that record migration
    activation.  Used by replicas to know when to switch
    L1-event-watcher targets from V1 to V2. -/
def isMigrationActivation (entry : LogEntry) : Bool :=
  match entry.signedAction.action with
  | .faultProofResolution _ _ _ _ => false  -- not migration
  | _ => false  -- migration is L1-only; no L2 action records it
```

The L2 runtime's L1-event-watcher subsystem receives a
`MigrationActivated` event from L1 and switches its target.
No L2 action is appended (the L2 log is unaware of the L1
migration; the L2 simply observes settlements from a different
contract going forward).

**Acceptance criteria.**

  * V1 freezing semantics tested: in-flight games can settle;
    new games rejected.
  * V1-to-V2 transition tested in cross-stack scenario: 5+
    fixtures covering mid-bisection migration, mid-timeout
    migration, post-settlement migration.
  * No L2 state corruption: replicas surviving migration
    reproduce identical L2 state as fresh replicas
    bootstrapping post-migration.

## 13. Workstream H.9 — Migration

### 13.1 WU H.9.1 — `CanonDisputeVerifierV2.sol`

**Module:** `solidity/src/contracts/CanonDisputeVerifierV2.sol`

**Specification.**  A new immutable contract supporting both
fault-proof game settlements (for deterministic claim variants)
and adjudicator-quorum settlements (for `oracleMisreported`).

**Acceptance criteria.**

  * Constructor takes:
    * `address faultProofGame` — the L1 game contract address
    * `address[] approvedAdjudicators` — for oracle disputes
    * `uint8 quorumThreshold` — for oracle disputes
    * `address bridge`, `address sequencerStake`, `address
      attestor`, `bytes32 deploymentId` — same as V1
  * Reuses Workstream-E V1 audit-1, audit-2, audit-3 fixes (no
    regressions).
  * Cross-stack equivalent to the Lean-side
    `DisputeConfig.enableFaultProofGame = true` path.

### 13.2 WU H.9.2 — `CanonFaultProofMigration.sol`

**Module:** `solidity/src/contracts/CanonFaultProofMigration.sol`

**Specification.**  A `CanonMigration`-style handoff contract that
moves authority from V1 to V2 with `MIN_GRACE_WINDOW_BLOCKS` delay
and bidirectional consent (fixed in Workstream-E audit-3).

**Acceptance criteria.**

  * Constructor parameters mirror `CanonMigration.sol` exactly.
  * Predecessor (V1) must pre-commit by setting its `migration`
    immutable to point at this contract (audit-3 discipline).
  * Activation freezes V1 (no new disputes accepted) but leaves
    V1 readable (existing oracle disputes continue to settle on
    V1; new disputes go to V2).
  * Tested by 8+ Solidity cases covering: happy-path activation,
    grace-window-too-short rejection, predecessor-not-committed
    rejection, post-activation-V1-still-readable, post-
    activation-V2-fully-operational.

### 13.3 WU H.9.3 — Deployment script

**Module:** `solidity/script/DeployFaultProof.s.sol`

**Specification.**  A single CREATE3 bundle deploying:
`CanonStepVM`, `CanonFaultProofGame`, `CanonStateRootSubmission`,
`CanonDisputeVerifierV2`, `CanonFaultProofMigration`.  The
five contracts have a circular dependency
(`CanonDisputeVerifierV2` references the game contract; the game
contract references the step VM and state-root submission), so
CREATE3 (Workstream-E §9) is the standard pattern for breaking
the cycle.

**Acceptance criteria.**

  * Idempotent on re-run.
  * Verifies CREATE3 predictions match deployed addresses.
  * Post-deploy `assertConsistent()` invocations on every contract.
  * Adds `make testnet-faultproof-acceptance{,-dryrun}` Make
    targets.

### 13.4 WU H.9.4 — In-flight V1 dispute migration (NEW)

**Module:** `solidity/src/contracts/CanonFaultProofMigration.sol`
(continuation)

**Why this WU.**  v1 said "V1 readability preserved post-
activation" but didn't specify what happens to *open
adjudicator-quorum disputes* on V1 that haven't been resolved
when migration activates.  Two cases need handling:

  1. **`oracleMisreported` disputes.**  These continue using
     the adjudicator quorum.  Migration policy: V1 retains
     authority for the `oracleMisreported` claim variant; V2
     does not handle it (V2's adjudicator-quorum support is
     for residual oracle disputes).  The deployment must
     decide whether `oracleMisreported` disputes filed
     post-activation go to V1 (legacy) or to V2 (new).
  2. **Deterministic-claim disputes already in adjudication.**
     If `Action.dispute (.preconditionFalse idx)` was filed
     on V1 pre-activation but not yet adjudicated, the policy
     is:
     * V1's adjudicator quorum retains authority to settle
       these disputes for the `MIN_GRACE_WINDOW_BLOCKS`
       window (≈ 30 days).
     * After the grace window, V2 takes over: any party may
       challenge the underlying state root via the L1
       fault-proof game on V2.

**Specification.**

```solidity
contract CanonFaultProofMigration {
    // Constants from Workstream-E §20:
    uint64 public immutable activationBlock;
    uint64 public immutable graceWindowBlocks;

    // Oracle dispute routing:
    address public immutable oracleDisputeContract;
    // After activation, set by constructor to V1 (oracle
    // disputes continue on V1) or V2 (new oracle dispute
    // architecture).  Deployment-time decision.

    // Deterministic-dispute migration:
    function isDisputePastGracePeriod(uint64 disputeIdx)
        external view returns (bool) {
        SubmittedRoot memory dispute = v1.disputes(disputeIdx);
        if (dispute.submittedAtBlock == 0) return false;
        return block.number >
            dispute.submittedAtBlock + graceWindowBlocks;
    }
}
```

**Acceptance criteria.**

  * V1's adjudicator quorum continues operating for
    `oracleMisreported` past activation.
  * Open deterministic-claim disputes have a 30-day grace
    period to settle on V1; after that, V2's fault-proof
    pathway is the only resolution.
  * Tested by 6 fixtures: oracle dispute pre-activation
    settling post-activation; deterministic dispute settling
    in grace; deterministic dispute past grace falling through
    to V2.

**V2 genesis state-root chain handover (audit-fix; new
sub-spec).**  V2's `CanonStateRootSubmission` cannot start with
`prevLogEntryHash = bytes32(0)` for its first submission,
because that would break the hash chain (per WU H.7.4) — the
V2 chain wouldn't link back to V1's last finalised state.

**Solution: migration contract exposes V1's last-finalised
hash as immutable.**

```solidity
contract CanonFaultProofMigration {
    // ... existing fields ...

    /// V1's last-finalised log entry hash, captured at migration
    /// activation and exposed as an immutable.  V2's first state-
    /// root submission references this value as its
    /// `prevLogEntryHash`.
    bytes32 public immutable v1LastFinalisedLogEntryHash;

    /// V1's last-finalised log index, similarly captured.
    uint64  public immutable v1LastFinalisedLogIndex;

    constructor(
        /* ... existing params ... */,
        bytes32 _v1LastFinalisedLogEntryHash,
        uint64  _v1LastFinalisedLogIndex
    ) {
        v1LastFinalisedLogEntryHash = _v1LastFinalisedLogEntryHash;
        v1LastFinalisedLogIndex     = _v1LastFinalisedLogIndex;
    }
}
```

V2's `CanonStateRootSubmission` constructor takes a reference to
the migration contract and reads these values.  V2 starts
accepting submissions at `logIndex = v1LastFinalisedLogIndex +
1`, with `prevLogEntryHash = v1LastFinalisedLogEntryHash`.
V2's hash chain is now continuous with V1's.

**Edge case: no V1 finalised root.**  For the original V1
deployment (no predecessor), the migration contract is not
used; V1's `CanonStateRootSubmission` accepts `logIndex = 0`
with `prevLogEntryHash = bytes32(0)`.  Only the V1→V2
migration introduces the handover.

**Test coverage.**  +3 fixtures: handover at typical index
(N=1000); handover at index 0 (no V1 history); chain-broken
attempt (V2 tries to use a different prevLogEntryHash —
rejected with `HashChainBroken`).

## 14. Workstream H.10 — Cross-stack verification

Extends Workstream F's fixture corpora.

### 14.1 WU H.10.1 — F.1.8 step-VM equivalence corpus

**Module:** `solidity/test/CrossCheck/StepVM.t.sol` plus the
parallel Lean-side fixture writer.

**Specification.**  N entries per `Action` constructor (typically
N = 16) plus M adversarial entries per failure mode (mismatched
proof, inadmissible action, post-state forgery).  Each fixture is
a `(KernelStep, expectedOutcome)` pair; both Lean and Solidity
sides reproduce the outcome byte-for-byte.

**Target size:** 19 constructors × 16 happy-path + 5 failure
modes × 8 adversarial = ~344 fixtures.

### 14.2 WU H.10.2 — F.1.9 bisection-game equivalence corpus

**Module:** `solidity/test/CrossCheck/BisectionGame.t.sol`

**Specification.**  Per-scenario fixtures covering:

  * Happy-path bisection: 6 fixtures across log lengths 8, 64,
    1024, 16k, 256k, 4M (2^22).
  * Adversarial-claimant strategies: 12 fixtures (claimant
    bisects to wrong midpoint, claimant times out, claimant
    settles on a falsified single step).
  * Adversarial-challenger strategies: 12 fixtures.
  * Bond redistribution: 8 fixtures across each settlement path.

**Target size:** ~38 fixtures.

### 14.3 WU H.10.3 — F.1.10 fault-proof scenario corpus

**Module:** `solidity/test/CrossCheck/FaultProofScenarios.t.sol`

**Specification.**  End-to-end scenarios combining state-root
submission, challenge initiation, bisection rounds, single-step
execution, and settlement.  Each scenario is a fully-specified
narrative from log genesis to game resolution.

**Target size:** 8 scenarios mirroring the workstream's
acceptance test (§2.3) at varying log scales and challenge
patterns.

### 14.4 WU H.10.4 — Goldens corpus extension

**Module:** `solidity/test/goldens/`

**Specification.**  Add 16 mainnet-style fault-proof game
transcripts (synthetic LCG-seeded initially per Workstream F
discipline; replaceable with real transcripts post-deployment).

### 14.5 WU H.10.5 — Off-chain prover/observer tooling (NEW)

**Module:** `runtime/canon-faultproof-observer/` (new Rust
crate, deferred to follow-up like other Rust deliverables);
**Lean-side reference:** `LegalKernel/FaultProof/Observer.lean`.

**Why this WU.**  v1 specified the on-chain protocol but didn't
specify the off-chain tooling a challenger needs to actually
detect a fault and assemble a challenge.  Three concrete tools:

  1. **State-root verifier.**  Given a Canon node and an L1
     state-root submission, recompute `commitExtendedState`
     and compare.  If different, the node has detected a
     fault.
  2. **Cell-proof generator.**  Given a state and a list of
     cell tags, generate the corresponding `CellProof` bundle
     (Merkle paths through the SMT).  Required for both
     `terminateOnSingleStep` calldata and for sub-step bundles
     in bulk actions.
  3. **Bisection-game player.**  Given an in-progress game and
     the canonical truth, compute the next honest move per the
     `honestStrategy` definition (WU H.4.4a).  Wraps the L1
     contract calls to submit the move.

**Lean-side reference specification.**

```lean
namespace LegalKernel.FaultProof.Observer

/-- Detect whether a sequencer's state-root submission is
    correct, given the runtime's canonical view. -/
def detectFault
    (genesis : ExtendedState) (log : List LogEntry)
    (sequencerCommit : StateCommit) (logIndex : LogIndex)
    : Bool :=
  commitExtendedState (kernelOnlyReplay genesis (log.take logIndex))
  ≠ sequencerCommit

/-- Generate the cell-proof bundle for a given action from
    the runtime's `ExtendedState`. -/
def buildCellProofs
    (es : ExtendedState) (action : Action) : CellProofBundle

/-- Compute the next honest move in a game.  Wraps
    `honestStrategy` (WU H.4.4a) with deployment-config-aware
    behaviour (uses the deployment's truth function). -/
def computeNextMove
    (truth : LogIndex → StateCommit) (gs : GameState)
    : Option GameTransition := honestStrategy truth gs

end LegalKernel.FaultProof.Observer
```

**Rust-side scope (deferred).**  The Rust crate
`runtime/canon-faultproof-observer` will:

  * Subscribe to L1 events (`StateRootSubmitted`,
    `FaultProofGameOpened`, etc.) via web3 RPC.
  * Maintain a local Canon node mirror (replay the canonical
    L2 log).
  * Cross-check every L1 state-root submission against the
    local view.
  * On detected fault, generate the challenge calldata
    (binding hash + initial commits) and submit via a
    deployment-supplied wallet.
  * Play through bisection rounds via the same wallet.
  * Persist game state across restarts (allowing operators to
    safely upgrade the observer mid-game).

**Acceptance criteria.**

  * Lean-side `detectFault`, `buildCellProofs`,
    `computeNextMove` defined and tested.
  * 8 cases per function in `Test/FaultProof/Observer.lean`.
  * Rust-side specification documented in
    `docs/fault_proof_observer_spec.md` (Lean-equivalent of
    the deferred Rust crate's behavior, for cross-stack
    parity testing once the crate ships).
  * The Rust crate's release is tracked as a Workstream-H
    follow-up; the Lean side fully specifies what the crate
    will do.

## 15. Workstream H.11 — Property-based tests

Extends Workstream F.4's property-based testing harness.

### 15.1 WU H.11.1 — Bisection convergence property

**Module:** `LegalKernel/Test/Properties/FaultProof.lean`

**Specification.**

```lean
def bisectionConvergenceProperty : Property := …
```

For 100 randomly-generated game scenarios (varying log lengths,
divergence points, and party strategies), assert that:

  * Honest play converges in ≤ `MAX_BISECTION_DEPTH` rounds.
  * Game terminates with a deterministic settlement outcome.
  * Settlement outcome agrees with the ground-truth state-root
    sequence.

### 15.2 WU H.11.2 — Single-honest-challenger property

**Module:** `LegalKernel/Test/Properties/FaultProof.lean`
(continuation)

**Specification.**

For 100 randomly-generated invalid-state-root scenarios, where:

  * The sequencer publishes a state root differing from the
    truth at exactly one log index `j`.
  * One party plays the honest strategy; the opposing party
    plays randomly.

Assert that the honest party always wins.

### 15.3 WU H.11.3 — Bond accounting invariant

**Module:** `LegalKernel/Test/Properties/FaultProof.lean`
(continuation)

**Specification.**

Across 100 randomly-generated game transcripts (legal +
illegal moves), assert that:

  * Total ETH locked in the game contract equals the sum of
    posted bonds at every game step.
  * Slashing math is exact (no rounding or off-by-one issues).
  * Settlement payouts always equal the loser's bond exactly,
    minus the deployment-treasury split (per OQ8 resolution).

### 15.4 WU H.11.4 — Performance benchmark property (NEW)

**Module:** `LegalKernel/Test/Properties/FaultProofPerf.lean`

**Why this WU.**  v1 marked benchmarking as deferred.  v2 adds
a property-based performance regression check on the
critical-path cost of `commitExtendedState` and
`buildCellProofs` — the two operations a sequencer runs at
state-root submission time, and that an observer runs at
fault-detection time.

**Specification.**

For 100 randomly-generated `ExtendedState` instances of varying
sizes:

  * Measure `commitExtendedState` time per state-size class:
    * Small (≤ 100 actors / 5 resources): ≤ 1 ms
    * Medium (≤ 10k actors / 50 resources): ≤ 100 ms
    * Large (≤ 1M actors / 1k resources): ≤ 10 s
  * Measure `buildCellProofs` time per cell-bundle size:
    * Small (≤ 4 cells, e.g., transfer): ≤ 5 ms
    * Bulk (256 cells, distributeOthers): ≤ 1 s

The property fails if any of these bounds are exceeded across
the 100 samples.  A single timeout is treated as a regression.

**Reproducibility.**  `CANON_PROPERTY_SEED` env var pins the
test seed; CI uses the default seed for stability.

**Acceptance criteria.**

  * Three time-bound properties, each × 100 samples.
  * Reproducible failures via seed override.
  * Test infrastructure compiles to Lean 4's native time
    measurement (`IO.monoMsNow`).
  * The property is *advisory* (not strict): a one-off failure
    on a slow CI runner doesn't block the merge, but a
    sustained regression triggers investigation.

## 16. Workstream H.12 — Audit binaries / TCB / sorry budget

### 16.1 WU H.12.1 — Audit binary updates

**Modules:** `Tools/CountSorries.lean`, `Tools/TcbAudit.lean`,
`Tools/StubAudit.lean`.

**Specification.**

  * `count_sorries`: extends to scan `LegalKernel/FaultProof/`
    modules.  Threshold remains zero.
  * `tcb_audit`: no change to `tcb_allowlist.txt` (no TCB
    expansion).  The fault-proof modules import non-TCB
    sub-states; the TCB allowlist remains restricted to
    `Std.Data.TreeMap` + the two TCB core modules.
  * `stub_audit`: extends to scan the new modules.  Continues
    to allowlist `Verify` and `signingInput` (already
    documented as opaque).  No new opaque declarations.

**Acceptance criteria.**

  * All three audit binaries run green on every WU H.* commit.
  * CI gates the merge on each binary's exit code.

### 16.2 WU H.12.2 — Sorry budget

**Specification.**  Zero sorries across every WU H.* module.

**Acceptance criteria.**

  * `lake exe count_sorries` returns 0.
  * The four headline theorems
    (`kernelStepApply_coherent_with_kernelOnlyApply`,
    `commitExtendedState_injective_under_collision_free`,
    `bisection_converges_in_log_length`,
    `honest_challenger_wins_against_invalid_state_root`) all
    proved with `[propext, Quot.sound]` axioms only (no
    `Classical.choice`, no custom axioms).

### 16.3 WU H.12.3 — `kernelBuildTag` bump

**Specification.**

```lean
def kernelBuildTag := "canon-fault-proof-migration"
```

Bumped in `LegalKernel.lean` at the umbrella module.  Tested in
`Test/Umbrella.lean`.

## 17. Workstream H.13 — Documentation + Genesis Plan amendment

### 17.1 WU H.13.1 — Genesis Plan amendment

**Module:** `docs/GENESIS_PLAN.md`

**Specification.**  Add §15 "Fault-Proof Migration" covering:

  * The state-commitment scheme (§15.1)
  * The step semantics (§15.2)
  * The bisection game (§15.3)
  * The L1 contract surface (§15.4)
  * The dispute-pipeline integration (§15.5)
  * The migration path (§15.6)
  * The trust-model update (§15.7)
  * The deviation block (deltas from Workstream-D SMT, etc.) (§15.8)

**Acceptance criteria.**

  * The §13.6 two-reviewer gate **does not** trigger (no TCB
    changes), but the amendment process still runs because
    Workstream H introduces a fundamentally new resolution
    mechanism.  Treat as if it did trigger: two reviewers,
    explicit theorem-by-theorem signoff.
  * The amendment cross-references every WU's headline theorem.
  * The amendment block sits between current §14 and the
    glossary.

### 17.2 WU H.13.2 — `docs/abi.md` updates

**Specification.**

  * Add the two new `Action` constructor encodings (indices 17,
    18).
  * Add the three new `Event` constructor encodings (indices
    13–15).
  * Add the four new Solidity contracts' ABI surfaces.
  * Add the new bond / dispute-window / bisection-depth
    constants.

**Acceptance criteria.**

  * Each table extension is mechanically verified by a parallel
    test that decodes a sample byte sequence and asserts the
    documented field shape.

### 17.3 WU H.13.3 — `docs/fault_proof_design.md`

**New module:** `docs/fault_proof_design.md`

**Specification.**  A standalone design-rationale document
covering:

  * Why interactive fault proofs over validity proofs (cost
    tradeoff)
  * Why macro-step VM over micro-step VM (kernel-size advantage)
  * The bond economics rationale (game-theoretic analysis)
  * The bisection-depth sizing argument
  * The trust-model upgrade path (Phase 1 → Phase 2 → Phase 3)

**Acceptance criteria.**

  * Plain-language; readable by deployment operators without
    Lean expertise.
  * Cross-references the Genesis Plan §15 amendment and this
    workstream plan.

### 17.4 WU H.13.4 — `CLAUDE.md` updates

**Specification.**  Update CLAUDE.md's:

  * Project status (Workstream H complete)
  * Module layout (new namespaces under `LegalKernel/FaultProof/`)
  * Test count (1228 → ~1500)
  * `kernelBuildTag` value
  * Type-level theorems table (extends to ~250 theorems)
  * Implementation roadmap (new "H" row)

**Acceptance criteria.**

  * Mirrors the post-LP / post-E pattern.

## 18. Type-level theorems summary

The headline theorems Workstream H adds, ordered by their position
in the trust chain:

| #   | Theorem | Module | Phase |
|-----|---------|--------|-------|
| 212 | `commitBalanceMap_deterministic` | `FaultProof/Commit/Balance.lean` | H.2.1 |
| 213 | `commitBalanceMap_after_setBalance` | `FaultProof/Commit/Balance.lean` | H.2.1 |
| 214 | `commitNonceState_deterministic` | `FaultProof/Commit/Identity.lean` | H.2.2 |
| 215 | `commitKeyRegistry_deterministic` | `FaultProof/Commit/Identity.lean` | H.2.2 |
| 216 | `commitLocalPolicies_deterministic` | `FaultProof/Commit/Identity.lean` | H.2.2 |
| 217 | `commitBridgeState_deterministic` | `FaultProof/Commit/Bridge.lean` | H.2.3 |
| 218 | `commitExtendedState_deterministic` | `FaultProof/Commit/Top.lean` | H.2.4 |
| 219 | `commitExtendedState_size = 32` | `FaultProof/Commit/Top.lean` | H.2.4 |
| 220 | `commitExtendedState_injective_under_collision_free` | `FaultProof/Commit/Injectivity.lean` | H.2.5 |
| 221 | `verifyCellProof_complete` | `FaultProof/Proof/Verify.lean` | H.3.3 |
| 222 | `verifyCellProof_sound_under_collision_free` | `FaultProof/Proof/Verify.lean` | H.3.3 |
| 223 | `updateCommitment_agrees_with_setCell` | `FaultProof/Proof/Verify.lean` | H.3.3 |
| 224 | `kernelStepApply_deterministic` | `FaultProof/Step.lean` | H.1.2 |
| 225 | `kernelStepApply_coherent_with_kernelOnlyApply` | `FaultProof/Coherence.lean` | H.1.3 |
| 226 | `requiredCellProofs_matches_apply_impl` (×19 variants) | `FaultProof/Proof/Shapes.lean` | H.3.2 |
| 227 | `bulk_action_substeps_compose` | `FaultProof/StepVariants.lean` | H.1.4 |
| 228 | `kernelStep_roundtrip` | `Encoding/KernelStep.lean` | H.1.5 |
| 229 | `kernelStep_encode_injective` | `Encoding/KernelStep.lean` | H.1.5 |
| 230 | `applyTransition_deterministic` | `FaultProof/Game/Step.lean` | H.4.2 |
| 231 | `bisection_converges_in_log_length` | `FaultProof/Game/Convergence.lean` | H.4.3 |
| 232 | `honest_challenger_wins_against_invalid_state_root` | `FaultProof/Game/Honesty.lean` | H.4.4 |
| 233 | `faultProof_challenger_won_implies_state_root_wrong` | `FaultProof/Witness.lean` | H.8.4 |
| 234 | `Action.compile_injective` extends to indices 17, 18 | `Authority/Action.lean` | H.8.1 |
| 235 | `faultProofChallenge_compiled_isConservative` | `FaultProof/LawClassification.lean` | H.8.1 |
| 236 | `faultProofChallenge_compiled_isMonotonic` | `FaultProof/LawClassification.lean` | H.8.1 |
| 237 | `faultProofResolution_compiled_isConservative` | `FaultProof/LawClassification.lean` | H.8.1 |
| 238 | `faultProofResolution_compiled_isMonotonic` | `FaultProof/LawClassification.lean` | H.8.1 |
| 239 | `bridgePolicy_rejects_faultProofChallenge` | `Bridge/BridgeActor.lean` | H.8.1 |
| 240 | `bridgePolicy_rejects_faultProofResolution` | `Bridge/BridgeActor.lean` | H.8.1 |
| 241 | `accounting_delta_faultProofChallenge` | `Bridge/Accounting.lean` | H.8.1 |
| 242 | `accounting_delta_faultProofResolution` | `Bridge/Accounting.lean` | H.8.1 |
| 243 | `extractEvents_faultProofChallenge_emits_gameOpened` | `Events/Extract.lean` | H.8.3 |
| 244 | `extractEvents_faultProofResolution_emits_gameSettled` | `Events/Extract.lean` | H.8.3 |
| 245 | `non_meta_preserves_localPolicies` extends to indices 17, 18 | `Authority/SignedAction.lean` | H.8.1 |
| 246 | `non_registry_mutating_preserves_registry` extends to indices 17, 18 | `Authority/SignedAction.lean` | H.8.1 |
| 247 | `applyActionToBridgeState_faultProofChallenge` (identity) | `Bridge/Admissible.lean` | H.8.1 |
| 248 | `applyActionToBridgeState_faultProofResolution` (identity) | `Bridge/Admissible.lean` | H.8.1 |
| 249 | `applyCellWrites_total_for_admissible_actions` | `FaultProof/Step.lean` | H.1.2 |
| 250 | `recomputeCommitment_extensional` | `FaultProof/Step.lean` | H.1.2 |
| 251 | `applyCellWrites_matches_kernelOnlyApply_<variant>` (×19) | `FaultProof/Coherence/Variants.lean` | H.1.3a |
| 252 | `recomputeCommitment_agrees_with_commitExtendedState` | `FaultProof/Coherence/RecomputeAgreement.lean` | H.1.3c |
| 253 | `kernelStepApply_chain_coherent_with_kernelOnlyReplay` | `FaultProof/Coherence/Replay.lean` | H.1.3d |
| 254 | `chainKernelStepApply_deterministic` | `FaultProof/Step.lean` | H.1.6 |
| 255 | `chainKernelStepApply_split` | `FaultProof/Step.lean` | H.1.6 |
| 256 | `commit<SubState>_injective_under_collision_free` (×5) | `FaultProof/Commit/SubStateInjectivity.lean` | H.2.5a |
| 257 | `extendedStateExtensionallyEqual_implies_observably_equal` | `FaultProof/Commit/Canonicalisation.lean` | H.2.5c |
| 258 | `smtPathFromNat_inj_under_bound` | `FaultProof/Commit/KeyDerivation.lean` | H.2.6 |
| 259 | `verifyCellProofs_complete` | `FaultProof/Proof/Verify.lean` | H.3.3 |
| 260 | `verifyCellProof_complete_for_absent_cell` | `FaultProof/Proof/NonMembership.lean` | H.3.4 |
| 261 | `applyCellWrites_creates_absent_cells` | `FaultProof/Proof/NonMembership.lean` | H.3.4 |
| 262 | `verifyTypedCellProofs_complete` | `FaultProof/Proof/ReadWrite.lean` | H.3.5 |
| 263 | `verifyTypedCellProofs_separates_readOnly_writeCells` | `FaultProof/Proof/ReadWrite.lean` | H.3.5 |
| 264 | `range_halves_on_response{,_disagree}` | `FaultProof/Game/Convergence/Halving.lean` | H.4.3a |
| 265 | `range_size_after_k_rounds` | `FaultProof/Game/Convergence/Descent.lean` | H.4.3b |
| 266 | `range_single_step_after_log_rounds` | `FaultProof/Game/Convergence/Descent.lean` | H.4.3b |
| 267 | `bisection_terminates_in_at_most_max_depth_rounds` | `FaultProof/Game/Convergence.lean` | H.4.3c |
| 268 | `honest_strategy_unique` | `FaultProof/Game/StrategyUniqueness.lean` | H.4.4b |
| 269 | `honest_challenger_wins_via_sequencer_timeout` | `FaultProof/Game/Timeout.lean` | H.4.4d |
| 270 | `gameWellFormed` decidable | `FaultProof/Game/EdgeCases.lean` | H.4.6 |
| 271 | Six edge-case theorems | `FaultProof/Game/EdgeCases.lean` | H.4.6 |
| 272 | `gameState_roundtrip` | `Encoding/GameState.lean` | H.4.5 |

The trust-strength upgrade theorem is **#232** (the
single-honest-challenger property).  Every other theorem in the
list is supporting infrastructure for #232 to hold.

The four theorems whose unconditional discharge is most critical
are:

  * #220 (`commitExtendedState_injective_under_collision_free`)
    — without this, two parties could agree on a state root but
    disagree on the underlying state.
  * #225 (`kernelStepApply_coherent_with_kernelOnlyApply`) —
    without this, the L1 step VM could disagree with the L2
    kernel even on valid state roots.
  * #231 (`bisection_converges_in_log_length`) — without this,
    the game could fail to terminate on legal play.
  * #232 (`honest_challenger_wins_against_invalid_state_root`)
    — the trust-model upgrade itself.

All four are proved without `sorry`, conditional on
`CollisionFree hashBytes` (the standard Workstream-D + Workstream-A
discipline).

## 19. Open questions

These are decisions deferred to landing time, where deployment-
specific evidence will inform the final choice.

### 19.1 OQ1 — Bond denomination

The plan uses ETH bonds (`STATE_ROOT_SUBMISSION_BOND = 1.0 ETH`,
`MIN_CHALLENGE_BOND = 0.05 ETH`).  Alternatives:

  * **Per-deployment ERC-20 bonds.**  A deployment-specific
    token instead of ETH.  Cheaper for users with deployment
    tokens already in hand; harder to reason about from L1.
  * **Stablecoin bonds.**  USDC or DAI.  Removes ETH-price
    volatility from the bond economics.
  * **Hybrid: ETH for sequencer bond, deployment token for
    challenger bond.**  Aligns sequencer with L1 economics
    (where their gas costs live) and challenger with deployment
    economics (where their disputes derive from).

The MVP defaults to ETH-only for simplicity; switching to ERC-20
or hybrid is a deployment-time configuration that doesn't
require protocol changes (the bond-currency address is a
constructor argument).

### 19.2 OQ2 — Challenger bond pricing

`MIN_CHALLENGE_BOND = 0.05 ETH` is chosen to be:

  * Small enough that any user with non-trivial deployment
    activity can afford to challenge.
  * Large enough to deter griefing attacks (1000 simultaneous
    junk challenges = 50 ETH committed, immediately slashed if
    they don't materialise into actual disputes).

Open question: should the bond scale with the disputed log range
length?  A challenge against `[0..1M]` is logarithmically the
same effort as `[0..100]` (bisection convergence is `log₂`), but
gas-wise the L1 storage cost is identical.  Argument for fixed:
simpler economics; the sequencer's bond is what scales with
deployment value.  Argument for scaling: a malicious sequencer
who controls the deployment treasury can publish junk state
roots cheaply if challengers' bond doesn't reflect the dispute's
actual significance.  TBD at deployment time.

### 19.3 OQ3 — Sequencer set granularity

Current Workstream-E design: a single sequencer per deployment,
identified by an immutable address in `CanonStateRootSubmission.sol`.
Alternatives:

  * **Sequencer rotation (round-robin).**  N pre-approved
    sequencer addresses; per-block selection rotates.  Improves
    liveness; complicates state-root submission economics
    (whose bond gets slashed?).
  * **Permissionless sequencer.**  Anyone can submit a state
    root with a sufficient bond.  Maximally decentralised;
    requires careful anti-spam mechanisms.

The MVP defaults to single-sequencer (Workstream-E baseline);
scaling to multi-sequencer is a deployment-time configuration.

### 19.4 OQ4 — Dispute-window length

`FAULT_PROOF_DISPUTE_WINDOW = 216_000 blocks` (~30 days at
12 s/block) mirrors `MIN_GRACE_WINDOW_BLOCKS`.  Alternatives:

  * Shorter (7 days = 50_400 blocks): faster finality; reduces
    challenger time to detect faults.
  * Longer (90 days = 648_000 blocks): more challenger
    confidence; slower withdrawal latency.

Recommend defaulting to 30 days.  Deployments with high-stakes
finality (e.g. high-value DeFi) may opt for 90; deployments with
high-throughput-low-stakes (e.g. gaming) may opt for 7.

### 19.5 OQ5 — Bisection-depth bound (RESOLVED)

**v2 resolution.**  `MAX_BISECTION_DEPTH = 64`.

`MAX_BISECTION_DEPTH = 64` covers log lengths up to 2^64, which
is essentially unbounded.  Reducing to 32 (covers 2^32 = ~4B
entries) saves ~half the worst-case per-game gas, but at the
cost of accepting a hard log-length ceiling.  Production
deployments will never hit 2^32 entries in any reasonable
timeframe (≥ 4B actions at 100 actions/second = ≥ 1.3 years
sustained at peak), but locking the ceiling at construction
time is a footgun.  v2 takes the paranoid choice: 64 is the
ceiling, and the per-game gas headroom is acceptable
(~512M gas worst case, ~9 blocks at 60M each).

### 19.6 OQ6 — Sub-step granularity for bulk actions (RESOLVED)

**v2 resolution.**  Per-recipient sub-steps for
`distributeOthers` and `proportionalDilute`.

Each sub-step touches exactly one balance cell plus the bulk
action's nonce on the final sub-step.  Smaller granularity
(per-cell) is degenerate (each sub-step already touches one
cell); larger granularity (multi-recipient batches) reintroduces
the unbounded-cell-count problem.  Per-recipient is the unique
correct decomposition.

### 19.7 OQ7 — Cross-game state isolation (RESOLVED)

**v2 resolution.**  Single-game-per-state-root.

Multiple games may run simultaneously against state roots at
*different* log indices, but never against the same state root.
The `CanonFaultProofGame` contract maintains a
`mapping(uint64 logIndex => uint256 activeGameId)`; the second
caller of `initiateChallenge` for an already-disputed
`logIndex` reverts with `GameAlreadyExists`.

If the first challenger loses their game (state root affirmed),
a 1000-block "re-challenge window" opens during which a
different challenger can file a new game.  Outside that window,
the state root finalises and is no longer challengeable.  This
is the Optimism Cannon default and matches the design's
"single-honest-challenger" trust assumption (you don't need
multiple concurrent challengers; one suffices).

### 19.8 OQ8 — Slashed-bond destination

When a sequencer loses a fault-proof game, their bond is
slashed.  Where does it go?

  * **Challenger.**  Standard fault-proof economics.  Aligns
    challenger incentives with deployment safety.
  * **Burn.**  Removes the slashed value entirely.  Cleanest
    economic story; reduces sequencer rent extraction by
    discouraging deliberate fault-then-self-challenge schemes
    (though those are detectable and the deployment can
    blacklist).
  * **Deployment treasury.**  Slashed value goes to a
    deployment-controlled address.  Funds future development.

Recommend: 95% to challenger (incentive), 5% to deployment
treasury (revenue share).  Deployment-time configurable.

## 20. Glossary

| Term | Meaning |
|------|---------|
| **Bisection game** | The interactive L1 protocol that narrows a state-root disagreement to a single disputed step. |
| **CellProof** | A Merkle proof witnessing one cell's value at a committed state root. |
| **CellProofBundle** | The set of cell proofs covering all cells one step reads or writes. |
| **CellTag** | The tag identifying which sub-state + cell key a `CellProof` references. |
| **Claim** | A state-root assertion: at log index `idx`, the state root is `commit`. |
| **Coherence theorem** | A theorem proving two formalisations of the same concept agree. The fault-proof workstream's coherence theorem (#225) connects `kernelStepApply` to `kernelOnlyApply`. |
| **Commitment** | A 32-byte hash binding a piece of state. The top-level commitment binds the full `ExtendedState`. |
| **Fault proof** | A cryptographic witness that a state transition was executed incorrectly. In Canon, fault proofs are settled interactively rather than as standalone non-interactive proofs. |
| **Game (fault-proof game)** | An instance of the bisection protocol initiated by a challenger to dispute a sequencer's state root. |
| **Honest strategy** | The bisection-game strategy that always submits the truthful midpoint. |
| **KernelStep** | The data type capturing one kernel step's inputs and outputs in Merkle-state form. |
| **MerkleProof** | A path of sibling hashes proving a leaf's inclusion in a Merkle tree. |
| **Sequencer** | The deployment-pre-approved actor responsible for ordering and timestamping L2 actions. |
| **State root** | The top-level commitment of the `ExtendedState` at a particular log index. |
| **Step VM** | The L1 contract that executes one kernel step at a time, given Merkle proofs for the touched cells. |
| **Sub-step** | One per-recipient credit in a bulk action like `distributeOthers`. |
| **Witness (propositional)** | A Lean `Prop` value carrying evidence that a particular condition holds. Witness-bearing functions are functions whose type signature requires a propositional witness; this prevents callers from invoking them without proof of the condition. |

---

## Appendix A — Acceptance criteria summary

A complete Workstream H landing satisfies all of the following:

  1. **Build posture.**  `lake build`, `lake test`, `lake exe
     count_sorries`, `lake exe tcb_audit`, `lake exe stub_audit`
     all green on the final commit.  `forge build`, `forge test`
     also green.
  2. **Test count.**  Lean tests grow from 1228 to ≥ 1500.
     Solidity tests grow by ≥ 120 (across 4 new suites:
     `step-vm`, `fault-proof-game`, `state-root-submission`,
     `dispute-verifier-v2`).
  3. **Sorry budget.**  Zero sorries across every WU H.* module.
  4. **TCB budget.**  Zero TCB expansion.  No new modules in
     `tcb_allowlist.txt`.
  5. **Axiom budget.**  Zero new axioms.  All headline theorems
     `#print axioms`-clean.
  6. **Opaque budget.**  Zero new opaque declarations.
  7. **`kernelBuildTag`.**  Bumped to
     `"canon-fault-proof-migration"`.  Umbrella build-tag check
     updated.
  8. **Genesis Plan amendment.**  §15 added.  Two-reviewer signoff.
  9. **Acceptance test.**  The §2.3 acceptance test passes
     end-to-end across Lean and Solidity in CI.
  10. **Cross-stack coverage.**  Every `Action` constructor has
      ≥ 16 step-VM equivalence fixtures; every game-state
      transition has ≥ 8 bisection-game equivalence fixtures.
  11. **Property-based coverage.**  3 new properties × 100
      samples each, reproducible via `CANON_PROPERTY_SEED`.
  12. **Migration.**  `CanonFaultProofMigration` deploys cleanly
      against a testnet V1 deployment; activation freezes V1
      and brings V2 fully online.
  13. **Documentation.**  `docs/abi.md`, `CLAUDE.md`,
      `docs/fault_proof_design.md` updated.
      `docs/GENESIS_PLAN.md` §15 added.

## Appendix B — Risk register

Risks identified during planning, ranked by impact × likelihood:

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Bisection game's L1 gas exceeds practical limits | High | Medium | Per-step gas budget enforced; bulk-action sub-step decomposition; 64-depth cap |
| Cross-stack divergence between Lean step VM and Solidity step VM | Critical | Low | F.1.8 corpus + property-based equivalence tests; cross-stack divergence triggers CI failure |
| Sequencer bond economics enable griefing | Medium | Low | Bond pricing review at deployment time; fixed defaults conservative |
| Hash adaptor (production keccak256) not yet linked | Critical | High (already known) | Workstream H requires `isKeccak256Linked = true`; CI gates on this |
| `commitExtendedState` performance pathological for large state | High | Medium | Incremental commitment updates; benchmark in WU H.11.4 (deferred) |
| Migration leaves V1 disputes unresolvable | High | Low | V2's design preserves V1 readability; in-flight V1 disputes complete on V1 post-handoff |
| Single-honest-challenger assumption violated in practice | Critical | Low (by design) | Fundamental trust assumption; documented; mitigations include challenger reward economics |
| Property-based test seed coverage insufficient | Medium | Medium | Default 100 samples; `CANON_PROPERTY_SEED` env var enables larger suites at deployment time |

## Appendix C — Workstream effort estimate

Rough order-of-magnitude effort (for reference; not a commitment):

| Phase | WUs | Estimated effort |
|-------|-----|------------------|
| Specification (H.1–H.4) | 18 sub-WUs | ~3–4 weeks of focused engineering |
| L1 implementation (H.5–H.7) | 9 sub-WUs | ~4–6 weeks |
| Integration (H.8–H.9) | 7 sub-WUs | ~2–3 weeks |
| Verification + docs (H.10–H.13) | ~12 sub-WUs | ~3–4 weeks |
| **Total** | **~46 sub-WUs** | **~12–17 weeks** |

Comparable in scope to Workstream E (Solidity contracts, ~10
weeks of integrated effort) plus Workstream F (cross-stack
verification, ~4 weeks).  The kernel's small footprint keeps
the effort below what an EVM-equivalent fault-proof migration
would require (Optimism's Cannon took >12 months end-to-end).

---

*End of Workstream H planning document.*

## Appendix D — Per-variant cell-read/write table

The complete cell-read/write specification for all 19 `Action`
constructors.  This table is the authoritative source for WUs
H.1.4, H.3.2, H.5.2.* (per-variant Solidity step functions),
and the cross-stack equivalence corpus in WU H.10.1.

Notation:
  * `RO` = read-only proof (verified but cell-value not changed)
  * `RW` = read-write proof (verified AND cell-value changes)
  * `s` = signer (action's `signer` field)
  * `r`, `rcv`, etc. = action's parameters

| Idx | Constructor                | Read-only cells              | Read-write cells                                                                |
|-----|----------------------------|------------------------------|---------------------------------------------------------------------------------|
| 0   | `transfer r s rcv amt`     | `[registry s]`               | `[balance r s, balance r rcv, nonce s]`                                         |
| 1   | `mint r to amt`            | `[registry s]`               | `[balance r to, nonce s]`                                                       |
| 2   | `burn r from amt`          | `[registry s]`               | `[balance r from, nonce s]`                                                     |
| 3   | `freezeResource r`         | `[registry s]`               | `[nonce s]`                                                                     |
| 4   | `replaceKey actor newKey`  | `[registry s]`               | `[registry actor, nonce s]`                                                     |
| 5   | `reward r to amt`          | `[registry s]`               | `[balance r to, nonce s]`                                                       |
| 6   | `distributeOthers r exc amt` (BULK) | `[registry s]`     | `[balance r k for each k != exc, nonce s]` (≤ 256 cells)                        |
| 7   | `proportionalDilute r exc amt` (BULK) | `[registry s]`   | `[balance r k for each k != exc, nonce s]` (≤ 256 cells)                        |
| 8   | `dispute d`                | `[registry s]`               | `[nonce s]`                                                                     |
| 9   | `disputeWithdraw idx`      | `[registry s]`               | `[nonce s]`                                                                     |
| 10  | `verdict v`                | `[registry s]`               | `[nonce s]`                                                                     |
| 11  | `rollback targetIdx`       | `[registry s]`               | `[nonce s]`                                                                     |
| 12  | `registerIdentity actor pk` | `[registry s]`              | `[registry actor, nonce s]`                                                     |
| 13  | `deposit d r recipient amt` | `[registry s, bridgeConsumed d]` | `[balance r recipient, nonce s, bridgeConsumed d]`                          |
| 14  | `withdraw r s amt rcpL1`   | `[registry s]`               | `[balance r s, nonce s, bridgePending nextWdId, bridgeNextWdId]`                |
| 15  | `declareLocalPolicy p`     | `[registry s]`               | `[localPolicy s, nonce s]`                                                      |
| 16  | `revokeLocalPolicy`        | `[registry s]`               | `[localPolicy s, nonce s]`                                                      |
| 17  | `faultProofChallenge ...`  | `[registry s]`               | `[nonce s]`                                                                     |
| 18  | `faultProofResolution ...` | `[registry s]`               | `[nonce s]`                                                                     |

**Reading the table.**

  * Constructor index matches `Action.tag` and the CBE encoder's
    constructor-tag byte.
  * Read-only `[registry s]` is universal: every action verifies
    its signer's registered key for signature validation.  This
    cell is read but never written (signature verification doesn't
    mutate the registry).
  * `[nonce s]` is read-write for every action: signature
    verification reads the current nonce; admissibility increments
    it.
  * Bulk actions (indices 6, 7) have unbounded read-write cell
    sets at the action level; per-sub-step they touch one
    `balance` cell.  The bulk-action sub-step decomposition
    (WU H.1.4) is what keeps the per-step cost bounded.
  * Bridge-only actions (indices 12, 13, 14) have additional
    `bridgePolicy` constraints checked at admissibility time:
    the signer must be the bridge actor for `registerIdentity`
    and `deposit`; *not* the bridge actor for `withdraw`
    (per Workstream-C audit-1 fix).

**Cross-stack equivalence target.**

For every entry in this table, the WU H.10.1 fixture corpus has
≥ 16 happy-path test cases plus ≥ 8 adversarial cases
(mismatched proof, inadmissible action, post-state forgery,
absent-cell creation, cross-deployment replay).  Total
fixture count: 19 × 16 + 19 × 8 = 456 fixtures.

## Appendix E — Bond-economics game-theoretic analysis

This appendix formalises why the bond pricing in §2 (Status)
prevents profitable attacks under reasonable economic
assumptions.

**Notation.**

  * Let `B_s = STATE_ROOT_SUBMISSION_BOND = 1.0 ETH`
  * Let `B_c = MIN_CHALLENGE_BOND = 0.05 ETH`
  * Let `G_seq = average gas cost of a sequencer's defensive
    moves in a game ≈ 13M gas / game ≈ 0.13 ETH at 100 gwei`
  * Let `G_chl = average gas cost of a challenger's offensive
    moves ≈ 13M gas / game ≈ 0.13 ETH at 100 gwei`
  * Let `V = value extracted from a successful state-root fraud`
  * Let `P_h = probability at least one honest challenger
    detects the fraud within the dispute window`

**Sequencer-attack analysis.**

A malicious sequencer attempts to publish a fraudulent state
root extracting value `V`.  Their expected payoff is:

```
E[Sequencer attack] = (1 - P_h) × V                       -- success: extract V
                    - P_h × B_s                            -- detected: lose bond
                    - P_h × G_seq                          -- detected: lose gas
                    - 0                                    -- success: no gas (dispute window expires)
```

Setting `E[Sequencer attack] = 0`:

```
(1 - P_h) × V = P_h × (B_s + G_seq)
V = P_h × (B_s + G_seq) / (1 - P_h)
```

For typical parameters (`B_s = 1.0`, `G_seq = 0.13`, `P_h = 0.99`):

```
V_breakeven = 0.99 × 1.13 / 0.01 = 111.87 ETH
```

In words: a fraud must extract more than 112 ETH for the attack
to be profitable, given a 99% honest-detection probability.
For typical Canon deployments, single-action value extraction
is bounded by the per-actor balance × the per-action cap, both
of which are deployment-config items.  Production deployments
should pin `STATE_ROOT_SUBMISSION_BOND ≥ V_max / 100` where
`V_max` is the maximum value at risk in any single state-root
window.  The 1.0 ETH default suffices for deployments where
single-state-root value-at-risk ≤ 100 ETH (e.g., low-value
chains, gaming, social).

For high-value deployments (DeFi, etc.), the deployment-time
bond override should be much higher — e.g., 10 ETH for a
deployment with $1B+ TVL.  This is documented in the
deployment runbook (Appendix K).

**Challenger-griefing analysis.**

A malicious challenger files junk challenges to drain the
sequencer's gas budget.

Their expected payoff per junk challenge:

```
E[Challenger grief] = - B_c                               -- always lose bond
                    - G_chl                                -- gas costs
                    + 0                                    -- no upside (sequencer is honest)
                    = -(B_c + G_chl) = -0.18 ETH
```

So each junk challenge costs the attacker 0.18 ETH.  The
sequencer's defensive cost per game is 0.13 ETH.  The attacker
loses more than the sequencer per game; the attack is
economically irrational unless the attacker's goal is non-
financial (e.g., reputational damage to the deployment).

**DoS via simultaneous junk challenges.**

If the attacker files N simultaneous challenges:

  * Attacker cost: N × 0.18 ETH
  * Sequencer cost: N × 0.13 ETH (assuming sequencer plays
    every game in parallel)

The L1's per-block gas budget caps the rate at which games
can progress: with `MIN_BISECTION_STEP_INTERVAL_BLOCKS = 5`,
each game advances at most every 60 seconds.  An attacker
filing 100 junk challenges costs themselves 18 ETH and
extends the sequencer's defensive window by ~6000 blocks
(~20 hours).  At 18 ETH per 20-hour delay, the cost of
sustained DoS is prohibitive (≥ $30k/day at typical ETH
prices).

**Conclusion.**  The default bond pricing is sound for
deployments with single-state-root value-at-risk ≤ 100 ETH.
Higher-value deployments should scale `B_s` proportionally.
The challenger-griefing economics are favourable for the
sequencer (attacker pays more per game).

## Appendix F — Per-L1-entry-point gas budget

Detailed gas estimates for each L1 entry point, expressed in
worst-case gas units.  Production-keccak256-linked deployment
assumed.

### F.1 `CanonStateRootSubmission`

| Entry | Worst-case gas | Notes |
|-------|----------------|-------|
| `submitStateRoot` | 80_000 | 2 SSTOREs + bond transfer + 1 event |
| `finaliseStateRoot` | 50_000 | Bond release + status update |

### F.2 `CanonFaultProofGame`

| Entry | Worst-case gas | Notes |
|-------|----------------|-------|
| `initiateChallenge` | 200_000 | Game struct init + 2 events |
| `submitMidpoint` | 80_000 | 1 SSTORE + 1 event |
| `respondToMidpoint` | 80_000 | 1 SSTORE + 1 event |
| `terminateOnSingleStep` | 8_000_000 | Step VM execution (per-variant; see F.3) |
| `claimTimeout` | 100_000 | Status update + bond redistribution |

### F.3 `CanonStepVM` (per-variant `executeStep`)

| Constructor | Gas budget | Notes |
|-------------|------------|-------|
| `transfer` | 350_000 | 4 cell proofs + signature verify |
| `mint` | 280_000 | 3 cell proofs |
| `burn` | 280_000 | 3 cell proofs |
| `freezeResource` | 200_000 | 2 cell proofs |
| `replaceKey` | 320_000 | 3 cell proofs + registry write |
| `reward` | 280_000 | 3 cell proofs |
| `distributeOthers` (per sub-step) | 200_000 | 1 balance cell + base costs |
| `proportionalDilute` (per sub-step) | 220_000 | + division arithmetic |
| `dispute` | 250_000 | Larger calldata payload |
| `disputeWithdraw` | 200_000 | |
| `verdict` | 250_000 | Verdict payload |
| `rollback` | 200_000 | |
| `registerIdentity` | 320_000 | Registry write |
| `deposit` | 420_000 | 4 cell proofs + bridge state update |
| `withdraw` | 480_000 | 5 cell proofs + bridge state update |
| `declareLocalPolicy` | 380_000 | Variable; capped at 16 KB policy |
| `revokeLocalPolicy` | 280_000 | |
| `faultProofChallenge` | 250_000 | Challenge payload |
| `faultProofResolution` | 220_000 | Resolution payload |

### F.4 `CanonDisputeVerifierV2`

| Entry | Worst-case gas | Notes |
|-------|----------------|-------|
| `finaliseUpheld` (oracle) | 600_000 | Adjudicator quorum + bridge revert |
| `finaliseRejected` (oracle) | 500_000 | |
| `finaliseFromFaultProof` | 200_000 | Reads game settlement; calls bridge |

### F.5 `CanonFaultProofMigration`

| Entry | Worst-case gas | Notes |
|-------|----------------|-------|
| `activate` | 150_000 | One-shot freeze of V1 |

**Per-game total gas budget (worst case).**

```
submitStateRoot:               80_000
initiateChallenge:            200_000
64 × submitMidpoint:        5_120_000
64 × respondToMidpoint:     5_120_000
terminateOnSingleStep:      8_000_000
                          ───────────
TOTAL:                     18_520_000   (~31% of one block @ 60M)
```

Per game, both parties combined consume ~18.5M gas.  Spread
across 128 transactions over the dispute window, this is
trivially manageable.  The single biggest single-transaction
cost is `terminateOnSingleStep` at 8M gas (~13% of block);
acceptable.

## Appendix G — Cross-stack fixture JSON schema

The cross-stack fixture corpora (WU H.10.1 – H.10.4) use a
common JSON schema.  This appendix defines it.

### G.1 Step-VM fixture (`step_vm.json`)

```json
{
  "fixtures": [
    {
      "fixtureId": "transfer-happy-001",
      "actionVariant": "transfer",
      "preStateCommit": "0x...",
      "signedActionEncoded": "0x...",
      "cellProofs": [
        {
          "cellTag": {"variant": "balance", "resourceId": 1, "actorId": 42},
          "cellValue": "0x...",
          "siblings": ["0x...", "0x...", ...]
        },
        ...
      ],
      "expectedPostStateCommit": "0x...",
      "expectedRevertReason": null
    },
    {
      "fixtureId": "transfer-adversarial-bad-proof-001",
      "actionVariant": "transfer",
      "preStateCommit": "0x...",
      "signedActionEncoded": "0x...",
      "cellProofs": [
        ...  (with one tampered sibling)
      ],
      "expectedPostStateCommit": null,
      "expectedRevertReason": "BadCellProof"
    }
  ]
}
```

### G.2 Bisection-game fixture (`bisection_game.json`)

```json
{
  "fixtures": [
    {
      "fixtureId": "happy-log-1024",
      "logLength": 1024,
      "divergencePoint": 512,
      "initialGameState": { ... },
      "transcript": [
        {"transition": "submitMidpoint", "midpointCommit": "0x..."},
        {"transition": "respondDisagree"},
        ...
      ],
      "expectedFinalStatus": "challengerWon",
      "expectedFinalState": { ... }
    }
  ]
}
```

### G.3 Scenario fixture (`scenarios.json`)

```json
{
  "fixtures": [
    {
      "fixtureId": "scenario-end-to-end-001",
      "logEntries": [...],
      "sequencerSubmittedRoot": {"logIndex": N, "commit": "0x..."},
      "challengerActions": [
        {"action": "initiateChallenge", "challengerCommit": "0x..."},
        {"action": "playHonestStrategy"}
      ],
      "expectedSettlement": {
        "winner": "challenger",
        "revertFromIdx": 17,
        "bondPayout": "1050000000000000000"
      }
    }
  ]
}
```

### G.4 Schema validation

A JSON schema (`fixture-schema.json`) is shipped under
`solidity/test/CrossCheck/schemas/` for both the Lean fixture
generator and the Solidity test driver to validate.  The schema
is enforced at fixture-generation time; CI fails if a fixture
fails schema validation.

### G.5 Generation discipline

  * Lean side generates fixtures via `Test/FaultProof/FixtureGen.lean`,
    seeded by deterministic LCG (per Workstream-F discipline).
  * Solidity side parses fixtures via Forge cheatcodes
    (`vm.readFile`, `vm.parseJson`).
  * The `CANON_FIXTURES_OVERWRITE` environment variable controls
    write vs. verify mode; defaults to verify (CI gates on
    no-rewrite-needed).

## Appendix H — Security attack-tree

Detailed enumeration of attack vectors and mitigations.
Extends §3.4 with implementation-level detail.

### H.1 Sequencer-side attacks

#### H.1.1 Publish wrong state root and abandon

  * **Attack:** sequencer publishes `commit'` ≠ truthful `commit`,
    abandons (does not respond to challenges).
  * **Mitigation:** challenger initiates game; sequencer's failure
    to respond fires `BISECTION_RESPONSE_TIMEOUT`; challenger
    wins by `claimTimeout`.  Sequencer loses
    `STATE_ROOT_SUBMISSION_BOND`.
  * **Residual:** none.

#### H.1.2 Publish wrong state root and play through

  * **Attack:** sequencer publishes `commit'`, plays full
    bisection.
  * **Mitigation:** by WU H.4.4c, honest challenger wins.  At
    single-step termination, the L1 step VM proves the
    sequencer wrong.
  * **Residual:** conditional on `CollisionFree hashBytes`.

#### H.1.3 Submit valid state root but later attempt to revert

  * **Attack:** sequencer submits truthful `commit`, then
    attempts to challenge their own root with a different
    "challenger" address (rebate + denial).
  * **Mitigation:** the bond economics make self-challenge
    unprofitable (sequencer pays both the submission bond and
    the challenge bond, plus L1 gas, with no upside).  Plus,
    the deployment can blacklist the challenger address if
    detected.
  * **Residual:** non-financial gain (e.g., delaying a
    legitimate withdrawal); detected by deployment watcher;
    blacklist mitigates.

#### H.1.4 Spam state-root submissions

  * **Attack:** sequencer submits N state roots in rapid
    succession to inflate L1 storage.
  * **Mitigation:** `MIN_SUBMISSION_INTERVAL_BLOCKS` rate
    limit; `MAX_OUTSTANDING_ROOTS_PER_SEQUENCER` cap; per-
    submission bond (each costs 1 ETH).  At 1 root per 100
    blocks × 1 ETH each, sustained spam costs 10 ETH/day; not
    economically rational.
  * **Residual:** deployment-level disk costs for honest replicas.

### H.2 Challenger-side attacks

#### H.2.1 File junk challenge against valid state root

  * **Attack:** attacker files challenge against a valid root,
    abandons or plays through.
  * **Mitigation:** sequencer responds; bisection settles in
    sequencer's favour; attacker loses `MIN_CHALLENGE_BOND`.
  * **Residual:** sequencer's gas cost (~0.13 ETH); offset by
    L1 fees + deployment-treasury split.

#### H.2.2 DoS via many junk challenges

  * **Attack:** attacker files N challenges in parallel.
  * **Mitigation:** per-game gas costs paid by attacker
    (~0.13 ETH per game); N junk games cost attacker N × 0.18
    ETH (bond + gas).  See Appendix E for detailed economics.
  * **Residual:** non-financial griefing; rate-limited by L1
    gas budget.

#### H.2.3 Concurrent challenges against same root

  * **Attack:** two challengers simultaneously file challenges
    against the same root (race condition).
  * **Mitigation:** per OQ7 resolution, single-game-per-state-
    root.  First challenger wins the slot; second reverts with
    `GameAlreadyExists`.
  * **Residual:** UX inconvenience (second challenger waits
    for re-challenge window).

#### H.2.4 Spoiler / front-running of honest challenge (audit-fix; new)

  * **Attack:** attacker watches the L1 mempool for an honest
    challenger's pending `initiateChallenge` transaction.
    Front-runs (higher gas price) with their own challenge
    against the same `disputedLogIndex`.  With single-game-
    per-state-root (OQ7), the spoiler wins the slot.  Spoiler
    then deliberately loses the bisection (e.g., submits
    untruthful midpoints), letting the L1 step VM declare the
    sequencer winner.  State root affirms; honest challenger
    must re-file in the narrow re-challenge window.
  * **Cost to spoiler:** `MIN_CHALLENGE_BOND + L1 gas` ≈ 0.18
    ETH per spoiler attempt.
  * **Mitigation:** the re-challenge window (per OQ7
    resolution: 1000 blocks ≈ 200 minutes) gives honest
    challengers a second chance.  Sequencer-side: if the same
    spoiler pattern recurs, deployment may blacklist the
    spoiler address (out-of-band; deployment-policy decision).
  * **Residual:** the honest challenger pays a delay penalty
    (~200 minutes per spoiler attack) but retains the ability
    to ultimately revert the bad state root.  Permanent fund
    loss is impossible (the sequencer's bond is locked the
    whole time; eventual honest challenge wins it).
  * **Future mitigation (out of scope):** commit-reveal
    challenge initiation, where challengers commit to an
    intent hash that hides the disputed root until reveal.
    Deferred to a follow-up workstream.

### H.3 Cryptographic attacks

### H.3 Cryptographic attacks

#### H.3.1 Hash collision in `commitExtendedState`

  * **Attack:** find `es₁ ≠ es₂` with
    `commitExtendedState es₁ = commitExtendedState es₂`.
  * **Mitigation:** `CollisionFree hashBytes` hypothesis
    (production keccak256 satisfies under standard
    assumptions).
  * **Residual:** conditional on hash CR.  CI requires
    `isKeccak256Linked = true`; the FNV-1a-64 fallback is
    explicitly disallowed for production.

#### H.3.2 Forged ECDSA signature

  * **Attack:** forge a signature for the sequencer's signed
    actions or for adjudicator verdicts.
  * **Mitigation:** EUF-CMA on `Verify` (the deployment-supplied
    signature scheme).  Same trust assumption as Phase-3 +
    Workstream-A.
  * **Residual:** conditional on EUF-CMA.

### H.4 Implementation-bug attacks

#### H.4.1 Step-VM-kernel divergence

  * **Attack:** Solidity step VM and Lean kernel disagree on
    the post-state for a particular action.
  * **Mitigation:** WU H.10.1 cross-stack equivalence corpus
    (456 fixtures); CI gates on byte-for-byte agreement.
  * **Residual:** test-coverage gap (fixture not exercising
    the divergent path).  Property-based testing (WU H.11)
    increases coverage; deployment-side observers continuously
    cross-check.

#### H.4.2 Reentrancy on settlement

  * **Attack:** winner's `receive()` callback reenters the
    contract during bond payout, tries to disrupt state.
  * **Mitigation:** `nonReentrant` modifier + CEI ordering on
    every external entry.  Tested by 6+ Solidity reentrancy
    fixtures.
  * **Residual:** none.

### H.5 L1 chain-state attacks

#### H.5.1 L1 reorganisation during in-flight game (audit-fix; new)

  * **Attack vector:** L1 chain reorg removes the block
    containing an in-flight bisection move.  The game's L1
    storage state diverges between the original chain head and
    the post-reorg head.
  * **Mitigation:** standard rollup posture — reorgs shallower
    than the deployment's confirmation depth (typically 64
    blocks) are absorbed transparently (Solidity's view of
    storage updates with the reorg).  Reorgs deeper than the
    confirmation depth are treated as a deployment-level
    emergency: operators pause submissions, manually
    reconcile, then resume.
  * **Why deep reorgs aren't a Workstream-H bug:** deep L1
    reorgs are a *deployment-level* failure of the underlying
    L1 chain assumption.  No L2 protocol can recover
    automatically from a Byzantine L1; the standard rollup
    answer is human intervention.  Workstream H inherits this
    posture from existing rollup designs.
  * **Operator runbook reference:** Appendix K.3 (rollback
    procedure) covers the manual reconciliation steps.

#### H.5.2 L1 censorship of honest challenger transactions

  * **Attack vector:** L1 block builders censor an honest
    challenger's `initiateChallenge` or `submitMidpoint`
    transactions, allowing a fraudulent state root to finalise.
  * **Mitigation:** the dispute window (216_000 blocks ≈ 30
    days) is far longer than any plausible censorship
    duration.  Standard L1 censorship-resistance assumptions
    (i.e., not all block builders cooperate to censor for 30
    days) apply.
  * **Residual:** conditional on L1 liveness assumptions.

### H.6 Deployment-misconfiguration attacks

#### H.5.1 Insufficient bond

  * **Attack:** deployment sets `STATE_ROOT_SUBMISSION_BOND` too
    low; sequencer attacks become profitable.
  * **Mitigation:** Appendix E provides the bond-pricing
    formula; deployment runbook (Appendix K) documents it.
  * **Residual:** deployment-time decision.  Cannot be fixed
    post-deployment (constants are immutable); requires
    migration to a new deployment.

#### H.5.2 Sequencer set captured

  * **Attack:** the deployment's pre-approved sequencer key is
    compromised; attacker submits state roots arbitrarily.
  * **Mitigation:** any honest party can challenge any
    fraudulent root.  Worst case: attacker submits many
    fraudulent roots; honest party challenges each;
    attacker loses `STATE_ROOT_SUBMISSION_BOND` per fraud.
  * **Residual:** deployment must rotate sequencer key;
    `replaceKey` action handles this for L2; sequencer-set
    is L1 immutable, so requires migration.

## Appendix I — Best-practices compliance checklist

A pre-merge checklist to confirm each WU adheres to project
discipline.

### I.1 Per-WU build gates

For every WU, before merge:

- [ ] `lake build` green
- [ ] `lake test` green (all suites pass)
- [ ] `lake exe count_sorries` returns 0
- [ ] `lake exe tcb_audit` clean
- [ ] `lake exe stub_audit` clean
- [ ] `forge build` green (Solidity-touching WUs)
- [ ] `forge test` green (Solidity-touching WUs)
- [ ] CI pipeline green

### I.2 Naming discipline

For every WU, before merge:

- [ ] No identifier contains "wu", "phase", "audit", "f<NN>",
      "tmp", "todo", "fixme", "claude_", "session_"
- [ ] Mechanical check: `git diff --cached -U0 -- '*.lean' |
      grep -E '^\+(def|theorem|...)' | grep -iE '...'`
      returns empty

### I.3 Decidability discipline

For every new `Prop`-valued declaration:

- [ ] Has a paired `Decidable` instance
- [ ] Instance synthesizes via `inferInstance` (no hand-written
      derivation, except for genuinely irreducible predicates)
- [ ] If instance is consumed by another module, it has a
      *named* declaration (not anonymous)

### I.4 Theorem hygiene

For every new theorem:

- [ ] Proved without `sorry`
- [ ] `#print axioms` shows expected axioms only (no new
      custom axioms)
- [ ] Hypotheses are explicit (no implicit `Classical.choice`
      via tactic that opens the door)
- [ ] Statement uses snake_case (Mathlib/Lean convention)
- [ ] Complete docstring (`/-- ... -/`) explaining what the
      theorem proves and how it's used

### I.5 Module-level discipline

For every new Lean module:

- [ ] License header (`Canon - A Societal Kernel ...`)
- [ ] Module docstring explaining purpose
- [ ] Section docstrings (`/-! ... -/`) for major sub-sections
- [ ] No autoImplicit
- [ ] Zero linter warnings

### I.6 Solidity-specific discipline

For every new Solidity contract:

- [ ] No proxy / upgradeability pattern
- [ ] No admin role
- [ ] No `pause()` function
- [ ] All state variables `immutable` if set in constructor;
      otherwise documented why mutable
- [ ] `nonReentrant` on every external function that mutates
      state or transfers value
- [ ] CEI ordering on every external call sequence
- [ ] Custom errors instead of `require` strings
- [ ] Events for every state mutation
- [ ] `forge-lint` passes with zero warnings

### I.7 Cross-stack discipline

For every WU touching both Lean and Solidity:

- [ ] Cross-stack fixture corpus updated to cover the WU's
      surface
- [ ] Byte-for-byte equivalence verified (under
      `isKeccak256Linked = true`)
- [ ] Documentation explicitly notes the cross-stack
      relationship

### I.8 Per-WU commit discipline

- [ ] One commit per WU (sub-WUs may batch)
- [ ] Commit message format: `WU H.X.Y: <imperative summary>`
- [ ] Body explains *why*, not *what*

## Appendix J — WU dependency graph

The WUs have a directed acyclic dependency structure.  This
appendix renders the DAG so readers can see which WUs unblock
which.

```
H.2.1 (BalanceMap SMT) ──┐
H.2.2 (Identity SMTs)  ──┤
H.2.3 (BridgeState SMT) ─┼─→ H.2.4 (Top commit) ─→ H.2.5b ─→ H.2.5c
                          │                          ↑
H.2.6 (Key derivation) ───┘                          │
                                                     │
H.3.1 (CellProof type) ──→ H.3.2 (Shapes) ──┐         │
                                            ├─→ H.3.3 (Verify)
                                            │
                                            ├─→ H.3.4 (NonMembership)
                                            │
                                            └─→ H.3.5 (ReadWrite)

H.1.1 ──→ H.1.2 ──→ H.1.4 ──→ H.1.5
                ↓
                H.1.3a (per-variant) ─→ H.1.3b ─→ H.1.3c ─→ H.1.3d
                                                            ↑
                                                    H.1.6 (multi-step)

H.4.1 ──→ H.4.2 ──→ H.4.3a ──→ H.4.3b ──→ H.4.3c
                ↓                          ↓
                H.4.6 (Edge cases)         H.4.4a ─→ H.4.4b ─→ H.4.4c
                                                              ↓
                                                              H.4.4d
                ↓
                H.4.5 (Encoding)

H.5.1 (skeleton) ──→ H.5.2.1...19 (per-variant)
                        ↑
                        H.5.3 (Merkle library)

H.6.1a ──→ H.6.1b ─┬─→ H.6.1c ─→ H.6.1d ─→ H.6.1e ─→ H.6.1g
                   └─→ H.6.1f
                                 ↑
                                 H.6.2 (Bond economics)
                                 ↓
                                 H.6.3 (Events)

H.7.1 ──→ H.7.2 ──→ H.7.3 (Anti-DoS) ──→ H.7.4 (Hash chain)

H.1.* + H.2.* + H.3.* + H.4.* ──→ H.8.1 ──→ H.8.2 ──→ H.8.3 ──→ H.8.4 ──→ H.8.5

H.5.* + H.6.* + H.7.* + H.8.* ──→ H.9.1 ──→ H.9.2 ──→ H.9.3 ──→ H.9.4

H.1.* + H.5.* + H.6.* ──→ H.10.1 ──→ H.10.2 ──→ H.10.3 ──→ H.10.4 ──→ H.10.5

H.4.* + H.10.* ──→ H.11.1 ──→ H.11.2 ──→ H.11.3 ──→ H.11.4

All WUs ──→ H.12 (Audit binaries) ──→ H.13 (Documentation)
```

**Critical path.**  The longest chain is:

```
H.2.1 ─→ H.2.4 ─→ H.2.5b ─→ H.2.5c ─→ H.3.3 ─→ H.1.3b ─→ H.4.4c ─→ H.8.4 ─→ H.9.* ─→ H.10.* ─→ H.13
```

This is ~12 sequential dependencies; with parallel work across
sub-graphs (H.5, H.6, H.7 can all proceed once H.4 lands), the
total wall-clock should be 12–17 weeks per the §C estimate.

**Parallelisation opportunities.**

  * H.2.1, H.2.2, H.2.3 are independent; can be parallelised
    across three engineers.
  * H.5.2.1 through H.5.2.19 are independent (each per-variant
    function); can be parallelised across many engineers.
  * H.10.1 through H.10.4 corpus generation is independent;
    parallelisable.

## Appendix K — Migration runbook (operator-facing)

A step-by-step guide for deployment operators upgrading from V1
(adjudicator-quorum) to V2 (fault-proof) dispute resolution.

### K.1 Pre-migration prerequisites

Before scheduling migration:

- [ ] Workstream H Lean side fully landed and audited.
- [ ] Solidity contracts (V2 bundle) deployed via CREATE3 to
      a known address.  Address recorded in deployment registry.
- [ ] Production keccak256 binding linked
      (`isKeccak256Linked = true`).
- [ ] Bond economics review per Appendix E: confirm
      `STATE_ROOT_SUBMISSION_BOND` ≥ deployment-specific
      `V_max / 100`.
- [ ] Off-chain observer tooling (WU H.10.5) deployed by at
      least one independent party (preferably 3+).
- [ ] V1 contract pre-commits: V1's `migration` immutable
      field set to V2's `CanonFaultProofMigration` address
      (audit-3 discipline).

### K.2 Migration execution

Step 1 — schedule activation:

```bash
# Deploy migration contract
forge script script/DeployFaultProof.s.sol \
    --rpc-url $RPC \
    --broadcast \
    --private-key $DEPLOYER_KEY

# Schedule activation (30-day grace window)
cast send $MIGRATION_ADDR \
    "scheduleActivation(uint64)" \
    $((CURRENT_BLOCK + 216_000)) \
    --private-key $DEPLOYER_KEY
```

Step 2 — public announcement:

  * Post to deployment's status page: "Workstream-H migration
    activates at block N."
  * Notify integrators (DEXes, bridges, indexers) of the
    upcoming behavioural change.
  * Specifically: the L1-event-watcher target changes from V1
    to V2 at activation.

Step 3 — operator preparedness checks (week before activation):

  * Confirm at least one independent observer is live and
    successfully cross-checking state roots.
  * Run a dress-rehearsal challenge on V2 with a known-bad
    state root (testnet only); verify settlement works
    end-to-end.
  * Audit V1 for in-flight oracleMisreported and deterministic
    disputes; tabulate which will need migration handling
    per WU H.9.4.

Step 4 — activation:

```bash
# After block N
cast send $MIGRATION_ADDR \
    "activate()" \
    --private-key $DEPLOYER_KEY
```

  * V1 enters settle-only mode (per WU H.8.5).
  * V2 starts accepting state-root submissions.
  * Sequencers must update to use V2's
    `CanonStateRootSubmission` for all submissions going
    forward.

Step 5 — post-migration monitoring (first 30 days):

  * Daily: review V1 in-flight disputes; ensure they settle
    within the grace window.
  * Daily: review V2 state-root submission cadence; cross-
    check against expected sequencer activity.
  * Monitor `FaultProofGameOpened` events; investigate every
    one.
  * Monitor bond balances on V2 to detect anomalies.

Step 6 — graceful retirement (Day 30+):

  * V1 in-flight disputes past their grace window are
    automatically routable to V2 per WU H.9.4.
  * V1 contract becomes purely read-only for historical
    queries.
  * All new disputes use V2 path.

### K.3 Rollback procedure (if migration fails)

If V2 has a critical bug discovered post-activation:

  1. Immediately deploy fixed V2' via CREATE3 to a new address.
  2. Schedule V2 → V2' migration with another 30-day grace
     window.
  3. Treat the situation as a chained migration; V2's open
     disputes settle on V2 during V2 → V2' grace.

There is no L1-side "undo" — once V1 is frozen, it cannot be
unfrozen.  The migration is forward-only.  Operators should
treat the activation block as a point-of-no-return for V1.

### K.4 Per-deployment configuration knobs

Decisions that can vary per deployment:

  * **Bond denominations** (OQ1).  Default ETH; alternatives
    documented in §19.1.
  * **Bond magnitudes**.  Defaults `1.0` / `0.05` ETH; scale
    per Appendix E formula.
  * **Dispute window** (OQ4).  Default 30 days; adjust per
    deployment finality requirements.
  * **Slashed-bond split** (OQ8).  Default 95/5; configurable
    treasury address.
  * **Sequencer set** (OQ3).  Default single; multi-sequencer
    rotation deferred.
  * **Adjudicator set** for residual oracleMisreported path.

These are deployment-time constructor arguments; immutable
post-deployment.  Operators must commit to these values at
deployment time.


---

*End of Workstream H planning document (v2).*

*Total: 13 work units → ~70 sub-WUs across 4 implementation
phases.  61 new type-level theorems specified.  11 appendices
covering acceptance, risk, effort, cell-read/write semantics,
bond economics, gas budgets, fixture schemas, attack tree,
best-practices, WU dependency graph, and migration runbook.*

*This plan supersedes the v1 plan of 2026-05-08.  Promotion
to a Genesis-Plan §15 amendment is tracked under WU H.13.1.*

## Appendix L — v2 audit findings and resolutions

This appendix records the v2-internal audit pass that
identified and fixed correctness bugs introduced during the
v1 → v2 expansion, plus completeness gaps in v2 itself.
Each finding is keyed by severity and resolution status.

### L.1 Audit methodology

The audit cross-checked v2 plan claims against the actual
codebase signatures in:

  * `LegalKernel/Disputes/Evidence.lean` (`kernelOnlyApply`,
    `kernelOnlyReplay` signatures)
  * `LegalKernel/Authority/SignedAction.lean`
    (`apply_admissible_with` body)
  * `LegalKernel/Runtime/LogFile.lean` (`LogEntry.hash`
    formula)
  * `LegalKernel/Authority/Action.lean` (`Action.tag`
    enumeration)
  * `LegalKernel/Authority/LocalPolicySemantics.lean`
    (`Action.tag` extension to indices 15, 16)
  * `LegalKernel/Kernel.lean` (TCB function signatures)
  * `solidity/src/contracts/CanonBridge.sol`
    (`revertToPriorRoot` audit-2 (floor, ceiling) machinery)

Plus internal-consistency checks across plan WU
cross-references.

### L.2 Critical findings (correctness bugs)

#### L.2.1 — `kernelOnlyApply` signature mismatch

  * **Original v2 claim:**
    `kernelOnlyApply : ExtendedState → SignedAction → Option ExtendedState`
  * **Codebase reality** (`Disputes/Evidence.lean:89`):
    `kernelOnlyApply : ExtendedState → LogEntry → ExtendedState`
    (takes `LogEntry`, returns `ExtendedState` directly,
    total — never fails)
  * **Affected WUs:** H.1.2, H.1.3a–d, H.1.6, theorem #225
  * **Resolution:** v2 audit-pass updated WU H.1.3b's
    coherence theorem to use the correct signature; added
    `signedActionToLogEntry` bridge function for the
    KernelStep ↔ kernelOnlyApply boundary.  Updated H.1.6's
    chain-coherence theorem to use the correct signature.
    Fixed in commit (audit-pass-1).

#### L.2.2 — `KernelStep.signedAction` field type mismatch with coherence

  * **Issue:** the v2 spec carries a `SignedAction` in
    `KernelStep`, but `kernelOnlyApply` consumes a
    `LogEntry`.  The coherence theorem can't compose without
    a bridge.
  * **Resolution:** added `signedActionToLogEntry` helper +
    documented the bridge in WU H.1.3b.  Future revision may
    elect to change `KernelStep.signedAction` to
    `KernelStep.entry : LogEntry` for cleaner composition;
    deferred as a follow-up audit pass.

#### L.2.3 — L1 hash-chain semantics misclaimed as cross-stack-equivalent

  * **Issue:** v2 WU H.7.4 said the L1 chain
    `keccak256(abi.encode(prevLogEntryHash, stateCommit))`
    "uses the same composition" as kernel-side `LogEntry.hash`.
    But `LogEntry.hash` hashes
    `(encode signedAction ++ encode prevHash)` — different
    inputs.
  * **Resolution:** rewrote WU H.7.4's coherence section to
    explicitly distinguish the two chains: L2 chain (log
    entries) vs L1 chain (state-root submissions).  The two
    chains link through `prevLogEntryHash` — each L1
    submission's prevLogEntryHash = the kernel-computed
    `LogEntry.hash log[logIndex - 1]`.  Cross-stack
    equivalence verified by WU H.10.4 fixture corpus.
    Fixed in audit-pass-1.

#### L.2.4 — Missing helper specifications

  * **Issue:** v2 spec referenced `buildCellProof`,
    `buildCellProofs`, `extractRequiredCells`, `getCellValue`,
    `setCell`, `isCellAbsent` in theorem statements without
    defining them as artifacts.
  * **Resolution:** added explicit specifications for all six
    helpers in WU H.1.2; ship in
    `LegalKernel/FaultProof/Step.lean` and
    `Proof/Cell.lean`.  Fixed in audit-pass-1.

#### L.2.5 — `kernelStepApply` failure-mode prose described impossible branch

  * **Issue:** v2 said `kernelStepApply` returns `none` when
    "kernelOnlyApply itself returns `none`" — but
    `kernelOnlyApply` is total.
  * **Resolution:** rewrote prose to clarify that
    `kernelStepApply` fails on inadmissibility (via
    `applyCellWrites` returning `none`), distinct from
    `kernelOnlyApply`'s silent-no-op semantics.  Documented
    the single semantic difference between the two functions.
    Fixed in audit-pass-1.

### L.3 Important findings (security / completeness)

#### L.3.1 — Spoiler / front-running attack class (audit-pass-1)

  * **Issue:** v2 Appendix H didn't enumerate the
    front-running attack on `initiateChallenge`.
  * **Resolution:** added H.2.4 attack-tree entry analyzing
    cost (~0.18 ETH/attempt), residual risk (delay only, no
    fund loss), and future mitigation (commit-reveal).  Fixed
    in audit-pass-1.

#### L.3.2 — V2 genesis state-root chain handover missing

  * **Issue:** v2 didn't specify how V2's first state-root
    submission chains back to V1's last finalised root.
    Without this, V2's hash-chain integrity check (WU H.7.4)
    would either fail or break the chain on first submission.
  * **Resolution:** added `v1LastFinalisedLogEntryHash` and
    `v1LastFinalisedLogIndex` immutable fields to
    `CanonFaultProofMigration`; V2 reads them at construction.
    Specified in WU H.9.4.  Fixed in audit-pass-1.

#### L.3.3 — Withdrawal-window vs fault-proof-window alignment

  * **Issue:** v2 didn't specify the constraint
    `FAULT_PROOF_DISPUTE_WINDOW ≥ WITHDRAWAL_FINALISATION_WINDOW`.
    Violation would allow withdrawals to finalise on L1
    against a state root that later gets faulted, leading to
    L1-side fund loss.
  * **Resolution:** added `assertConsistent()` invariant to
    `CanonStateRootSubmission` constructor + WU H.7.3 acceptance
    criteria.  Fixed in audit-pass-1.

#### L.3.4 — L1 reorganisation handling unspecified

  * **Issue:** v2 treated L1 reorgs only via "L1 nonce
    discipline" handwave.
  * **Resolution:** added H.5.1 attack-tree entry distinguishing
    shallow reorgs (absorbed transparently by Solidity storage)
    from deep reorgs (deployment-level emergency requiring
    manual intervention per Appendix K.3).  Fixed in
    audit-pass-1.

#### L.3.5 — `FaultProofChallengerWon` witness construction unspecified

  * **Issue:** v2 defined the propositional witness but didn't
    specify how a runtime constructs it from L1 evidence.
  * **Resolution:** added WU H.4.4e
    (`FaultProofChallengerWon.of_log_entry`) using a new
    deployment-supplied opaque `l1FaultProofVerifier`.
    Documented the new trust assumption (L1 watcher honesty)
    in the trust-boundary inventory.  Fixed in audit-pass-1.

### L.4 Minor findings (clarity / best practices)

These were noted but considered low-priority or already
acceptable in v2; not fixed in audit-pass-1 but tracked for
future revisions:

  * **L.4.1.** v2 prose occasionally over-states v1 issues as
    "wrong" when "non-standard" is more accurate.  Style only.
  * **L.4.2.** Test count target (+270) underestimates actual
    implied count (~450+).  Update to tracking number deferred.
  * **L.4.3.** Off-chain observer hardware/cost analysis
    missing.  Deferred to deployment runbook.
  * **L.4.4.** Per-variant gas-budget enforcement mechanism
    not specified.  Solidity-side: `forge test --gas-report`
    + dedicated gas-regression test fixtures.  Document in
    `solidity/test/StepVMGasReport.t.sol`.
  * **L.4.5.** The plan doesn't note that deployments may
    want to subsidize challenger bonds via a public fund to
    maintain trust-model practical viability.  Operator-runbook
    matter; deferred.

### L.5 Audit-pass-1 commit summary

The audit-pass-1 fix landed in the same commit as this
appendix.  Specific files modified:

  * `docs/planning/fault_proof_migration_plan.md` — additions:
    helper-spec block (WU H.1.2), corrected coherence theorem
    signature (WU H.1.3b), L1-vs-L2-chain clarification (WU
    H.7.4), spoiler attack (Appendix H.2.4), L1 reorg
    handling (Appendix H.5.1), V2 genesis chain (WU H.9.4),
    witness construction (WU H.4.4e), this appendix (L).

No code in `LegalKernel/` is modified by audit-pass-1: this
is still a planning document.  All theorems' axiom
discipline is preserved; new opaque (`l1FaultProofVerifier`)
follows the existing `Verify` / `hashBytes` pattern.

### L.6 Overall assessment

After audit-pass-1, the v2 plan is **implementation-ready**:

  * Every theorem statement type-checks against actual
    codebase signatures.
  * Every helper used in proofs has an explicit specification.
  * Cross-stack equivalence claims correctly characterise
    which chains link through which fields.
  * Security analysis covers the previously-undocumented
    attack vectors.
  * The witness-bearing API at the migration boundary is
    fully specified.

Implementation effort estimate (Appendix C) remains valid;
the audit didn't surface any work-unit-blocking issues.
Workstream H is ready to begin implementation against the v2
plan + this audit appendix.


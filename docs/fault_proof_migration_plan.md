<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Fault-Proof Migration — Workstream Plan (Workstream H)

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
  5. Workstream H.1 — Step semantics extraction
  6. Workstream H.2 — State commitment scheme
  7. Workstream H.3 — Per-step proofs
  8. Workstream H.4 — Bisection game (Lean specification)
  9. Workstream H.5 — Solidity step VM
  10. Workstream H.6 — Solidity bisection contract
  11. Workstream H.7 — Sequencer state-root submission
  12. Workstream H.8 — Dispute pipeline integration
  13. Workstream H.9 — Migration
  14. Workstream H.10 — Cross-stack verification
  15. Workstream H.11 — Property-based tests
  16. Workstream H.12 — Audit binaries / TCB / sorry budget
  17. Workstream H.13 — Documentation + Genesis Plan amendment
  18. Type-level theorems summary
  19. Open questions
  20. Glossary

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

### 3.2 Trust-boundary inventory

The trust boundaries that Workstream H modifies, in addition to
those documented in the Ethereum-integration plan §3.3:

| Boundary | Pre-H assumption | Post-H assumption |
|----------|------------------|-------------------|
| State-root validity | M-of-N adjudicators honest | 1 honest challenger globally |
| Adjudicator availability | M-of-N adjudicators live within window | Any party with bond available |
| `checkEvidence` re-evaluation | Performed M times by adjudicators | Performed once on L1 by step VM |
| Verdict signature aggregation | Off-chain coordinator | None (no signatures needed) |
| Bond economics | None at protocol layer | L1-native bonds; slashed by step VM |

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

**Specification.**

```lean
/-- The Merkle-state-aware step function.  Given the pre-state
    commitment, the action, and the Merkle proofs for the touched
    cells, compute the claimed post-state commitment.

    Returns `none` if any of the per-cell Merkle proofs fail to
    verify against `preStateCommit`, if the action is not
    admissible at the pre-state, or if `kernelOnlyApply` itself
    returns `none`. -/
def kernelStepApply (step : KernelStep) : Option StateCommit
```

**Acceptance criteria.**

  * Total function (`Option`-returning).
  * Decidable: `inferInstance` resolves
    `Decidable (kernelStepApply step = some commit)`.
  * Three `Decidable` checks compose:
    1. `verifyCellProofs step.preStateCommit step.cellProofs`
       (Merkle proof verification — see WU H.3.3).
    2. `Action.compile step.signedAction.action` produces a
       `Transition` with decidable precondition (which holds for
       every existing law via the `decPre := fun _ => inferInstance`
       discipline).
    3. The post-state commitment match
       `kernelStepApplyToCells step.cellProofs step.signedAction
        = step.postStateCommit`.

**Proof obligations.**

  * `kernelStepApply_deterministic`: equal inputs produce equal
    outputs (mechanical via `rfl`).

### 5.3 WU H.1.3 — Coherence with `kernelOnlyApply`

**Module:** `LegalKernel/FaultProof/Coherence.lean`

**Specification.**

The headline coherence theorem:

```lean
theorem kernelStepApply_coherent_with_kernelOnlyApply
    (es : ExtendedState) (st : SignedAction)
    (h_admissible : ∃ verify P d, AdmissibleWith verify P d es st) :
    let step : KernelStep := {
      preStateCommit  := commitExtendedState es,
      signedAction    := st,
      postStateCommit := commitExtendedState (kernelOnlyApply es st),
      cellProofs      := buildCellProofs es st
    }
    kernelStepApply step = some step.postStateCommit
```

**Acceptance criteria.**

  * Theorem proved without `sorry` and without `Classical.choice`
    (uses only `propext` and `Quot.sound` plus the existing
    `Verify` opaque-but-erased status).
  * The proof composes:
    1. `commitExtendedState`'s injectivity in cell content
       (from WU H.2.6).
    2. `verifyCellProofs`'s soundness (from WU H.3.3,
       conditional on hash collision-resistance).
    3. The kernel's existing `apply_admissible` definition.

**Why this matters.**  This is the load-bearing theorem of the
entire workstream: it certifies that the L1 step VM's behaviour
matches the L2 kernel's behaviour exactly.  Without it, the L1
fault-proof game might disagree with the L2 runtime even on
valid state roots, breaking sequencer liveness.

**Proof strategy.**  Structural induction on the `Action` variant.
Each case unfolds `kernelOnlyApply` and `kernelStepApply`, applies
the corresponding cell-update lemma from WU H.3.3, and closes by
`rfl` or `congrArg`.

### 5.4 WU H.1.4 — Per-action-variant step definitions

**Module:** `LegalKernel/FaultProof/StepVariants.lean`

**Specification.**

For each of the 19 `Action` constructors (transfer / mint / burn /
freezeResource / replaceKey / reward / distributeOthers /
proportionalDilute / dispute / disputeWithdraw / verdict /
rollback / registerIdentity / deposit / withdraw /
declareLocalPolicy / revokeLocalPolicy / faultProofChallenge /
faultProofResolution), define the per-cell read/write set:

```lean
def Action.cellReadWriteSet : Action → CellSet
```

For example:
  * `transfer r s rcv amt` reads `(balances r s, balances r rcv,
    nonces s, registry s)` and writes `(balances r s, balances r
    rcv, nonces s)`.
  * `distributeOthers r exclude amt` reads / writes O(N) balance
    cells where N is the number of actors at resource r — this is
    the **bulk action** case, handled via sub-step decomposition.

**Bulk-action handling.**  Two new types:

```lean
/-- A single sub-step within a bulk action.  For
    `distributeOthers`, one sub-step is one per-recipient credit. -/
structure SubStep where
  parentActionIdx : LogIndex
  subStepIdx      : Nat
  affectedActor   : ActorId
  preCellValue    : Amount
  postCellValue   : Amount
  cellProof       : MerkleProof

/-- A bulk action decomposed into a sequence of sub-steps. -/
def Action.subSteps : Action → List SubStep
```

The `MAX_RECIPIENTS_PER_BULK_ACTION = 256` cap (from §2 status)
is enforced at the action-construction layer (a new
`Action.fieldsBounded` clause); attempts to construct a bulk action
exceeding the cap are rejected at decode time as
`DecodeError.invalidLength`.

**Acceptance criteria.**

  * Each variant has an explicit cell-read/write specification.
  * The bulk-action sub-step decomposition is total.
  * The sub-step sequence's reduction equals the bulk action's
    `apply_impl` (theorem `bulk_action_substeps_compose`).

### 5.5 WU H.1.5 — `KernelStep` codec

**Module:** `LegalKernel/Encoding/KernelStep.lean`

**Specification.**  CBE codec for `KernelStep`:

```lean
def KernelStep.encode : KernelStep → Stream
def KernelStep.decode : Stream → Except DecodeError (KernelStep × Stream)
def KernelStep.fieldsBounded : KernelStep → Prop
```

**Acceptance criteria.**

  * `kernelStep_roundtrip`: bounded round-trip identity.
  * `kernelStep_encode_injective`: bounded injectivity.
  * `kernelStep_encode_deterministic`: structural rfl-class.
  * `KernelStep.fieldsBounded` is decidable via `inferInstance`.
  * The encoder's output for each variant fits within the
    deployment's per-action wire-size budget (typically 4 KB).

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

### 6.5 WU H.2.5 — `commitExtendedState` injectivity

**Module:** `LegalKernel/FaultProof/Commit/Injectivity.lean`

**Specification.**

```lean
theorem commitExtendedState_injective_under_collision_free
    (es₁ es₂ : ExtendedState)
    (h_cf : CollisionFree hashBytes)
    (h_eq : commitExtendedState es₁ = commitExtendedState es₂) :
    extendedStateExtensionallyEqual es₁ es₂
```

**Acceptance criteria.**

  * Theorem proved without `sorry`, conditional on
    `CollisionFree hashBytes`.
  * The proof reuses the Workstream-D `verifyProof_sound`
    discipline (per-level `hashUp_inj_of_collisionFree` plus
    `byteArray_append_inj`).

**Why this matters.**  This is the proof that "if the L1 contract
sees the same state root from two parties, the parties must
actually agree on the state."  Without this, the bisection game
could converge to a single step where both parties claim the same
state-root commitment but actually disagree on the underlying
state.

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

**Specification.**

```lean
/-- Verify a single cell proof against the committed state root. -/
def verifyCellProof
    (commit : StateCommit) (proof : CellProof) : Bool

/-- Verify every cell proof in a bundle. -/
def verifyCellProofs
    (commit : StateCommit) (bundle : CellProofBundle) : Bool

/-- Compute the new commitment after updating one cell. -/
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
```

**Acceptance criteria.**

  * Both theorems proved without `sorry`.
  * `updateCommitment` agrees with `commitExtendedState` after
    the corresponding cell update (theorem
    `updateCommitment_agrees_with_setCell`).
  * The completeness theorem requires no hash hypothesis (it's
    structural recursion through the Merkle tree, mirroring
    Workstream D's `verifyProof_complete`).
  * The soundness theorem requires `CollisionFree hashBytes`,
    matching Workstream D's discipline.

## 8. Workstream H.4 — Bisection game (Lean specification)

This WU formalises the bisection game as a state machine with
explicit transitions.  The Lean side is the *reference
implementation*; the Solidity side (WU H.6) ports it line-for-line
under cross-stack equivalence testing.

### 8.1 WU H.4.1 — `Claim` and `Bisection` types

**Module:** `LegalKernel/FaultProof/Game/Types.lean`

**Specification.**

```lean
/-- A single state-root assertion: at log index `idx`, the state
    root is `commit`. -/
structure Claim where
  idx    : LogIndex
  commit : StateCommit
  deriving Repr, DecidableEq

/-- A bisection round.  `claimant` and `challenger` each assert
    a distinct state root for the `(start, end)` range; the
    round narrows the disagreement to half the range. -/
structure BisectionRound where
  start            : Claim
  ending           : Claim
  claimantMidpoint    : Claim
  challengerMidpoint  : Claim
  deriving Repr, DecidableEq

/-- The game state: a list of bisection rounds plus the
    submitter and challenger identities. -/
structure GameState where
  submitter   : ActorId
  challenger  : ActorId
  rounds      : List BisectionRound
  bondClaimant   : Amount
  bondChallenger : Amount
  status         : GameStatus
  deriving Repr, DecidableEq

/-- Game terminates in one of three states. -/
inductive GameStatus
  | inProgress
  | claimantWon
  | challengerWon
  | timedOut (loser : ActorId)
  deriving Repr, DecidableEq
```

**Acceptance criteria.**

  * All types have `Repr` + `DecidableEq`.
  * CBE codecs for `Claim`, `BisectionRound`, and `GameState`
    with round-trip + injectivity proofs.

### 8.2 WU H.4.2 — Game state transitions

**Module:** `LegalKernel/FaultProof/Game/Step.lean`

**Specification.**

```lean
/-- The set of legal transitions from one game state to the next.
    `submitMidpoint` occurs when the current round is
    incomplete; `terminateOnSingleStep` occurs when the bisection
    has narrowed to a single step that L1 can execute directly. -/
inductive GameTransition
  | submitMidpoint (party : ActorId) (mp : Claim)
  | terminateOnSingleStep
      (disputedStep : KernelStep)
      (submitterPostCommit : StateCommit)
      (challengerPostCommit : StateCommit)
  | timeout (party : ActorId)

def applyTransition
    (gs : GameState) (t : GameTransition) : Option GameState
```

**Acceptance criteria.**

  * `applyTransition` is total and decidable.
  * Transitions that violate the game's well-formedness (e.g. a
    party submitting a midpoint outside the agreed range) are
    rejected with `none`.

### 8.3 WU H.4.3 — Bisection convergence

**Module:** `LegalKernel/FaultProof/Game/Convergence.lean`

**Specification.**  The headline theorem of the game design:

```lean
theorem bisection_converges_in_log_length
    (gs₀ : GameState)
    (h_distinct : gs₀.rounds.head?.map (fun r => r.start.commit ≠ r.ending.commit) = some true)
    (h_log_len : LogIndex)
    (transitions : List GameTransition)
    (h_legal : isLegalTranscript gs₀ transitions) :
    let final := transitions.foldl (fun gs t => applyTransition gs t |>.getD gs) gs₀
    final.status ≠ .inProgress ∨ transitions.length ≥ Nat.log2 h_log_len + 1
```

In words: any legal game transcript either terminates in at most
`log₂(log_length) + 1` rounds, or it stays in progress (for
liveness reasons covered by the L1 timeout mechanism).

**Acceptance criteria.**

  * Theorem proved by induction on `transitions.length`.  Each
    legal `submitMidpoint` halves the range; after `log₂` rounds
    the range is a single step, triggering
    `terminateOnSingleStep`.
  * The bisection-depth bound `MAX_BISECTION_DEPTH = 64` is
    sufficient for log lengths up to `2^64` (i.e. always; the
    runtime's `LogIndex = Nat` is unbounded but
    `2^64` log entries at production throughput is millennia of
    operation).

### 8.4 WU H.4.4 — Single-honest-challenger property

**Module:** `LegalKernel/FaultProof/Game/Honesty.lean`

**Specification.**  The trust-model theorem:

```lean
/-- An honest party plays the legal transition that minimises
    the dispute range and never asserts a false midpoint.  -/
def isHonestStrategy
    (party : ActorId) (truthfulCommits : LogIndex → StateCommit)
    (gs : GameState) : Option GameTransition

theorem honest_challenger_wins_against_invalid_state_root
    (gs₀ : GameState)
    (truth : LogIndex → StateCommit)
    (h_invalid : gs₀.rounds.head?.map (fun r => r.ending.commit ≠ truth r.ending.idx) = some true)
    (h_challenger_honest :
        ∀ gs, gs.challenger plays isHonestStrategy gs.challenger truth gs)
    (transcript : LegalTranscript gs₀) :
    transcript.final.status = .challengerWon
```

In words: if the submitter's claimed state root differs from the
truth, and the challenger plays the honest strategy, then the
challenger wins regardless of the submitter's strategy.

**Acceptance criteria.**

  * Theorem proved without `sorry`.
  * Proof composes: bisection convergence (WU H.4.3) +
    `kernelStepApply_coherent_with_kernelOnlyApply` (WU H.1.3) +
    `commitExtendedState_injective_under_collision_free` (WU H.2.5).
  * The proof critically depends on `CollisionFree hashBytes`;
    the theorem's hypothesis carries this as an explicit `Prop`
    parameter.

**Why this is the load-bearing theorem.**  This single theorem
*replaces* the entire trust assumption that the Phase-6 quorum
mechanism rests on.  Anyone reading the kernel and finding this
theorem can verify mechanically that the fault-proof game is
correct without trusting any adjudicator set.

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

### 9.2 WU H.5.2 — Per-action-variant step functions

**Module:** `solidity/src/contracts/CanonStepVM.sol` (continuation)

**Specification.**  For each of the 19 `Action` constructors,
implement a private function `_step<Variant>` that:

  1. Decodes the action's CBE bytes via `CBEDecode` library
     (Workstream E).
  2. Verifies the per-cell Merkle proofs against `preStateCommit`.
  3. Computes the new cell values using the action's semantic
     rule.
  4. Re-aggregates the sub-state SMT roots and the top-level
     state commitment.
  5. Returns the new commitment.

For example, `_stepTransfer`:

```solidity
function _stepTransfer(
    bytes32 preStateCommit,
    uint256 resourceId,
    uint256 sender,
    uint256 receiver,
    uint256 amount,
    CellProof memory senderBalance,
    CellProof memory receiverBalance,
    CellProof memory senderNonce,
    CellProof memory senderRegistry,
    bytes memory signature
) private view returns (bytes32 postStateCommit);
```

**Bulk-action handling.**  `_stepDistributeOthers` and
`_stepProportionalDilute` execute one sub-step per call (per
recipient).  The bisection contract drills into bulk actions
during the bisection phase, identifying the specific sub-step in
dispute.

**Acceptance criteria.**

  * One function per `Action` constructor.  Coverage table in
    contract docstring.
  * Per-variant gas budgets documented and tested.
  * Cross-stack equivalence: each function's output matches the
    Lean-side `kernelStepApply` for every fixture in WU H.10's
    corpus.

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

### 10.1 WU H.6.1 — `CanonFaultProofGame.sol`

**Module:** `solidity/src/contracts/CanonFaultProofGame.sol`

**Specification.**  The L1 game contract.  External entry points:

```solidity
function initiateChallenge(
    bytes32 disputedStateRoot,
    bytes32 challengerStateRoot,
    Claim memory startClaim,
    Claim memory endClaim
) external payable returns (uint64 gameId);

function submitMidpoint(
    uint64 gameId,
    Claim memory midpoint
) external;

function terminateOnSingleStep(
    uint64 gameId,
    bytes calldata signedActionEncoded,
    CellProof[] calldata cellProofs
) external;

function claimTimeout(uint64 gameId) external;
```

**Internal state per game:**

```solidity
struct Game {
    address sequencer;
    address challenger;
    uint64  startIdx;
    uint64  endIdx;
    bytes32 startCommit;
    bytes32 endCommit;
    bytes32 sequencerEndCommit;
    bytes32 challengerEndCommit;
    uint64  bisectionDepth;
    address whoseTurn;        // sequencer or challenger
    uint64  turnDeadline;     // block number after which timeout fires
    GameStatus status;
    uint128 sequencerBond;
    uint128 challengerBond;
}
mapping(uint64 => Game) public games;
uint64 public nextGameId;
```

**Acceptance criteria.**

  * `MAX_BISECTION_DEPTH = 64` cap enforced.
  * `BISECTION_RESPONSE_TIMEOUT = 21_600 blocks` per round.
  * Reentrancy-safe (`nonReentrant` modifier on every external
    function that touches game state or transfers value).
  * Cross-stack equivalent to the Lean-side `applyTransition`
    (WU H.4.2) for every fixture in WU H.10.2.

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

### 11.3 WU H.7.3 — Anti-DoS protections

**Specification.**

  * Per-block submission rate limit (configurable; default 1
    state root per 100 blocks per sequencer).
  * Per-sequencer total-locked-bond cap (default 100 outstanding
    state roots).
  * Per-game bisection-step rate limit (one step per 5 blocks
    per game per party).

**Acceptance criteria.**

  * Rate limits are deployment-time constants (immutable).
  * Tested by adversarial scenarios in the cross-stack corpus.

## 12. Workstream H.8 — Dispute pipeline integration

### 12.1 WU H.8.1 — New `Action` constructors

**Module extensions:** `LegalKernel/Authority/Action.lean`,
`LegalKernel/Encoding/Action.lean`,
`LegalKernel/Authority/SignedAction.lean`,
`LegalKernel/Bridge/BridgeActor.lean`,
`LegalKernel/Disputes/Evidence.lean`,
`LegalKernel/LocalPolicy/LawClassification.lean`.

**New constructors at frozen indices 17, 18:**

```lean
/-- A user submits a fault-proof challenge against a sequencer's
    state-root submission.  The actual game runs on L1; this
    action is the L2-side notification + bond commitment. -/
| faultProofChallenge (gameId : Nat) (disputedStartIdx : LogIndex)
                       (disputedEndIdx : LogIndex)
                       (challengerCommit : StateCommit)

/-- A fault-proof game's L1 settlement is mirrored on L2 via this
    action.  Triggers the same `revertToPriorRoot` logic that
    Phase-6 `applyVerdict (.upheld)` triggers, but sourced from
    the fault-proof game rather than from an adjudicator
    quorum. -/
| faultProofResolution (gameId : Nat) (winner : ActorId)
                        (revertFromIdx : LogIndex)
```

Both compile to `Laws.freezeResource 0` at the kernel level
(no balance / nonce changes; the dispute-pipeline-mirroring side
effects are in the runtime layer).

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
  * Settlement payouts always equal the loser's bond exactly.

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

### 19.5 OQ5 — Bisection-depth bound

`MAX_BISECTION_DEPTH = 64` covers log lengths up to 2^64, which
is essentially unbounded.  Could be reduced to 32 (covers 2^32 =
~4B entries) for ~half the per-game gas.  Realistically, no
deployment will hit 2^32 entries in any reasonable timeframe;
defaulting to 64 is paranoid but cheap.

### 19.6 OQ6 — Sub-step granularity for bulk actions

Current plan: `distributeOthers` and `proportionalDilute`
decompose into per-recipient sub-steps.  Alternative: decompose
into smaller sub-units (per-recipient × per-cell) — but each
sub-step already touches exactly one cell, so this is degenerate.

Confirmed: per-recipient is the right granularity.

### 19.7 OQ7 — Cross-game state isolation

Multiple games may run simultaneously against state roots at
different log indices.  Current plan: each game is independent
(separate `gameId`), and the `CanonFaultProofGame` contract
maintains them as a `mapping`.  Open question: can two games
about *the same state root* coexist?  Argument for yes: multiple
challengers may identify different faults in the same state
root, and concurrent disputes converge faster.  Argument for no:
duplication of work; complicates settlement (whose claim wins
if two challengers both win their respective games?).

Recommend: single-game-per-state-root.  First challenger to
file gets the slot.  Subsequent challengers wait for that game
to settle; if it's lost (state root affirmed), they have a
narrow re-challenge window.  This is the Optimism Cannon
default.

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

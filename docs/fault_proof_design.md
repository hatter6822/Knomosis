<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon Fault-Proof Design Rationale

This document is the standalone design-rationale companion to
`docs/fault_proof_migration_plan.md`.  It explains the *why*
behind the major design decisions of Workstream H, in plain
language, for deployment operators who don't read Lean.

For the *what* (engineering plan + per-WU specs), see
`fault_proof_migration_plan.md`.

For the *formal content* (Lean theorems + proofs), see
`LegalKernel/FaultProof/`.

---

## 1. Why interactive fault proofs over validity proofs (ZK)?

Canon's roadmap envisions three phases of dispute resolution:

| Phase | Mechanism | Trust assumption | Cost profile |
|-------|-----------|------------------|--------------|
| 1 | Bot-quorum (Phase 6) | M-of-N adjudicators | Cheap on L1; trust-heavy |
| **2** | **Interactive fault proofs (Workstream H)** | **1-of-anyone** | **Moderate L1 gas; honest-challenger trust** |
| 3 | Validity proofs (ZK) | SNARK soundness | Expensive prover; low trust |

Workstream H is Phase 2.  It strikes the best practical
balance between trust strength and L1 cost for Canon's current
production volumes.

**Why not ZK?**  Validity proofs (SNARKs / STARKs) are
unconditionally trust-minimal but require expensive prover
infrastructure ($1k+/proof on production circuits).  Canon's
small kernel footprint (~hundreds of lines in two TCB files)
makes a fault-proof game tractable; the same footprint *also*
makes the kernel a uniquely tractable target for ZK in a
future Phase 3.  Workstream H neither precludes nor requires
Phase 3.

**Why not stay on bot-quorums?**  The M-of-N trust assumption
is pragmatic but brittle: if all N bots are compromised, wrong
state roots slip through.  Workstream H's "1-of-anyone honest"
assumption is structurally stronger.

---

## 2. Why a macro-step VM (per-Action) over a micro-step VM
(per-EVM-instruction)?

Optimism's Cannon and Arbitrum's BoLD use micro-step VMs:
they run a MIPS or RISC-V interpreter on L1 to execute the L2
program one instruction at a time.  This is necessary because
EVM instructions don't decompose cleanly.

Canon's kernel is *much smaller* — a `transfer` action is
already a single semantic step.  We can afford a macro-step
VM that executes one entire Action at a time.

**Tradeoffs.**

  * **+ Simpler L1 contracts.**  No emulator needed; just per-
    variant Solidity step functions.
  * **+ Faster bisection.**  Steps are coarse, so bisection
    converges in fewer rounds.
  * **+ Smaller bundle for cross-stack equivalence.**  ~344
    fixtures (per WU H.10.1) vs ~10k+ for a micro-step VM.
  * **− Bulk actions need sub-step decomposition.**
    `distributeOthers` and `proportionalDilute` write to many
    cells; we decompose them into per-recipient sub-steps
    (per WU H.1.4).
  * **− New laws require new step VM code.**  Each new Action
    constructor needs a per-variant `_step<Variant>` Solidity
    function.

The kernel-size advantage is what makes macro-step viable.

---

## 3. Bond economics rationale

The two bond constants:

  * `STATE_ROOT_SUBMISSION_BOND = 1.0 ETH`
  * `MIN_CHALLENGE_BOND = 0.05 ETH`

**Game-theoretic analysis** (Appendix E of the workstream plan):

A malicious sequencer attempting fraud:
  * Expected payoff: `(1 - P_h) * V - P_h * (1.0 + 0.13)`
  * Where `P_h` is the probability of honest detection,
    `V` is the value extracted, `0.13` is L1 gas.
  * Setting expected payoff = 0: `V_breakeven = P_h * 1.13 / (1 - P_h)`
  * For `P_h = 0.99`: `V_breakeven = 111.87 ETH`

So a sequencer must extract more than 112 ETH per fraud for
the attack to be profitable, given a 99% honest-detection
probability.  Lower-value attacks are economically irrational.

Production deployments with single-state-root value-at-risk
above 100 ETH should scale `STATE_ROOT_SUBMISSION_BOND`
proportionally (e.g., 10 ETH for $1B+ TVL).

**Challenger griefing analysis:**

Each junk challenge costs the attacker
`MIN_CHALLENGE_BOND + L1 gas ≈ 0.18 ETH`.  The sequencer's
defensive cost per game is ≈ 0.13 ETH.  The attacker loses
more per game than the sequencer; griefing is economically
irrational unless the attacker's goal is non-financial
(e.g., reputational damage).

**The 95/5 split** (OQ8 resolution): 95% of slashed bond goes
to the winner, 5% to the deployment treasury.  Aligns
challenger incentives with deployment safety while keeping
the sequencer-side downside concentrated.

---

## 4. Bisection-depth sizing

`MAX_BISECTION_DEPTH = 64`.

Why 64?
  * Covers initial dispute ranges up to `2^64` log entries.
  * `2^64` actions at 100 actions/second = ~5.8 trillion
    seconds = ~185k years.  Effectively unbounded.
  * Worst-case L1 gas per game: 64 rounds × 80k gas/midpoint
    + 64 rounds × 80k gas/response + 8M gas/single-step
    termination = ~18.5M gas.  Comfortably within a single L1
    block.

Could reduce to 32 (covers 2^32 = ~4B entries) and save half
the per-game gas.  But 32 is a hard ceiling; once a
deployment's log exceeds 2^32 entries, fault-proof games
break.  64 is the paranoid choice.

---

## 5. Trust-model upgrade: the precise claim

**Pre-Workstream-H assumption:** "M of N pre-approved
adjudicators are honest at adjudication time."

**Post-Workstream-H assumption:** "At least one party
(adjudicator or non-adjudicator) is willing to play the
fault-proof game with a bond during the dispute window."

Why "strictly weaker":
  * If all M of the original quorum are honest *and* willing
    to play, they satisfy both assumptions.
  * If any subset of the original quorum (≥ 1) is honest and
    willing, the new assumption holds; the old fails if the
    subset is < M.
  * If no original quorum member participates but any non-
    adjudicator with a Canon node and 0.05 ETH does, the new
    assumption holds; the old fails entirely.

The new assumption is satisfied in strictly more scenarios.

**The headline theorem (#232 family in `LegalKernel.FaultProof.Honesty`):**
  * `honest_strategy_unique` — uniqueness.
  * `honest_challenger_wins_per_round` — per-step content.
  * `honest_challenger_wins_via_sequencer_timeout` — timeout
    corollary.
  * `disagreement_persists_along_trace` — multi-step content.

Together with the convergence theorem (#231:
`bisection_converges_after_enough_rounds`) and the
coherence theorem (#225:
`recomputeCommitment_coherent_with_kernelOnlyApply`), these
establish the trust-model upgrade at the type level.

---

## 6. Why witness-state cell proofs (vs Merkle-path SMT)?

The plan §12.2 specifies SMT-based cell commitments for L1
gas optimisation.  The first-pass implementation uses
**witness-state cell proofs**: each `CellProof` carries the
full witness `ExtendedState`, and the verifier re-hashes the
witness to compare against the public commit.

**Why witness-state first?**

  * **Mathematically equivalent** for soundness purposes.
    Under `CollisionFree hashBytes`, both forms establish the
    cell-value's binding to the public commit.
  * **Simpler proofs.**  The witness-state form makes #221
    (verifier completeness) and #222 (soundness) provable
    in a few lines.  The SMT form requires the full per-cell-
    tag SMT lemma chain.
  * **Cross-stack tractability.**  The witness-state form
    means the L1 contract can re-hash the witness state to
    verify; no Merkle-path traversal needed.

**Cost.** L1 gas is O(state size) rather than O(log N).  For
small/medium deployments this is acceptable.  Production
deployments with large state may upgrade to SMT-form via the
`StepVMMerkle.sol` library; cross-stack equivalence with the
witness-state form is established at the fixture-corpus level.

---

## 7. Operator-facing decisions

When deploying Workstream H, deployment operators must
configure:

  * **`STATE_ROOT_SUBMISSION_BOND`** — scale to your value-
    at-risk per state-root window (recommended: ≥ 1% of VAR).
  * **`MIN_CHALLENGE_BOND`** — 0.05 ETH default; lower for
    high-frequency-low-stakes deployments, higher for value-
    sensitive ones.
  * **`FAULT_PROOF_DISPUTE_WINDOW`** — 30 days default.
    Shorter (e.g., 7 days) trades faster finality for less
    challenger detection time.
  * **`MIN_SUBMISSION_INTERVAL_BLOCKS`** — 100 blocks
    default; throttle submissions to allow detection time.
  * **Sequencer set** — single-sequencer per Workstream-E
    baseline; multi-sequencer is OQ3 (deferred).
  * **Treasury address** — receives the 5% bond redistribution.

See the operator runbook (Appendix K of the workstream plan)
for the full deployment checklist.

---

## 8. Future work

Items deferred from Workstream H:

  * **Solidity-side per-variant step functions (H.5.2.*)** —
    19 functions, one per Action constructor.  The skeleton
    `CanonStepVM.sol` ships; the per-variant cell-write
    semantic execution is a follow-up.
  * **Off-chain Rust observer crate (H.10.5)** — the Lean
    reference (`LegalKernel.FaultProof.Observer`) ships; the
    Rust crate ports it as a runtime adaptor.
  * **Cross-stack fixture corpus expansion** — F.1.8 (~344
    fixtures), F.1.9 (~38 fixtures), F.1.10 (~8 scenarios)
    are scaffolded with seed corpora; full population requires
    Solidity-side fixture consumption.
  * **SMT-form cell proofs** — production gas optimisation;
    `StepVMMerkle.sol` library is the bridge.

---

*End of Canon Fault-Proof Design Rationale.*

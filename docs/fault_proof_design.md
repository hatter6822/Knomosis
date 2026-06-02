<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis Fault-Proof Design Rationale

This document is the standalone design-rationale companion to
`docs/planning/fault_proof_migration_plan.md`.  It explains the *why*
behind the major design decisions of Workstream H, in plain
language, for deployment operators who don't read Lean.

For the *what* (engineering plan + per-WU specs), see
`docs/planning/fault_proof_migration_plan.md`.

For the *formal content* (Lean theorems + proofs), see
`LegalKernel/FaultProof/`.

---

## 1. Why interactive fault proofs over validity proofs (ZK)?

Knomosis's roadmap envisions three phases of dispute resolution:

| Phase | Mechanism | Trust assumption | Cost profile |
|-------|-----------|------------------|--------------|
| 1 | Bot-quorum (Phase 6) | M-of-N adjudicators | Cheap on L1; trust-heavy |
| **2** | **Interactive fault proofs (Workstream H)** | **1-of-anyone** | **Moderate L1 gas; honest-challenger trust** |
| 3 | Validity proofs (ZK) | SNARK soundness | Expensive prover; low trust |

Workstream H is Phase 2.  It strikes the best practical
balance between trust strength and L1 cost for Knomosis's current
production volumes.

**Why not ZK?**  Validity proofs (SNARKs / STARKs) are
unconditionally trust-minimal but require expensive prover
infrastructure ($1k+/proof on production circuits).  Knomosis's
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

Knomosis's kernel is *much smaller* — a `transfer` action is
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
    adjudicator with a Knomosis node and 0.05 ETH does, the new
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

**Scope: the bridge ledger is out of the per-step fault proof (by
design).**  The fault proof's per-step reference transition is
`kernelOnlyApply` (`recomputeCommitment = commitExtendedState ∘
kernelOnlyApply`), the kernel-EXECUTION semantics: it writes `base`
balances, `nonces`, `registry`, and `localPolicies`, and *provably
leaves the bridge ledger* (`consumed` / `pending` / `nextWdId`)
unchanged — `Disputes.kernelOnlyApply_preserves_bridge`,
`Disputes.kernelOnlyReplay_preserves_bridge`, and
`FaultProof.applyCellWrites_to_state_preserves_bridge`.  So the
bisection-adjudicated state-commitment chain holds the bridge
sub-state CONSTANT across every step it adjudicates: even a
`deposit` / `depositWithFee` / `withdraw` step re-derives only the
balance / nonce effect on chain, never the `consumed` / `pending`
mutation.

This is sound because the bridge ledger has its own verification
path, independent of the per-step bisection game:

  * **Deposit-replay protection** is enforced at admission time by
    `BridgeAdmissibleWith`'s deposit-id-freshness conjuncts (6 / 6b):
    a bridge-signed deposit carrying a reused `depositId` is rejected
    before it is ever applied or committed.
  * **Withdrawal tracking** is verified on L1 by the §13
    withdrawal-proof + finalisation chain (`Bridge.WithdrawalRoot`,
    `Bridge.Finalisation`), which proves a pending withdrawal's
    membership in the finalised L2 state root before the L1 bridge
    contract pays out.

The per-step bisection game therefore adjudicates the
kernel-execution sub-state; the bridge ledger is a constant context
within that game, secured by the two mechanisms above.  Bringing the
bridge ledger's per-step evolution *into* the bisection game — so a
disputed deposit's `consumed`-marking is itself re-executed on L1 —
is a possible future hardening (it would require lifting the L1 step
VM to model `applyActionToBridgeState` and matching the Solidity
`executeStep` cell-write set); it is not needed for the soundness
argument above and is tracked as future work.

---

## 6. Why witness-state cell proofs (vs Merkle-path SMT)?

The plan §12.2 specifies SMT-based cell commitments for L1
gas optimisation.  The first-pass implementation uses
**witness-state cell proofs**: each `CellProof` carries the
full witness `ExtendedState`, and the Lean verifier re-hashes
the witness to compare against the public commit.

**Why witness-state first?**

  * **Mathematically clean** at the Lean level.  Lean's
    `verifyCellProof` checks both `commitExtendedState
    witnessState = commit` AND `getCellValue witnessState
    cellTag = cellValue`.  Under `CollisionFree hashBytes`,
    the two checks together bind the cellValue to the public
    commit (Lean theorems #221 + #222 are provable in a few
    lines).
  * **Simpler proofs.**  The witness-state form makes #221
    (verifier completeness) and #222 (soundness) provable
    in a few lines.  The SMT form requires the full per-cell-
    tag SMT lemma chain.

**Cross-stack soundness gap (acknowledged).**  The Lean-side
verifier re-hashes the full witness state; the Solidity-side
`KnomosisStepVM` cannot afford to do so on L1 (gas-prohibitive).
Solidity only checks `witnessCommit == preStateCommit` and
trusts the proof's `cellValue` field — i.e., the Solidity
side has the FIRST binding check but not the SECOND.

For an honest responding party submitting canonical cell
values, both sides reach the same conclusion.  An adversarial
responder could in principle submit a cellProof whose
`witnessCommit` matches `preStateCommit` (legit binding) but
whose `cellValue` is forged (a lie about the cell content);
Lean's verifier rejects this, but Solidity's accepts.  The
gap closes when SMT-form cell proofs ship (`StepVMMerkle.sol`
provides the skeleton).

**Mitigations** for the current shipping form:

  * **Off-chain audit.**  Deployments should audit cell-proof
    submissions to challenge games, flagging any anomalous
    cellValue patterns.  The L1 contract emits per-game
    events that off-chain observers can cross-check against
    the canonical L2 state.
  * **Cross-stack fixture corpus.**  WU H.10.1 fixtures
    validate the honest case at every per-Action variant.

**Cost (SMT path, future).** L1 gas is O(log N) instead of
O(state size).  Production deployments with large state must
upgrade to SMT-form before going to mainnet; the cross-stack
fixture corpus closes the loop.

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

Items not in Workstream H's scope, tracked separately:

  * **Off-chain Rust observer crate (H.10.5)** — the Lean
    reference specification (`LegalKernel.FaultProof.Observer`)
    ships in this workstream; the Rust port is tracked as a
    runtime-adaptor follow-up, mirroring how the Phase-5 Rust
    host (WUs 5.4 / 5.7 / 5.8 / 5.11) was tracked separately
    from the Lean specification.
  * **SMT-form cell proofs** — production gas optimisation.
    The current witness-state cell-proof form is mathematically
    sound (theorem #221 / #222) and structurally simpler; the
    SMT form is a deployment-layer cost optimisation and is
    structurally compatible with the existing soundness
    arguments.  `StepVMMerkle.sol` is the bridge skeleton.
  * **Cross-stack fixture corpus expansion** — F.1.8 (~344
    fixtures), F.1.9 (~38 fixtures), F.1.10 (~8 scenarios)
    ship with seed corpora; deployment-time runs typically
    extend these with deployment-specific traffic patterns.

---

*End of Knomosis Fault-Proof Design Rationale.*

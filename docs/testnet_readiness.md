# Knomosis — Testnet-Readiness Assessment

**Date:** 2026-06-14
**Status:** Workstream P2 deliverable.  Companion to
`docs/audits/20-production-security-review-and-external-audit-scope.md`
and `docs/economic_incentive_analysis.md`.

> **Scope.**  *Deploying* a public testnet needs infrastructure (RPC,
> funded keys, hosts) outside this repository.  This document is the
> **go/no-go readiness gate** for that deployment: it inventories the
> shipped operational surface, maps it to a deployment topology, and
> gives a checklist + honest gap analysis.  Operational facts verified
> against source on 2026-06-14.

---

## 1. Operational surface (shipped, verified)

| Component | Crate / artefact | Role |
|-----------|------------------|------|
| **Sequencer / network adaptor** | `knomosis-host` | TCP/TLS/Unix listener; admission + bounded queue + two-tier DRR fair scheduler (`--scheduler drr`); `CommandKernel` |
| **Watchtower** | `knomosis-faultproof-observer` | off-chain bisection-game observer; honest strategy; L1 watcher; EIP-1559 submitter; persistence; chaos suite |
| **L1 ingest** | `knomosis-l1-ingest` | L1 event watcher; ABI decoder; re-org tolerance; raw-TCP submitter |
| **Event subscription** | `knomosis-event-subscribe` | log-tail reader → `extract-events`; bounded-lag eviction |
| **Indexer** | `knomosis-indexer` | SQLite event indexer; balance / budget / pool views |
| **L1 contracts** | `solidity/src/contracts/` (11) | bridge custody, state-root submission, fault-proof game, sequencer stake, identity registry, step-VM, disaster-recovery multisig, migration |
| **Runtime CLI** | `knomosis` / `knomosis-replay` | bootstrap, replay, event extraction |

**Acceptance & runbooks (shipped):** `make testnet-acceptance` /
`testnet-acceptance-dryrun` (Workstream F.3; `solidity/Makefile`),
`docs/fault_proof_runbook.md`, `docs/gas_pool_runbook.md`,
`docs/fault_proof_design.md`, the F.1.x cross-stack equivalence suite,
and the SVC step-VM + SC SMT cross-stack corpora.

## 2. Deployment topology (target)

```
        L1 (Ethereum testnet)                  L2 (Knomosis)
  ┌──────────────────────────────┐      ┌──────────────────────────┐
  │ KnomosisBridge (custody)      │◄─────┤ knomosis-host (sequencer)│
  │ KnomosisStateRootSubmission   │◄─────┤   admit → commit         │
  │ KnomosisFaultProofGame        │◄────►│ knomosis-l1-ingest       │
  │ KnomosisSequencerStake        │      │ knomosis-indexer (views) │
  │ AmmDisasterRecoveryMultisig   │      │ knomosis-event-subscribe │
  └──────────────────────────────┘      └──────────────────────────┘
            ▲   watch + challenge                 │ replay/audit
            └──────── knomosis-faultproof-observer (≥1 independent) ┘
```

## 3. Go / no-go readiness checklist

### 3.1 Contracts & parameters
- [ ] All 11 contracts deployed to the testnet and **source-verified**
      on the explorer.
- [ ] Constructor parameters (`MIN_CHALLENGE_BOND`, bisection timeouts,
      `stakeAmount`, `maxDrainPerAction{Eth,Bold}`, `MIN_FEE_BPS` /
      `MAX_FEE_BPS`, TVL cap) **sized per `docs/economic_incentive_analysis.md`
      IC-1…IC-6** for testnet gas/value assumptions.
- [ ] `KnomosisAmmDisasterRecoveryMultisig` signer set chosen; `N`
      such that 3-of-N collusion exceeds reserve value (E-2/§5).

### 3.2 Trust-binding hardening (from the security review)
- [ ] **F-1:** run `knomosis hash-check` in the deploy pipeline — the
      gate is **implemented** (exit 1 on the FNV-1a-64 fallback, exit 0
      on a production-grade hash) — so the 64-bit fallback can **never**
      reach production.
- [ ] **F-2:** verifier-identifier assert — **done** (run
      `knomosis verify-check` in the deploy pipeline; exit 1 on the
      Lean-opaque fallback). **Remaining:** SHA-256-pin the cdylib
      artefacts (`knomosis-verify-secp256k1`, `knomosis-hash-keccak256`).

### 3.3 Liveness / watchtower (the IC-3 assumption)
- [ ] ≥1 **independent** `knomosis-faultproof-observer` running and
      funded; alerting on `BISECTION_RESPONSE_TIMEOUT` headroom.
- [ ] Re-org tolerance + persistence verified under the observer chaos
      suite against the testnet.

### 3.4 Acceptance
- [ ] `make testnet-acceptance` passes against the *deployed* contracts
      (not just the local fork dry-run).
- [ ] The F.1.x cross-stack equivalence + SVC step-VM + SC SMT corpora
      pass against the deployed step-VM / verifiers.
- [ ] `knomosis-bench` throughput on the target hardware meets the
      deployment's TPS target (baseline ~7.5k ops/sec observed).

### 3.5 Operations
- [ ] `docs/fault_proof_runbook.md` + `docs/gas_pool_runbook.md`
      dry-run by the on-call operator end-to-end.
- [ ] Key custody: `gasPoolActor`, `sequencerActor`, multisig signers,
      L1 submitter (`Zeroizing`); rotation + incident procedures.
- [ ] Monitoring/alerting: state-root submission cadence, observer
      challenges, pool drain vs cap, bridge TVL vs cap, indexer lag.

### 3.6 Pre-mainnet (beyond testnet)
- [ ] Independent external audit complete (scope:
      `docs/audits/20-…`); findings remediated.
- [ ] Adversarial fuzzing of the untrusted-input boundaries (security
      review §4.3) run to a coverage target.
- [ ] v2 receipt-verified reimbursement (GP.8.5) if the pool will hold
      material value (economic analysis §4 / IC-6).
- [ ] Decentralised sequencing path (OQ-H-2) evaluated.

## 4. Status & gaps

**Ready (shipped & verified):** the full operational daemon set, the L1
contract suite (~867 forge tests green), the cross-stack corpora, the
F.3 acceptance harness, and the two operator runbooks.  The system is
*functionally* deployable to a testnet today.

**Gaps before a *value-bearing* public testnet** (ordered):
1. The **F-1 / F-2 trust-binding hardening** (security review §7) — the
   single most important pre-deployment code items.
2. A **deployment parameterisation guide** encoding IC-1…IC-6
   (economic analysis E-1) so bonds/caps/stakes/fees are sized, not
   guessed.
3. **Monitoring/alerting + key-custody** procedures (§3.5) — currently
   the daemons exist but the *operational* wrapping does not.
4. **Adversarial fuzzing** of the untrusted-input boundaries (queued P2
   test-expansion increment).
5. The **independent external audit** (the §20 scope) — the gate to
   *mainnet*, strongly advisable before a value-bearing testnet.

**Recommendation.**  A *shadow / no-value* testnet (the daemons + the
F.3 acceptance suite against deployed contracts, with observers) can run
**now** and is the right next operational step — it exercises the whole
stack end-to-end and de-risks the runbooks.  Gating a *value-bearing*
testnet on items 1–2 (and ideally 5) is the responsible sequence.

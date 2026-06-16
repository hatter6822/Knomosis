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
      Lean-opaque fallback). Cdylib **SHA-256 artefact pin — done for
      both** adaptors: `scripts/verify_secp256k1_link.sh`
      (`knomosis-verify-secp256k1`) and `scripts/verify_keccak_link.sh`
      (`knomosis-hash-keccak256`) record / `--check` the staticlib
      SHA-256 and prove the fallback→production flip (CI:
      `ci-verify-secp256k1.yml`, `ci-hash-keccak256-link.yml`).
      **Remaining:** run the `--check` pin in the deploy pipeline as a
      required step.

### 3.3 Liveness / watchtower (the IC-3 assumption)
- [ ] ≥1 **independent** `knomosis-faultproof-observer` running and
      funded; alerting on `BISECTION_RESPONSE_TIMEOUT` headroom.
- [ ] Re-org tolerance + persistence verified under the observer chaos
      suite against the testnet.

### 3.4 Acceptance
- [x] **Local devnet end-to-end** — `make devnet`
      (`solidity/scripts/local_devnet.sh`) spins up a LIVE anvil node,
      BROADCAST-deploys the full suite, and verifies against the
      *deployed* contracts (on-chain bytecode + a live `deploymentId()`
      read).  Green locally; the live-node counterpart to the in-memory
      `testnet-acceptance-dryrun`.  **Surfaced finding:** the F.3
      `Deployer` is a CREATE3 *bundler* test-harness (43 065 B) that
      exceeds the EIP-170 limit, so `make testnet-acceptance` against a
      real RPC needs `--disable-code-size-limit` (or a non-bundling
      deploy path) — but **every PRODUCTION contract is comfortably
      under the limit** (`forge build --sizes`: Bridge 17 195 B / 7 381 B
      margin, FaultProofGame 7 551 B, all others well under), so the
      production contracts are genuinely deployable; only the test
      bundler needs the accommodation.
- [ ] `make testnet-acceptance` passes against the *deployed* contracts
      on a real RPC (not just the local devnet) — see the `Deployer`
      bundler note above.
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
      `docs/audits/20-…`); findings remediated.  An **internal** deep
      review (`docs/audits/21-…`) is done: it found + fixed 5 real
      contract defects (1 Critical, 1 High, 3 Medium/Low).
- [~] Adversarial fuzzing of the untrusted-input boundaries (security
      review §4.3).  **Partial:** never-panics property fuzz now covers
      the l1-ingest ABI decoder, the host frame reader, and the indexer
      decoder + two-pass dispatch (all-tag + overflow amounts); the SMT
      verifier has adversarial size-discipline tests.  **Remaining:** a
      coverage-target sweep + cargo-fuzz on the network boundaries.
- [x] v2 receipt-verified reimbursement (GP.8.5) — the gate is shipped
      (`LegalKernel.Bridge.ReceiptVerifiedClaim` + the Rust mirror);
      *enable* it before the pool holds material value (economic
      analysis §4 / IC-6).
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
4. **Adversarial fuzzing** of the untrusted-input boundaries —
   *in progress*: never-panics property fuzz on the l1-ingest decoder,
   host frame reader, and indexer decoder + dispatch; SMT
   size-discipline adversarial tests.  A coverage-target sweep +
   cargo-fuzz on the network boundaries remain.
5. The **independent external audit** (the §20 scope) — the gate to
   *mainnet*, strongly advisable before a value-bearing testnet.  The
   internal deep review (§21) has remediated 5 contract defects ahead of
   it.

**Recommendation.**  A *shadow / no-value* testnet (the daemons + the
F.3 acceptance suite against deployed contracts, with observers) can run
**now** and is the right next operational step — it exercises the whole
stack end-to-end and de-risks the runbooks.  Gating a *value-bearing*
testnet on items 1–2 (and ideally 5) is the responsible sequence.

<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis — Sepolia Launch Execution Checklist (value-bearing, BOLD + AMM)

**Status:** Operator-facing execution checklist for a value-bearing Sepolia
launch of the FULL suite (BOLD + functional AMM).  This is the
**execution-ordered index**: it sequences the steps and points at the
reference docs that own the detail — it deliberately does **not** duplicate
them.

- Deploy procedure (reference): `docs/sepolia_deployment_runbook.md`
- Parameter sizing: `docs/deployment_parameters.md` + `scripts/economic_simulation.py`
- Fill-in env template: `solidity/deploy.sepolia.env.example`
- One-command wrapper: `scripts/deploy_sepolia_launch.sh`
- Watchtower / fault-proof ops: `docs/fault_proof_runbook.md`
- Gas-pool / claim ops: `docs/gas_pool_runbook.md`
- Readiness gates: `docs/testnet_readiness.md` §3

> **The only manual inputs a launch requires** (everything else is
> automated by the wrapper):
> 1. **Fund the deployer EOA** with Sepolia ETH.
> 2. **Fill the env template** with your custodied addresses / signer.
> 3. **Provide** `SEPOLIA_RPC_URL` + `ETHERSCAN_API_KEY`.

---

## 0. Pre-flight (before you touch the RPC)

- [ ] **PR merged.** The launch commit is on `main`; you are deploying a
      merged, reviewed tree (not a feature branch).
- [ ] **Toolchain present.** `foundry` (`forge`/`cast`), the Lean toolchain
      (`./scripts/setup.sh`), and the Rust workspace build
      (`cd runtime && cargo build --workspace`). See runbook §1.
- [ ] **Foundry broadcast preflight.** Use a **stable** `foundry` release and
      confirm it broadcasts the full suite: `make deploy-local` against a local
      `anvil` must succeed. Some foundry *dev builds* regress on the
      `KnomosisDisputeVerifier` `constructor(tuple)` broadcast decode
      (`type check failed for "offset (usize)"`, before any tx is sent); the
      deploy logic is unaffected but the broadcast aborts. See
      `DEVELOPMENT.md` §10.5.
- [ ] **Parameters sized.** Run `python3 scripts/economic_simulation.py`
      against YOUR target gas price × trace depth; confirm the IC-1/2/5/6
      asserts pass with the values you will use. Record them. See
      `docs/deployment_parameters.md`.
- [ ] **Env filled.** `cp solidity/deploy.sepolia.env.example
      solidity/deploy.sepolia.env` and fill every `SET-THIS…`. The filled
      copy is git-ignored — never commit it.
- [ ] **Keys custodied** (see §5 for the full inventory). Each on-chain role
      (attestor, sequencer, treasury, adjudicators, BOLD breaker/admin, the
      AMM multisig signers) is an address whose key you control — **none is
      the deployer EOA**, and the AMM multisig has ≥ 3 distinct signers.
- [ ] **Deployer EOA funded** with enough Sepolia ETH for ~9
      contract-creation txs + the AMM seed (a few test-ETH is ample).
- [ ] **RPC + Etherscan** set (`SEPOLIA_RPC_URL`, `ETHERSCAN_API_KEY`).

## 1. Deploy (one command)

```bash
./scripts/deploy_sepolia_launch.sh solidity/deploy.sepolia.env
```

The wrapper runs, fail-fast, in order: env validation → **F-1/F-2
trust-binding gate** (a fallback crypto adaptor can never reach a
value-bearing deploy) → **in-memory dry-run** (catches config errors with no
gas) → **confirm** → **real broadcast + Etherscan verify** → prints the
addresses manifest. Add `--with-l2-stack` to bring up the L2 daemons against
the manifest in the same run, or `--dry-run` to stop before broadcasting.

- [ ] Dry-run passed (consistent deployment).
- [ ] Broadcast + Etherscan source-verification succeeded.
- [ ] Manifest written to `solidity/deployments/sepolia.json`.

## 2. Post-deploy verification

- [ ] **Manifest sanity.** Every contract address is present and non-zero;
      `l2ChainId` = `83572` (Sepolia test). See runbook §5.
- [ ] **On-chain wiring.** `bridge.migration() == 0` at genesis; the
      disaster-recovery multisig is the bridge's `ammDisasterRecovery` and its
      threshold is ≥ 3; the BOLD token resolves (`bridge.boldToken()`).
- [ ] **Runtime crypto grade.** The binary you will run reports production
      crypto: `knomosis hash-check` **and** `knomosis verify-check` both exit
      0 (F-1/F-2 on the *deployed* binary, not just the build gate).
- [ ] **Sources verified on Etherscan** for every deployed contract.

## 3. L2 stack + gateway

- [ ] **L2 daemons up** against the manifest:
      `MANIFEST=solidity/deployments/sepolia.json ./scripts/knomosis_l2_sepolia_stack.sh`
      (or the wrapper's `--with-l2-stack`). See runbook §6.
- [ ] **Gateway healthy.** `/healthz` 200; `/readyz` reports the indexer +
      upstreams ready; `/v1/info` shows the expected admission stage, wire
      versions, and `l2ChainId`. Auth is fail-closed (token file present,
      not world-readable). See runbook §7.
- [ ] **Public TLS** terminates at the gateway (or a co-located edge) — the
      per-request read deadline now bounds the TLS handshake/record I/O
      (slow-loris hardened); set `--sse-*` tunables per your load.

## 4. Ongoing operations (the launch is not "done" at broadcast)

### 4.1 Watchtower liveness (IC-3 — load-bearing, no constructor substitutes)
- [ ] **≥ 1 independent, funded `knomosis-faultproof-observer`** running with
      its own truth oracle and L1 submitter key. See
      `docs/fault_proof_runbook.md`.
- [ ] **Alert on bisection-timeout headroom:** page if an honest response
      would approach `bisectionResponseTimeout`; the observer must always be
      able to respond within a round.
- [ ] Run a **second, independently-operated** observer before the bridge
      holds material value (do not co-locate all watchtowers).

### 4.2 Monitoring + alerting
- [ ] **TVL vs caps:** alert as bridged value approaches `tvlCap` /
      `boldTvlCap` (raising a cap needs a migration — lead time).
- [ ] **Dispute / challenge events:** surface every `StateRoot` challenge,
      dispute filing, and settlement; a challenge that goes unanswered is an
      incident.
- [ ] **BOLD circuit breaker + AMM state:** alert on any pause / disable and
      on the receipt-verified-claim (GP.8.5) reimbursement flow; run ≥ 1
      independent `receipt_verifier` observer for the BOLD leg (a stale
      ETH→BOLD rate only under-reimburses). See `docs/gas_pool_runbook.md`
      §8 / §11.
- [ ] **Gateway + indexer health:** `/readyz`, request-error rate, indexer
      cursor lag behind the L1 tip, SSE stream count vs `--sse-max-streams`.

### 4.3 Key custody + rotation
- [ ] **Inventory** (each held separately; NOT the deployer EOA):
      `attestor`, `sequencer`, `treasury`, the `adjudicator` set, the
      `gasPoolActor` / `sequencerActor`, the BOLD `circuitBreaker` +
      `admin` (distinct), the L1 submitter, and the **AMM multisig signers**.
- [ ] **Multisig hygiene:** BOLD breaker/admin and the AMM disaster-recovery
      signers are multisigs (audit-21 B.2). Collusion of `threshold` AMM
      signers must cost more than the AMM reserve value. The multisig's 7-day
      group-expiry bounds a stale-quorum attack — track it.
- [ ] **Rotation:** immutable on-chain roles (attestor, sequencer, treasury,
      the fixed adjudicator set, BOLD roles) can only be changed by a
      `KnomosisMigration` redeploy — plan rotations as migrations. Off-chain
      keys (observer/L1-submitter, gateway bearer tokens) rotate freely;
      schedule a cadence and rotate on any suspected exposure.

### 4.4 Incident response
- [ ] **AMM emergency:** the disaster-recovery multisig fires
      `emergencyDisableAmm()` (3-of-N); the L2 reserve-reclamation flow
      follows. Runbook: `docs/fault_proof_runbook.md` §10 (recovery decision
      tree) and `docs/gas_pool_runbook.md`.
- [ ] **BOLD emergency:** the `circuitBreaker` pauses the BOLD leg
      (pause-only; it cannot move funds).
- [ ] **Teardown / redeploy** procedure: runbook §10.

## 5. Sign-off

- [ ] All of §0–§3 checked; §4.1 watchtower confirmed live; §4.2 alerts wired.
- [ ] The chosen parameter values are recorded (manifest + ops store) and
      match what `scripts/economic_simulation.py` asserts.
- [ ] `docs/testnet_readiness.md` §3 gates reconciled.

*This checklist sequences the launch; the reference docs above own the
detail. When a step here disagrees with a reference doc, the reference doc
wins — open an issue so this index is corrected.*

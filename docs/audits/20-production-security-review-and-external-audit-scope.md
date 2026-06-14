# Knomosis — Production Security Review & External-Audit Scope

**Date:** 2026-06-14
**Author:** internal review (Workstream P2 — production readiness)
**Status:** living document; the scoping input for an external audit.

> **This is not the §00–§19 Lean-module audit.**  Those reports audited
> the Lean source for *correctness* (and Workstream AR closed every
> finding).  This document audits the system for **deployment / fund
> safety**: it maps the trust boundary, distinguishes what the formal
> proofs *do* cover from the **residual surface they cannot**, and
> produces a prioritised scope + hardening checklist for an independent
> third-party audit.  All claims below were verified against source on
> 2026-06-14 (documentation was not trusted as a description of code).

---

## 1. Purpose

Knomosis is self-described **research-stage** software.  Its formal
guarantees are unusually strong, but formal proofs are *necessary, not
sufficient* for handling real value on a public network.  The residual
risk lives precisely where the theorems stop — the trust assumptions,
the fund-holding L1 contracts, the cross-stack fidelity, the non-TCB
runtime, operations/key-management, and the economic incentives.  This
review names that surface and scopes its independent validation.

## 2. The trust model (verified)

**TCB.**  691 lines total — `LegalKernel/Kernel.lean` (393) +
`LegalKernel/RBMapLemmas.lean` (298) — over **Lean core only** (no
Mathlib / batteries).  `#print axioms` on every kernel theorem returns a
subset of exactly `{propext, Classical.choice, Quot.sound}`; **no custom
axioms exist** (`tcb_audit`, `count_sorries`, `naming_audit` enforce
this in CI).  This is an exceptionally small, clean trusted core.

**The two trust assumptions are `opaque`, not `axiom`** (so the axiom
profile stays canonical), and both are discharged at runtime by
deployment-supplied implementations:

| # | Assumption | Surface | How discharged | Residual risk |
|---|-----------|---------|----------------|---------------|
| TA-1 | Signature scheme is EUF-CMA secure | the `verify : PublicKey → ByteArray → Signature → Bool` **parameter** threaded through `AdmissibleWith` (the spec-level `opaque Verify` is its abstraction) | production injects the `@[extern]` ECDSA-secp256k1 cdylib (`knomosis-verify-secp256k1`) | the *injected* verifier's correctness/security; the FFI marshalling |
| TA-2 | Hash is collision-resistant | `Runtime.Hash.{hashBytes,hashStream}` (`@[extern "knomosis_hash_bytes"]`) | production links BLAKE3 (256-bit) / keccak-256 (`knomosis-hash-keccak256`) | **the FNV-1a-64 fallback (`knomosis-hash-fallback.c`) is only 64-bit** — see Finding F-1 |

**Test-crypto containment.**  `MockCrypto.mockVerify`/`mockSign` exist
for happy-path tests; the `mock_import_audit` binary (CI gate) proves no
production module imports them.  Verified.

## 3. What the proofs *do* cover (do not re-audit)

The following are mechanised, axiom-clean theorems — an external audit
should treat them as **given** and not re-derive them:

- **Kernel (TCB):** determinism, no-silent-illegality
  (`impl_noop_if_not_pre`), refinement (`impl_refines_spec`), invariant
  preservation/composition, certified ≡ executable, reachability.
- **Economics:** supply conservation (`transfer_conserves`,
  `total_supply_global`); **chain-level bridge solvency & the §7.6.4
  escrow identity** (`bridge_chain_conserves`,
  `bridgeReachable_solvent`, `bridge_chain_accounting_equation` — CA).
- **Authority:** nonce-uniqueness, replay-impossibility, action-compile
  injectivity, actor-scoped local-policy independence.
- **Encoding:** the EI.2–EI.8 injectivity ladder
  (`State.encode_injective` → state-commitment extensional equality).
- **Fault proof:** bisection convergence, honest-challenger settlement,
  SMT cell-proof soundness, 25-variant step-VM dispatcher coherence.
- **Gas pool:** outflow cap (`gasPoolPolicy_permits_transfer_iff`),
  per-resource drain bound, AMM reserve isolation, AMM state-root
  commitment.

These hold **relative to TA-1/TA-2** and **for the Lean model**.  The
audit's job is everything *outside* that bracket.

## 4. Residual-risk surface (the audit scope)

### 4.1 The fund-holding L1 contracts — **highest priority**

`solidity/src/contracts/` — 11 contracts.  The contracts that hold or
move value:

- **`KnomosisBridge.sol`** — custodies ETH (`payable`/`msg.value`) and
  ERC-20 (`SafeERC20`); deposits, withdrawals against a verified
  withdrawal root, the GP.5 fee-split + BOLD circuit-breaker + TVL cap.
  Uses `ReentrancyGuard` + `nonReentrant` on value-moving paths
  (verified).
- **`KnomosisSequencerStake.sol`**, **`KnomosisFaultProofGame.sol`** —
  custody the sequencer bond / challenge stakes that the fault-proof
  game pays out.
- **`KnomosisAmmDisasterRecoveryMultisig.sol`** — the 3-of-N kill
  switch (100% line/branch coverage, 7-invariant stateful suite).

These are **corpus-linked + Foundry-tested (~867 passing)** but **not
fully formally proven** — they are the single most important external
audit target.  Focus: reentrancy beyond the guarded paths; access
control / signer authorisation; the withdrawal-root verification vs the
Lean `verifyProof_sound`/`_complete` spec; fault-proof game settlement &
payout vs `honest_challenger_wins…`; multisig threshold/expiry/replay;
integer/rounding in the fee-split & AMM; the BOLD circuit-breaker /
TVL-cap state machine; upgrade/migration (`KnomosisMigration`) authority.

### 4.2 Cross-stack fidelity (Lean ↔ EVM ↔ Rust)

The three stacks are reconciled by **corpora, not exhaustive proof**: 6
`.cxsf` fixtures (`ecdsa_secp256k1`, `keccak256`, `l1_ingest{,_bold,_fee_split}`,
`amm_swap`), the 278-entry step-VM corpus, and the SMT cell-proof
corpus.  Audit the **coverage**, not just the pass/fail: are all 25
action variants + boundary/adversarial inputs represented?  Is the
encoded equivalence the *intended* spec equality?  A divergence here is
a silent soundness gap (the EVM/Rust could accept what the Lean spec
rejects).  See P2 §6 (adversarial-corpus expansion).

### 4.3 The non-TCB Rust runtime

11 crates, ~1 960 tests, `unsafe_code = "forbid"` **except** the two FFI
cdylibs (`knomosis-verify-secp256k1`, `knomosis-hash-keccak256`), which
narrow to `deny` for their `#[no_mangle] pub unsafe extern "C"` entry
points + C shim.  The unsafe surface is therefore **small and
well-isolated** — audit the FFI marshalling (buffer lengths, null/short
inputs, ownership) in those two crates.  Fuzz the **untrusted-input**
boundaries: `knomosis-host` frame parser, `knomosis-l1-ingest` ABI
decoder, `knomosis-indexer` state reconstruction, and the
`knomosis-faultproof-observer` game state machine.

### 4.4 Operations & key management

Keys: `gasPoolActor` (the reimbursement claim signer, Track B),
`sequencerActor`, the disaster-recovery multisig signers, the L1
submitter (`Zeroizing` in the observer — verified).  The Track B
reimbursement is an **honour-system** claim (v1): bounded by
`gasPoolPolicy` per-action + the GP.7.3 per-trace drain bound, but
`amount` is *not* proven to equal real L1 gas spent (v2/GP.8.5 makes it
receipt-verified, deferred).  Audit key-custody, the multisig
operational security, and the honour-system bound's acceptability for
the target deployment.

### 4.5 Economic incentives — **not formally modelled**

The fault-proof game, gas-pool fee economics, AMM, and disaster-recovery
multisig have *safety* proofs but no *incentive/equilibrium* analysis
(is honesty the equilibrium? bond sizing vs griefing cost? fee-cap vs
sequencer profitability?).  This is the subject of the companion
deliverable `docs/economic_incentive_analysis.md` (P2).

## 5. Findings

| ID | Severity | Finding |
|----|----------|---------|
| **F-1** | **Medium → addressed** | The hash fallback `knomosis-hash-fallback.c` provides only **64-bit** collision resistance (FNV-1a-64); the state-commitment soundness assumes ≥128-bit. The strong binding (BLAKE3/keccak via `@[extern]`) is the production default and the fallback is for tests/CI, but previously **nothing failed if a production binary shipped the fallback**. A 64-bit hash makes state-commitment collisions feasible (~2³² work), forging fault-proof state roots. **Addressed (2026-06-14):** the `knomosis hash-check` subcommand now *fails closed* — it prints the binding and exits `1` on the fallback, `0` on a production-grade hash. Deployment/release pipelines MUST run it as a required gate (verified: exits 1 on the CI/dev fallback build). Residual operational step: wiring it into the release pipeline. |
| **F-2** | Low → partly addressed | TA-1/TA-2 are deployment-injected; a deployment that injects a *broken* verifier/hash silently loses all guarantees. Mitigated by the cdylibs + the cross-stack corpora, but the **injection point is unauthenticated at the Lean level** (build-time linkage). **Addressed (2026-06-14):** the verifier-identifier assertion is now implemented — `knomosis verify-check` fails closed (exit 1) on the Lean-opaque fallback and exit 0 when the secp256k1 cdylib (which now exports `knomosis_verify_identifier`) is linked; mirrors the F-1 hash gate. **Residual:** SHA-256-pin the cdylib *build artefacts* (a build-pipeline step, as `scripts/setup.sh` does for the toolchain). |
| **F-3** | Informational | Cross-stack equivalence is corpus-validated (§4.2). No finding of divergence; the risk is **coverage**, addressed by P2 §6 adversarial-corpus expansion. |
| **F-4** | Informational | Economic incentives are unmodelled (§4.5) — not a defect, a scope gap for the companion analysis. |

No critical or high findings in the reviewed surface.  The formally
verified core is sound; residual risk is concentrated in the L1
contracts (§4.1) and the deployment-discipline items above.

## 6. Recommended external-audit scope (priority order)

1. **`KnomosisBridge.sol` + the fund-holding contracts** (§4.1) — full
   manual review + symbolic/fuzz; this is where real funds live.
2. **The Lean↔Solidity boundary** — that the EVM withdrawal-root
   verifier, step-VM, and SMT verifier faithfully implement the Lean
   spec they mirror (the cross-stack corpus is the bridge; audit its
   coverage and the encoders).
3. **The two FFI cdylibs** (§4.3) — the only `unsafe` Rust.
4. **TA-1/TA-2 discharge** (§2) — that the injected secp256k1 & BLAKE3/
   keccak bindings are correct and correctly linked (F-1/F-2).
5. **The TCB** (`Kernel.lean`, `RBMapLemmas.lean`) — small; a
   confirmatory read of the spec ↔ theorem statements.

## 7. Pre-audit hardening checklist (Workstream P2)

- [x] **F-1 (gate implemented):** `knomosis hash-check` fails closed on
      the FNV-1a-64 fallback (exit 1; verified). **Remaining:** wire it
      into the release/deploy pipeline as a required gate.
- [~] **F-2:** verifier-identifier startup assert **done**
      (`knomosis verify-check`; cdylib exports `knomosis_verify_identifier`).
      **Remaining:** SHA-256-pin the cdylib build artefacts (pipeline).
- [ ] **Adversarial-corpus expansion** (§4.2) — boundary/adversarial
      fixtures for all 25 action variants + the fund paths
      (companion: P2 test-expansion increment).
- [~] **Fuzz the untrusted-input boundaries** (§4.3) — *started:* the
      L1-log ABI decoder (`decode_event`) is proptest-fuzzed for
      never-panics on arbitrary topics/data
      (`knomosis-l1-ingest/tests/property.rs`). **Remaining:** the host
      frame parser, the indexer state reconstruction, and the observer
      game state machine (same never-panics property).
- [ ] **Economic-incentive analysis** (§4.5) —
      `docs/economic_incentive_analysis.md`.
- [ ] **Testnet-readiness** — `docs/testnet_readiness.md`: exercise the
      F.3 dry-run, the runbooks, and the observer/sequencer end-to-end.

---

*This document is the scoping input for an independent audit and the
checklist for the remaining Workstream-P2 hardening.  It does not
itself constitute an external audit.*

<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis — Deployment Parameter Sizing Guide

**Date:** 2026-06-16
**Status:** Workstream P2 deliverable.  Companion to
`docs/economic_incentive_analysis.md` (the IC-1…IC-6 conditions),
`docs/audits/20-production-security-review-and-external-audit-scope.md`
(§4.5 / E-1), and `docs/testnet_readiness.md` (§3.1).

> **Why this document exists.**  Knomosis's *safety* properties are
> mechanised theorems, but its mechanism parameters — bonds, stakes,
> caps, fees, timeouts — are **deployment-immutable constructor values**.
> Incentive-compatibility (IC-1…IC-6) and the safety/liveness margins
> depend *entirely* on choosing them correctly for the target chain, gas
> price, and asset values.  This guide enumerates **every**
> deployment-immutable parameter of the fund-holding contracts, maps each
> to the IC condition (or constructor guard) that constrains it, and gives
> sizing guidance.  It is the operator-facing complement to the
> *parametric* economic analysis: that document states the *conditions*;
> this one says *which knob* and *how to turn it*.
>
> **All parameters below are immutable after construction** (changing one
> requires a full `KnomosisMigration` redeploy).  Size them once,
> correctly.  Parameter facts verified against the contract source on
> 2026-06-16.

---

## 1. How to size: the calibration harness

Do **not** invent numbers.  `scripts/economic_simulation.py` turns
IC-1…IC-6 into a swept numeric envelope for *your* deployment assumptions:

```bash
python3 scripts/economic_simulation.py        # prints the sizing tables + --asserts IC-1/2/5/6
```

It models the fault-proof game, the dispute-staking pipeline, and the gas
pool, and prints (a) the minimum incentive-compatible challenge bond per
trace-depth × gas-price, (b) the anti-spam stake floor, and (c) the
v1-honour-system vs v2-receipt-verified pool over-payment.  A green run
asserts the IC conditions hold across the swept grid.  *Representative
output:* at 50 gwei and a depth-2²⁰ trace, the minimum incentive-compatible
`MIN_CHALLENGE_BOND` is ≈ **0.115 ETH**.  Run it against your target gas
price and `N` (= log-depth of the bisection trace) before fixing the
numbers below.

**Workflow.**  (1) Estimate target chain gas price, the bisection trace
depth `N`, and the value of each bridged asset.  (2) Run the harness to
get the bond / stake / cap floors.  (3) Fill the per-contract values
below at or above those floors.  (4) Re-run the harness with your chosen
values to confirm the `--assert` checks pass.  (5) Record the chosen
values in the deployment manifest and the `make testnet-acceptance`
fixtures.

---

## 2. KnomosisFaultProofGame — challenge economics (IC-1, IC-2)

`constructor(uint64 bisectionResponseTimeout, uint128 minChallengeBond,
uint64 minBisectionStepInterval, address treasury, address stepVM,
address stateRootSubmission)`

| Parameter | Unit | IC | Sizing guidance |
|-----------|------|----|-----------------|
| `minChallengeBond` | wei | **IC-1, IC-2** | The bond `B` an honest challenger locks and a dishonest one forfeits.  The winner's share `R` of the slashed bond — **95 % after the 5 % `treasury` skim** (`winnerPayout = totalBonds·95/100`) — must exceed the L1 gas `G_c` to play the `⌈log₂ N⌉`-round game (IC-1: `R ≥ G_c`), *and* `B` must exceed a frivolous challenger's expected gain (IC-2).  Size from the harness's "min incentive-compatible bond" at your gas price × depth, then add margin for gas spikes.  **Re-check IC-1 after the 5 % skim** at small `B`. |
| `bisectionResponseTimeout` | L1 blocks | IC-2, IC-3 | The per-round response window.  Too short ⇒ an honest party with normal L1 latency loses by timeout; too long ⇒ an invalid root finalises slowly and locks bonds (capital cost).  Size to comfortably exceed honest L1-inclusion latency at the target chain's congestion, with headroom for the watchtower (IC-3). |
| `minBisectionStepInterval` | L1 blocks | IC-2 | Anti-DoS floor on the response *rate*; bounds the defender's burst cost `G_d`.  **Constructor guard:** must be `< bisectionResponseTimeout` (`InvalidTimeoutConfig`; audit-21 finding 1.4) — otherwise the responsible party can never act before the deadline. |
| `treasury` | address | — | Recipient of the 5 % slashed-bond skim (OQ8).  Use an address that does **not** revert on ETH receipt; settlement is pull-payment (audit-21 finding 1.3), so a reverting treasury no longer bricks the game, but it would forfeit its own share. |

## 3. KnomosisStateRootSubmission — sequencer submission bond

`constructor(uint128 bond, uint64 disputeWindow, uint64 minSubmissionInterval,
uint64 maxOutstandingRoots, address sequencer, address faultProofGame,
bytes32 deploymentId, uint64 withdrawalFinalisationWindow)`

| Parameter | Unit | Guidance |
|-----------|------|----------|
| `bond` | wei | The sequencer's per-root submission bond, at risk to a successful challenge.  Size ≥ the value a sequencer could extract by submitting one invalid root (so dishonest submission is −EV given the fault-proof game). |
| `disputeWindow` | L1 blocks | Window during which a root may be challenged before it finalises.  Must give ≥1 independent observer (IC-3) time to detect and challenge.  Coordinate with the game's `bisectionResponseTimeout`. |
| `withdrawalFinalisationWindow` | L1 blocks | Delay before a withdrawal against a root is spendable.  Should cover `disputeWindow` plus a full game's worst-case length (`⌈log₂ N⌉ · bisectionResponseTimeout`). |
| `minSubmissionInterval` | L1 blocks | Lower bound on submission cadence (anti-spam). |
| `maxOutstandingRoots` | count | Cap on un-finalised roots in flight (bounds challenge surface + state). |

## 4. KnomosisSequencerStake — sequencer slashing

`constructor(bytes32 knomosisVersionTag, address sequencer,
address disputeVerifier, address bridge, uint256 slashRatioBps,
uint64 disputeWindowBlocks, address burnAddress)`

| Parameter | Unit | Guidance |
|-----------|------|----------|
| `slashRatioBps` | bps | Fraction of the slashed sequencer stake paid to the successful challenger; the remainder burns to `burnAddress`.  Size the challenger share ≥ the challenger's cost (reinforces IC-1 for sequencer-fault disputes).  **Note (audit-21 finding 2.1):** the first upheld dispute consumes 100 % of `totalStaked`; under a multi-concurrent-dispute model, escrow per-dispute portions instead. |
| `disputeWindowBlocks` | L1 blocks | Window to open a sequencer-stake dispute. |
| `burnAddress` | address | Sink for the non-challenger slash remainder. |

## 5. KnomosisBridge — custody, fees, TVL, BOLD, AMM

`constructor(ConstructorArgs args)` — the economically-load-bearing fields:

| Field | Unit | IC / guard | Guidance |
|-------|------|-----------|----------|
| `tvlCap` | wei | §5 (exposure bound) | Global ceiling on bridged value.  Bounds total at-risk capital; start conservative on a young deployment and raise via migration as confidence grows. |
| `minFeeBps` / `maxFeeBps` | bps | §5 (user picks fee) | The band within which a depositor **chooses** the pool fee.  The deployer cannot extract via a high default (the *user* picks); a malicious user paying a high fee only gifts the sequencer.  **Constructor guards:** `minFeeBps ≤ maxFeeBps` and `maxFeeBps ≤ MAX_FEE_BPS_CAP (= 5000 bps = 50 %)`.  Size the band to the real L1-cost-recovery range. |
| `weiPerBudgetUnitEth` / `weiPerBudgetUnitBold` | wei/unit | IC-6 | Convert deposited fee value into action-budget units.  **Guard:** non-zero (`WeiPerBudgetUnitTooSmall`).  Sets how much execution a fee buys; calibrate against per-action L1 cost. |
| `boldTvlCap` | wei | §5 (per-asset bound) | Per-BOLD TVL sub-cap.  **Guard:** `≤ tvlCap` (`BoldTvlCapExceedsGlobal`).  Bounds single-asset (BOLD) exposure; the circuit breaker + Liquity auto-trigger are the dynamic complements. |
| `ammSeedRatioBps` | bps | §5 | Fraction of each pool-fee deposit routed to AMM liquidity.  **Guard:** `≤ MAX_AMM_SEED_RATIO_BPS`.  `0` disables the AMM (pre-v1.3 behaviour). |
| `boldCircuitBreaker` | address | §5 | Emergency BOLD-pause role.  Cannot move funds / alter roots / change immutables (blast radius minimised).  **Recommendation (audit-21 B.2):** a multisig; immutable single keys are a liveness/griefing risk remediable only by migration. |
| `boldAdmin` | address | §5 | `setBoldTvlCap` role.  Same multisig recommendation; must be distinct from `boldCircuitBreaker`. |
| `ammDisasterRecovery` | address | §5 | The only caller of `emergencyDisableAmm()`.  **Guard:** required non-zero on a *functional* AMM (BOLD-enabled with `ammSeedRatioBps > 0`) — `AmmDisasterRecoveryRequired`; `!= address(this)`.  **Set this to the `KnomosisAmmDisasterRecoveryMultisig` (§6).** |

Wiring/identity fields (`knomosisVersionTag`, `deploymentId`, `attestor`,
`disputeVerifier`, `sequencerStake`, `migration`, `boldTokenAddress`,
`erc20ResourceIds`/`erc20TokenAddrs`, and the `disputeWindowBlocks` /
`maxRedemptionWindowBlocks` / `maxAttestationStaleBlocks` / `cooldownBlocks`
windows) are correctness/topology parameters — set them per the deployment
topology in `docs/testnet_readiness.md` §2, not by economic sizing.  The
`boldTokenAddress` is **chain-conditional** (a Genesis-Plan §13.6 amendment):
on **mainnet** (chainid 1) it must be `address(0)` (BOLD opt-out) or the
canonical `BOLD_TOKEN_ADDRESS` pin — the mainnet authenticity guard is
unconditional; on **any other chain** (a testnet such as Sepolia, or a local
devnet) it may be `address(0)` **or** an operator-supplied chain-native BOLD
token, authenticated by the retained code-presence + `symbol() == "BOLD"`
cross-check (there is no canonical mainnet BOLD to pin off-chain).  The
effective token is exposed by the bridge's `boldToken()` immutable and every
runtime BOLD path resolves through it; the Liquity auto-trigger stays off
off-mainnet (its TroveManager oracles are mainnet-only).  See
`docs/sepolia_deployment_runbook.md` §4.3 for the Sepolia BOLD workflow.

The **L2 chain id** (`8357` production / `83572` test) is *not* a sized or
operator-set parameter: it is derived deterministically from the L1 the bridge
settles to (`KnomosisChainId.l2ChainId(block.chainid)`), emitted in the deploy
manifest (`l2ChainId`), and advertised by the gateway for wallet connection.
It is a chain-conditional identity constant like the `boldTokenAddress` guard,
not an economic knob — see `docs/abi.md` §13.10 and
`docs/sepolia_deployment_runbook.md` §7.4.

## 6. KnomosisAmmDisasterRecoveryMultisig — the AMM kill switch (§5)

`constructor(address bridge, address[] signers, uint256 threshold)`

| Parameter | IC / guard | Guidance |
|-----------|-----------|----------|
| `signers` (N) + `threshold` (M-of-N) | §5 | The `M`-of-`N` quorum that can fire `emergencyDisableAmm`.  **Constructor guard:** `threshold ≥ MIN_DISABLE_THRESHOLD (= 3)`; signers must be distinct, non-zero, and not the bridge/self.  Choose `N` and the signer set so that **collusion of `threshold` signers is costlier than the AMM reserve value** (a single — or `threshold − 1` — compromised key cannot trigger recovery).  A 7-day group-expiry bounds a stale-quorum attack. |

## 7. Off-Solidity parameters

Two IC conditions are governed outside the Solidity constructors:

- **Dispute-pipeline staking (IC-4, IC-5)** — `stakeAmount`,
  `stakeResource`, `escrowActor`, `treasuryActor` live in the Lean
  `StakingPolicy` (`LegalKernel/Disputes/Staking.lean`), set in the genesis
  deployment manifest.  `stakeAmount` is the single most sensitivity-prone
  parameter (it gates *both* spam-resistance and honest access): calibrate
  to the disputed resource's value; `stakeAmount = 0` disables staking.
- **Gas-pool drain + claim budget (IC-6)** — `maxDrainPerAction{Eth,Bold}`
  live in the `gasPoolActor` `LocalPolicy` (genesis manifest; GP.7.2/7.3),
  and the claim frequency is the `gasPoolActor`'s per-epoch budget
  (`--free-tier` / `--epoch-length`, `docs/gas_pool_runbook.md` §8.1).  Size
  so the honest reimbursement clears but the worst-case per-epoch over-claim
  is an acceptable loss; **enable the v2 receipt-verified path (GP.8.5)
  before the pool holds material value.**  v2 covers **both legs**: the ETH
  leg is wei-exact (oracle-free), and the BOLD leg converts the wei cost at
  an attested **ETH→BOLD rate oracle** (`l1EthBoldRateOracle`, GENESIS_PLAN
  §15E.7) — a *second* off-chain trust assumption that a BOLD-receipt-verified
  deployment must provision and cross-check (run ≥1 independent
  `receipt_verifier` observer); a stale/low rate only under-reimburses.

## 8. Operational (non-parameter) prerequisites

- **(IC-3) Watchtower liveness** — run ≥1 **independent**, funded
  `knomosis-faultproof-observer`; alert on `bisectionResponseTimeout`
  headroom.  No constructor value substitutes for this.
- **Key custody** — `gasPoolActor`, `sequencerActor`, the multisig signers,
  and the L1 submitter; see `docs/testnet_readiness.md` §3.5.
- **Trust-binding gates** — run `knomosis hash-check` + `knomosis
  verify-check` (and the `--check` artefact pins,
  `scripts/verify_{secp256k1,keccak}_link.sh`) in the deploy pipeline so a
  fallback hash/verifier can never reach production (security review F-1/F-2).

---

*This guide is the parameter-sizing complement to
`docs/economic_incentive_analysis.md`.  Run
`scripts/economic_simulation.py` to turn its IC conditions into concrete
floors for the values above; record the chosen values in the deployment
manifest before `make testnet-acceptance`.*

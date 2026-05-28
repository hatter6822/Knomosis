<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis Gas-Pool Operator Runbook

This document is the operator-facing companion to
`docs/planning/unified_gas_pool_plan.md` (the Workstream-GP
engineering plan) and the Genesis-Plan §15E amendment.  It covers the
day-to-day operation of the L1 `KnomosisBridge` BOLD safety surface
introduced in **WU GP.5.5: BOLD-specific safety hardening** — the
per-currency circuit breaker, the Liquity-V2 depeg auto-trigger, and
the per-BOLD TVL cap.

The mechanisms here are *deployment-side, L1-only* operational
controls.  They do not touch the Lean kernel, its theorems, or the
fault-proof game; they are the analogue of the four automatic
`circuitOpen` breakers, but BOLD-deposit-scoped and operator-toggled.

---

## 1. Roles

A BOLD-enabled deployment pins two **immutable** roles in the
`KnomosisBridge` constructor.  Both are tightly scoped — neither can
move funds, alter state roots, change any immutable, halt the ETH leg,
or stop withdrawals.

| Role                  | Powers                                                              | Suggested key custody            |
|-----------------------|---------------------------------------------------------------------|----------------------------------|
| `boldCircuitBreaker`  | `closeBoldCircuit()`, `openBoldCircuit()` — pause / resume BOLD deposits | Hot key / on-call keeper (fast)  |
| `boldAdmin`           | `setBoldTvlCap(uint256)` — tune the per-BOLD TVL cap within `[0, tvlCap]` | Cold key / multisig (deliberate) |

The split is deliberate (least privilege): the frequently-used
emergency-pause key cannot change the cap, and the parameter-tuning
key cannot pause.  The permissionless `closeBoldCircuitIfRedeeming
Heavily()` auto-trigger needs no role — anyone may call it — but only
*closes* (never opens) the circuit, and only when the on-chain depeg
signal crosses the threshold.

Both roles are `address public immutable`: they are fixed at
deployment and cannot be rotated.  Choose keys accordingly, and plan a
full redeploy + `KnomosisMigration` handoff if a role key must change.

---

## 2. The safety posture: deposits halted, withdrawals continue

Closing the BOLD circuit halts **only** `depositBoldWithFee`.  It does
**not** stop:

* ETH deposits (`depositETH` / `depositETHWithFee`),
* BOLD or ETH **withdrawals** (`withdrawWithProof`),
* state-root submission, dispute handling, or the fault-proof game.

This is the standard "deposits halted, withdrawals continue" incident
posture used by established bridges (Optimism, Arbitrum).  During a
BOLD depeg or other BOLD-specific incident, you stop accepting *new*
BOLD into the pool while existing reserves remain fully redeemable.

---

## 3. The BOLD circuit breaker

### 3.1 When to close the BOLD circuit

Close the circuit (manually, via `closeBoldCircuit()`, or let the
auto-trigger fire) when any of the following holds:

* **Off-chain price signal.**  A trusted off-chain oracle / price feed
  shows BOLD trading **below $0.95 or above $1.05 for a sustained
  window (> 24 h)**.
* **Liquity-V2 governance change.**  Liquity V2 governance announces a
  parameter change that materially alters BOLD economics (collateral
  set, interest-rate controller, redemption mechanics).
* **Anomalous flow.**  BOLD inflows or outflows exceed **10× the recent
  baseline**, which should also fire an on-call alert.
* **On-chain depeg signal.**  Liquity V2's redemption rate is elevated
  (see §4) — the auto-trigger automates exactly this case.

### 3.2 How to close

* **Manual:** the `boldCircuitBreaker` key calls `closeBoldCircuit()`.
  Emits `BoldCircuitClosed(timestamp)`.  Idempotent (re-closing is a
  harmless no-op).
* **Automated:** any address calls `closeBoldCircuitIfRedeemingHeavily()`
  on a deployment that opted in (`enableLiquityAutoCircuitTrigger ==
  true`).  See §4.

After closing, confirm `boldCircuitClosed() == true` and that a test
`depositBoldWithFee` reverts `BoldDepositPaused`.

### 3.3 How to reopen

Reopen **only** after the incident resolves:

1. Wait for the off-chain price signal to confirm BOLD back **inside
   its peg band for a sustained window (> 12 h)**.
2. If the auto-trigger fired, confirm Liquity V2's redemption rate is
   back below `BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS` (5%).
3. Run a manual sanity check: the bridge's BOLD balance
   (`BOLD.balanceOf(bridge)`) reconciles with `boldTotalLockedValue()`
   and the L2 gas-pool accounting equation (§15E.11).
4. The `boldCircuitBreaker` key calls `openBoldCircuit()`.  Emits
   `BoldCircuitOpened(timestamp)`.

---

## 4. The Liquity-V2 depeg auto-trigger

`closeBoldCircuitIfRedeemingHeavily()` reads Liquity V2's own
redemption-rate accumulator (`ILiquityV2Redemptions.getRedemptionRate()`
on the immutable `liquityV2BorrowerOps` oracle) and closes the BOLD
circuit if the rate is **at or above** the constitutional threshold
`BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS = 500` (5%).

### 4.1 Why Liquity's redemption rate is the canonical depeg signal

Liquity V2's redemption mechanism is BOLD's own peg-defence: when BOLD
trades **below** $1, arbitrageurs redeem BOLD against the
lowest-interest-rate troves for ~$1 of collateral, pocketing the
spread.  Heavy redemption volume therefore *is* the on-chain
manifestation of downward peg pressure — a trust-minimised signal that
needs no external price oracle.  The redemption rate rises with
redemption volume, so a sustained elevated rate is a reliable "BOLD is
under pressure" indicator.

### 4.2 Threshold calibration (500 bps = 5%)

5% is chosen to sit above routine redemption noise (small redemptions
happen continuously without any depeg) but below the level reached
during a genuine sustained de-peg.  It is a **constitutional**
constant: changing it is a Genesis-Plan §13.6 amendment (two-reviewer
rule), pinned in source by `scripts/audit_compile_time_caps.sh` and at
runtime by `BoldCircuitBreaker.t.sol::test_thresholdConstant_pinned`.
A deployment that wants a different sensitivity must redeploy.

### 4.3 Opt-in and failure modes

* The auto-trigger is **opt-in per deployment**
  (`enableLiquityAutoCircuitTrigger`).  Deployments preferring
  operator-only control set it `false`; `closeBoldCircuitIfRedeeming
  Heavily()` then reverts `AutoCircuitTriggerDisabled`.
* It is **idempotent**: if the circuit is already closed it returns
  without touching the oracle.
* If the Liquity oracle reverts, returns a wrong number of bytes
  (e.g. an ABI change in a future Liquity-V2 upgrade), or has no code,
  the call reverts `LiquityV2ReadFailed`.  The bridge reads the oracle
  via low-level `staticcall` with strict `success` + `returndata.length
  == 32` guards, so every fault class routes uniformly to that single
  error (rather than splitting between caught `try`/`catch` and opaque
  reverts).  The staticcall context additionally forbids any state
  mutation by the oracle during the read, so a malicious or buggy
  oracle cannot corrupt bridge state.  **Operator action on
  `LiquityV2ReadFailed`:** treat the auto-trigger as unavailable and
  fall back to the manual `closeBoldCircuit()` path; investigate
  whether the Liquity V2 redemption oracle was redeployed / changed /
  upgraded with an incompatible ABI.

### 4.4 Deployment note

When `enableLiquityAutoCircuitTrigger` is set, the constructor requires
`liquityV2BorrowerOps` to be non-zero and to hold contract code at
deploy time (fails loudly with `ZeroLiquityOracle` /
`LiquityOracleHasNoCode` otherwise).  Pin it to the canonical Liquity
V2 redemption-rate contract (the `CollateralRegistry` /
`BorrowerOperations`-equivalent exposing `getRedemptionRate()`) for the
network you are deploying on, and verify the address against Liquity
V2's published deployment before broadcasting.

---

## 5. The per-BOLD TVL cap

`boldTvlCap` bounds the per-currency BOLD locked value
(`boldTotalLockedValue`, tracked as net BOLD = deposits − withdrawals)
independently of — and no looser than — the global `tvlCap`.

* **Fail-closed default.**  A deployment that leaves `boldTvlCap` at 0
  rejects **every** BOLD deposit (`BoldTvlCapReached`) until the
  `boldAdmin` raises it.  Set a deliberate positive value at deploy
  time (constructor arg) or via `setBoldTvlCap` before opening to
  BOLD users.
* **Tightening only.**  `setBoldTvlCap(newCap)` reverts
  `BoldTvlCapExceedsGlobal` if `newCap > tvlCap`.  The per-BOLD cap can
  only tighten the deployment's overall reserve commitment.
* **Composition.**  Because `boldTvlCap ≤ tvlCap` always holds and
  `boldTotalLockedValue` tracks net BOLD, passing the BOLD cap implies
  passing the global cap.  When ETH reserves are 0 the two coincide.
* **Withdrawals free room.**  A BOLD `withdrawWithProof` decrements
  `boldTotalLockedValue`, so redeemed BOLD frees per-BOLD cap room for
  future deposits.

### 5.1 Using the cap as a graduated response

The cap is a softer lever than the circuit breaker.  During a *mild*
BOLD scare you may prefer to **lower** the cap (slow new BOLD inflow)
rather than fully **close** the circuit (halt it).  Lowering the cap
below the current `boldTotalLockedValue` does not claw back existing
deposits — it simply rejects new ones until withdrawals bring the net
total back under the new cap.

---

## 6. Monitoring checklist

* Alert when `boldTotalLockedValue()` approaches `boldTvlCap()`
  (e.g. > 90%).
* Alert when `boldCircuitClosed()` flips (subscribe to
  `BoldCircuitClosed` / `BoldCircuitOpened` /
  `BoldCircuitClosedByAutoTrigger`).
* Alert when Liquity V2's redemption rate approaches the 5% threshold
  (so a human can pre-empt or confirm an auto-trigger close).
* Periodically reconcile `BOLD.balanceOf(bridge)` against
  `boldTotalLockedValue()` and the L2 accounting equation.
* Alert on any `LiquityV2ReadFailed` from a keeper calling the
  auto-trigger — the oracle may have changed.

---

## 7. Quick reference

| Action                          | Function                                  | Caller               | Event                            |
|---------------------------------|-------------------------------------------|----------------------|----------------------------------|
| Pause BOLD deposits             | `closeBoldCircuit()`                      | `boldCircuitBreaker` | `BoldCircuitClosed`              |
| Resume BOLD deposits            | `openBoldCircuit()`                      | `boldCircuitBreaker` | `BoldCircuitOpened`             |
| Auto-pause on depeg             | `closeBoldCircuitIfRedeemingHeavily()`    | anyone (opt-in)      | `BoldCircuitClosedByAutoTrigger` |
| Adjust per-BOLD TVL cap         | `setBoldTvlCap(uint256)`                  | `boldAdmin`          | `BoldTvlCapUpdated`             |
| Read pause state                | `boldCircuitClosed()`                     | anyone (view)        | —                                |
| Read per-BOLD locked value      | `boldTotalLockedValue()`                  | anyone (view)        | —                                |
| Read per-BOLD cap               | `boldTvlCap()`                            | anyone (view)        | —                                |

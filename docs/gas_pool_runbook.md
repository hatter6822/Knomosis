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
signal fires.

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
* **On-chain depeg signal.**  Any Liquity V2 collateral branch
  (ETH / wstETH / rETH `TroveManager`) reports a non-zero
  `shutdownTime` (see §4) — the auto-trigger automates exactly this
  case.

### 3.2 How to close

* **Manual:** the `boldCircuitBreaker` key calls `closeBoldCircuit()`.
  Emits `BoldCircuitClosed(timestamp)`.  Idempotent (re-closing is a
  harmless no-op).
* **Automated:** any address calls
  `closeBoldCircuitIfAnyLiquityBranchShutdown()` on a deployment that
  opted in (`enableLiquityAutoCircuitTrigger == true`).  See §4.

After closing, confirm `boldCircuitClosed() == true` and that a test
`depositBoldWithFee` reverts `BoldDepositPaused`.

### 3.3 How to reopen

Reopen **only** after the incident resolves:

1. Wait for the off-chain price signal to confirm BOLD back **inside
   its peg band for a sustained window (> 12 h)**.
2. If the auto-trigger fired, confirm Liquity V2 has reactivated the
   shutdown branch (its `shutdownTime` would still read non-zero —
   Liquity-V2 `shutdownTime` is monotonic — but governance / the
   recovery flow restores normal redemption to the remaining
   branches).  In practice "reopen the BOLD circuit" is an explicit
   risk-acceptance decision: BOLD is still backed by whatever
   collateral mix is currently active.
3. Run a manual sanity check: the bridge's BOLD balance
   (`BOLD.balanceOf(bridge)`) reconciles with `boldTotalLockedValue()`
   and the L2 gas-pool accounting equation (§15E.11).
4. The `boldCircuitBreaker` key calls `openBoldCircuit()`.  Emits
   `BoldCircuitOpened(timestamp)`.

---

## 4. The Liquity-V2 branch-shutdown auto-trigger

`closeBoldCircuitIfAnyLiquityBranchShutdown()` reads `shutdownTime()`
from each of the three Liquity V2 collateral-branch `TroveManager`
contracts (interface `ILiquityV2TroveManager`) and closes the BOLD
circuit if **any** branch reports a non-zero `shutdownTime` — the
canonical Liquity-V2 on-chain signal that a collateral branch has been
wound down (oracle failure, governance vote, etc.).  The branches
checked, in order:

| Branch | `TroveManager` address                       |
|--------|----------------------------------------------|
| ETH    | `0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A` |
| wstETH | `0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22` |
| rETH   | `0xb2B2ABEb5C357a234363FF5D180912D319e3e19e` |

These three addresses are **constitutional pins** —
`address public constant LIQUITY_V2_TROVE_MANAGER_*` in the bridge —
each protected by the GP.5.2 source-level `audit_compile_time_caps.sh`
gate AND a runtime `test_troveManagerConstants_pinned`.  Changing any
of them is a Genesis-Plan §13.6 amendment.

### 4.1 Why branch shutdown is the canonical depeg signal

Liquity V2's `shutdownTime` is set on a `TroveManager` the moment its
collateral branch is wound down — by governance, by an oracle-failure
trigger, or by a circuit-breaker condition internal to Liquity.  Once
non-zero, it is **monotonic** (never resets to zero).  A shutdown
branch means BOLD's backing on that collateral type is no longer
actively managed: BOLD continues to redeem against the remaining
healthy branches, but the collateral mix has materially changed.
That is the moment Knomosis should halt **new** BOLD deposits — the
existing reserves stay redeemable, but the bridge stops accepting
fresh BOLD into the pool while the situation resolves.

This signal is strictly stronger than a price-feed depeg threshold:
it requires no external oracle, it is a Liquity-internal protocol
event (not market noise), and it is binary (zero / non-zero) rather
than continuous.

### 4.2 Opt-in and failure modes

* The auto-trigger is **opt-in per deployment**
  (`enableLiquityAutoCircuitTrigger`).  Deployments preferring
  operator-only control set it `false`;
  `closeBoldCircuitIfAnyLiquityBranchShutdown()` then reverts
  `AutoCircuitTriggerDisabled`.  Deployments on non-Liquity chains
  MUST leave it `false` (the constructor's code-presence check on the
  three TroveManager pins enforces this — `LiquityOracleHasNoCode`
  fires at deploy time if Liquity V2 is not deployed at the pins on
  the target chain).
* It is **idempotent**: if the circuit is already closed it returns
  without touching any TroveManager.  Safe to call repeatedly.
* Per-call gas is **bounded**.  Each TroveManager read is
  `staticcall`'d with a hard 100 000-gas cap
  (`LIQUITY_ORACLE_READ_GAS`).  A normal public-storage getter for
  `shutdownTime` costs ~3-5k gas; the cap exists purely to bound a
  malicious-Liquity-upgrade griefing surface (without it, an
  adversarial TroveManager that consumes all forwarded gas could
  burn a keeper bot's whole 30M-gas transaction).
* On the **close** path, the read short-circuits on the first
  non-zero `shutdownTime` (one staticcall when ETH is shutdown; two
  when ETH is healthy but wstETH is shutdown; etc.).  The event
  records which branch fired and that branch's `shutdownTime`.
* On the **no-shutdown** path, all three branches are read; the call
  reverts `NoLiquityBranchShutdown`.
* If a TroveManager reverts, returns the wrong number of bytes (e.g.
  a future Liquity-V2 ABI change), runs out of code (e.g. a
  self-destruct under a pre-Cancun fork), exceeds the 100k gas cap,
  or attempts a state mutation inside the staticcall context, the
  call reverts `LiquityV2ReadFailed`.  The bridge reads each
  TroveManager via low-level `staticcall` with strict `success` +
  `returndata.length == 32` guards, so every fault class routes
  uniformly to that single error (rather than splitting between
  caught `try`/`catch` and opaque reverts).  The staticcall context
  additionally forbids any state mutation by the callee, so a
  malicious or buggy TroveManager cannot corrupt bridge state.
  **Operator action on `LiquityV2ReadFailed`:** treat the auto-trigger
  as unavailable and fall back to the manual `closeBoldCircuit()`
  path; investigate whether Liquity V2 was redeployed / changed /
  upgraded with an incompatible ABI.

### 4.3 Deployment note

When `enableLiquityAutoCircuitTrigger` is set, the constructor
requires **all three** `LIQUITY_V2_TROVE_MANAGER_*` pinned addresses
to hold contract code at deploy time (fails loudly with
`LiquityOracleHasNoCode` otherwise).  This works because the address
pins are mainnet-specific: a deployment on any chain WHERE Liquity V2
has deployed those exact addresses will pass; any other chain will
fail closed.  On non-Liquity chains, set
`enableLiquityAutoCircuitTrigger = false` and drive the circuit
manually via `closeBoldCircuit()`.

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
* Alert when any Liquity V2 collateral branch (`TroveManager`) reports
  a non-zero `shutdownTime` (so a keeper bot can call the auto-trigger
  immediately, and operators can pre-empt or confirm the close).
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
| Auto-pause on depeg             | `closeBoldCircuitIfAnyLiquityBranchShutdown()` | anyone (opt-in) | `BoldCircuitClosedByAutoTrigger` |
| Adjust per-BOLD TVL cap         | `setBoldTvlCap(uint256)`                  | `boldAdmin`          | `BoldTvlCapUpdated`             |
| Read pause state                | `boldCircuitClosed()`                     | anyone (view)        | —                                |
| Read per-BOLD locked value      | `boldTotalLockedValue()`                  | anyone (view)        | —                                |
| Read per-BOLD cap               | `boldTvlCap()`                            | anyone (view)        | —                                |

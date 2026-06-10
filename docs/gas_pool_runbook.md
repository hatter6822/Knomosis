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
the per-BOLD TVL cap — plus the optional `knomosis-host` fair
scheduler (§8) and the L1 gas economics of the v1.3 operations
(§9, **WU GP.11.9**).

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

---

## 8. Fair sequencing (`knomosis-host`; optional, FQ Rung 0)

The `knomosis-host` admission front-end can run an optional per-actor
**fair scheduler** that bounds, under contention for the single serial
worker, the share any one connection can take of it — so a short-burst
flood delays only itself while honest connections keep their share and
their enqueue capacity, and a productive burst on an idle host is
throttled by nothing.  It is **default-OFF**; FIFO remains the baseline.

**Enabling it.**

```text
knomosis-host --listen 0.0.0.0:7654 --knomosis-binary … --knomosis-log … \
  --scheduler drr \
  --per-flow-cap 64 \      # max queued requests per connection (default 64)
  --max-flows 4096         # max distinct active connections (default 4096)
```

`--max-queue-depth <N>` (default 256) doubles as the DRR *global* cap
(total buffered requests).  The cap flags are ignored under
`--scheduler fifo`, but a nonsensical value (`--per-flow-cap 0`,
`--max-flows 0`) is rejected at startup regardless; under `--scheduler
drr` the host additionally requires `--per-flow-cap ≤ --max-queue-depth`.

**Observability.**  The fair worker logs an aggregate summary line
(`"fair scheduler summary"`) at shutdown and, while running, at most
once per 30 s when there has been activity — never per request.  Fields:
`dispatched`, `active_flows`, `queued`, and the per-reason rejection
counters (`rejected_per_flow` / `rejected_max_flows` / `rejected_global`).
A rising `rejected_per_flow` indicates a single connection over-submitting
(it is back-pressured to its own share); a rising `rejected_global`
indicates the host is saturated overall.

**Safety + scope.**

  * **No wire change** and **no admissibility change.**  Rung 0 is
    host-internal (`PROTOCOL_VERSION` stays `1`); the connection id is a
    fairness routing hint that affects *order and `Busy`-drop only*,
    never which actions the kernel admits.  Clients need no changes.
  * **When it bites.**  Fairness is keyed by connection, so it helps when
    distinct actors arrive on distinct connections and a connection
    carries multiple in-flight requests.  In a deployment where each
    request opens its own one-shot connection, every connection is a
    single-request flow and DRR coincides with FIFO; the mechanism still
    ships ready, and the Rung-1 signer-hint extension (future work)
    sharpens fairness for the single-upstream-connection topology.
  * **Reversible.**  Switch back with `--scheduler fifo` (or drop the
    flag) — the FIFO path is byte-for-byte unchanged.

See `docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md` §2 (design) and
§2.6 (the trust/safety invariants) for the full treatment.

---

## 9. Gas economics (v1.3 L1 operations; WU GP.11.9)

Every new v1.3 L1 operation has a committed, CI-gated gas baseline so
deployments can budget L1 costs, UIs can quote bridging fees, and
review can spot performance regressions mechanically.

### 9.1 Where the numbers come from

The deterministic forge suite
`solidity/test/BenchmarkGasV1_3.t.sol` measures each operation as a
pure call from a staged, steady-state scenario (pool pre-warmed, AMM
seeded to a realistic 15 ETH : 45 000 BOLD depth, fee 100 bps, the
production-recommended `ammSeedRatioBps = 3000`).  The baseline file
is `solidity/test/BenchmarkGasV1_3.gas-snapshot`:

```bash
cd solidity
make snapshot-gas         # regenerate the committed baseline
make snapshot-gas-check   # the CI gate: fails on any deviation > 5%
```

The CI gate runs on every PR touching `solidity/**`
(`.github/workflows/ci-solidity.yml`).  A *deliberate* gas change must
regenerate the baseline AND update the table below in the same PR; an
improvement beyond 5% must likewise be ratcheted into the baseline
(the gate is two-sided, which keeps the committed numbers honest).
Baselines are stable only for the pinned toolchain (Foundry v1.7.0,
solc 0.8.20, the committed `foundry.toml`) — regenerate with exactly
that toolchain.

**Reading a baseline.**  A snapshot entry is the gas consumed
executing the benchmark's call from the test harness.  An end-user
transaction additionally pays the 21 000 intrinsic transaction cost
plus calldata gas (a few hundred for these small calldata shapes),
and does *not* pay the harness's internal-call accounting (cold
account access + value-transfer surcharge, roughly 3–10k depending on
the operation).  The estimate

```text
user-tx gas ≈ baseline + 21 000        (slightly conservative)
usd         ≈ user-tx gas × gas-price-gwei × eth-usd × 10⁻⁹
```

therefore over-approximates the on-chain total by a few thousand gas —
the right direction for UX budgeting.  Worked example: a first-time
`depositETHWithFee` is 62 401 + 21 000 ≈ 83 000 gas; at a 30 gwei gas
price and $3 000/ETH that is 83 000 × 30 × 3 000 × 10⁻⁹ ≈ **$7.5** of
L1 gas, which the user absorbs in their bridging UX.

### 9.2 Baseline table (toolchain-pinned, 2026-06-10)

| Operation (scenario)                                   | Baseline (gas) | Est. user tx | $ @ 30 gwei, $3k/ETH |
|--------------------------------------------------------|---------------:|-------------:|---------------------:|
| `depositETH` (v1.0 reference, first deposit)           |         53 876 |        ~75k  |                ~$6.7 |
| `depositETHWithFee` (first deposit)                    |         62 401 |        ~83k  |                ~$7.5 |
| `depositETHWithFee` (repeat deposit)                   |         45 015 |        ~66k  |                ~$5.9 |
| `depositBoldWithFee` (first deposit)                   |         83 261 |       ~104k  |                ~$9.4 |
| `depositBoldWithFee` (repeat deposit)                  |         66 051 |        ~87k  |                ~$7.8 |
| `ammSwap` ETH→BOLD (first-ever BOLD recipient)         |         71 491 |        ~92k  |                ~$8.3 |
| `ammSwap` ETH→BOLD (repeat recipient)                  |         54 303 |        ~75k  |                ~$6.8 |
| `ammSwap` BOLD→ETH (exact approval)                    |         56 876 |        ~78k  |                ~$7.0 |
| `closeBoldCircuit`                                     |         31 904 |        ~53k  |                ~$4.8 |
| `openBoldCircuit`                                      |         10 108 |        ~31k  |                ~$2.8 |
| `setBoldTvlCap`                                        |         15 253 |        ~36k  |                ~$3.3 |
| `emergencyDisableAmm`                                  |         36 790 |        ~58k  |                ~$5.2 |
| Auto-trigger close (first branch, ETH, in shutdown)    |         37 999 |        ~59k  |                ~$5.3 |
| Auto-trigger close (last branch, rETH, in shutdown)    |         53 400 |        ~74k  |                ~$6.7 |
| Auto-trigger probe (no shutdown — reverts)             |         34 444 |        ~55k  |                ~$5.0 |

Cost-structure observations (deltas between rows, useful when judging
a future regression):

* **Fee-split machinery overhead ≈ 8.5k gas.**  `depositETHWithFee`
  (first) minus the plain `depositETH` reference = 62 401 − 53 876 =
  8 525: the fee arithmetic, budget-grant conversion, AMM seeding, and
  the richer event + receipt hash, all-in.
* **BOLD-leg premium ≈ 21k gas.**  `depositBoldWithFee` minus
  `depositETHWithFee` (same shape) ≈ 20.9k: the `transferFrom` pull,
  the two `balanceOf` delta reads, the allowance write, and the
  per-BOLD TVL accounting.
* **First-interaction premium ≈ 17.2k gas.**  A depositor's first
  deposit writes a fresh `depositNonce` slot, and a swapper's
  first-ever BOLD credits a fresh ERC-20 balance slot (both are the
  EVM's zero→non-zero SSTORE surcharge).  Quote first-time users the
  "first" rows.
* **Swap directions are near-symmetric.**  BOLD→ETH costs only ~2.6k
  more than a repeat ETH→BOLD (the `transferFrom` pull + allowance
  write + ETH send, mostly offset by not paying a BOLD transfer out).
* **BOLD prerequisites.**  `depositBoldWithFee` and BOLD→ETH `ammSwap`
  flows assume a prior ERC-20 `approve` — a separate ~46k-gas
  transaction (~$4.2 at the reference prices) not included in the
  rows above.

### 9.3 Caveats and calibration notes

* **Mock fidelity.**  The benchmarks run against `MockBold` (a plain
  ERC-20) and `MockLiquityV2TroveManager` (a plain storage getter).
  Real BOLD is a standard OpenZeppelin-style ERC-20 and the real
  Liquity V2 `shutdownTime()` is a public storage read, so costs are
  comparable; one known divergence is that real BOLD skips the
  allowance write for *infinite* approvals, saving a few thousand gas
  per `transferFrom` relative to the exact-approval shape benchmarked
  here.
* **Keeper probe cost.**  The "no shutdown" row is the auto-trigger
  keeper bot's recurring probe (all three TroveManager reads, then
  `NoLiquityBranchShutdown`); its snapshot value includes a small
  test-harness overhead for the expected revert.  Budget keeper bots
  off this row, not the close rows.
* **UI guidance.**  Wallets / bridge UIs should compute the estimate
  at the *current* gas price using the formula in §9.1 and display it
  before the user signs — at 100 gwei the typical fee-split deposit is
  ~$25, not ~$7.5, and surprising users with that is avoidable.
* **Plan-sketch reconciliation.**  The GP.11.9 plan sketch quoted
  end-user envelopes (e.g. deposits "~80–120k").  Measured end-user
  estimates land inside or below every sketched envelope — the sketch
  over-estimated `transferFrom` and TroveManager read costs
  (`depositBoldWithFee` ~104k vs "~140–180k"; the no-shutdown probe
  ~55k vs "up to ~100k").  The committed baselines above are the
  canonical numbers.

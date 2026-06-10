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

Every v1.3 L1 operation — plus the `withdrawWithProof` exit legs that
complete a user's round trip — has a committed, CI-gated gas baseline
so deployments can budget L1 costs, UIs can quote bridging fees, and
review catches performance regressions mechanically.

### 9.1 Where the numbers come from

The deterministic forge suite
`solidity/test/BenchmarkGasV1_3.t.sol` measures each operation as a
single call from a staged, steady-state scenario (pool pre-warmed, AMM
seeded to a realistic 15 ETH : 45 000 BOLD depth, fee 100 bps, the
production-recommended `ammSeedRatioBps = 3000`, BOLD modelled by the
real vendored OpenZeppelin ERC-20 so allowance semantics carry real
costs).  The suite runs under forge's **isolated mode** (`--isolate`,
enforced by the make targets) — foundry's documented-accurate mode for
the `snapshotGas*` cheatcodes, in which every benchmarked call
executes as its own EVM transaction.  Two values are recorded per
benchmark:

* **User-transaction gas** (`vm.snapshotGasLastCall`) — the FULL
  transaction gas the user pays on L1: 21 000 intrinsic + EIP-2028
  calldata + execution, with EIP-3529 refunds netted and the
  transaction target pre-warmed (EIP-2929).  Test-harness overhead is
  excluded by construction.  This is measured, not modelled — the
  isolated-vs-unisolated deltas decode to the gas as
  `21 000 + calldata − refunds` on all 21 benchmarks (e.g.
  `closeBoldCircuit` +21 064 = 21 000 + 64 calldata;
  `depositBoldWithFee` +13 816 = 21 000 + 416 − 2 800
  reentrancy-guard reset − 4 800 allowance-clear refund).
* **Calldata gas** (`<name>.calldata_gas`) — the exact EIP-2028
  intrinsic cost (16/non-zero byte, 4/zero byte) of the canonical
  calldata the benchmark sent, as a breakdown of the total.  This
  matters: a `withdrawWithProof` carries a ~2.7 kB SMT proof costing
  ~37.9k in calldata alone, two orders of magnitude above the
  small-call rows.

The committed baseline is
`solidity/test/BenchmarkGasV1_3.gas-baseline.json`; the table in §9.2
is **generated from it** — measurement and documentation cannot drift
apart:

```bash
cd solidity
make snapshot-gas           # re-measure; promote the baseline; regenerate §9.2
make snapshot-gas-check     # the CI gate (see below)
make snapshot-gas-selftest  # behavioural self-tests for the gate + generator
```

**The CI gate** (`make snapshot-gas-check`, run by
`.github/workflows/ci-solidity.yml` on every PR touching
`solidity/**`) enforces, per the GP.11.9 plan rule:

* any per-benchmark gas **increase beyond 5% fails** (one-sided —
  exactly the plan's ">5 % increase fails CI");
* benchmark-set drift fails (a benchmark added, removed, or renamed
  without `make snapshot-gas` — stale baselines cannot linger);
* a §9.2 table out of sync with the committed baseline fails;
* improvements beyond 5% **warn** without failing: nobody's unrelated
  PR is blocked by somebody else's optimisation, but the nudge to
  ratchet the baseline (and table) keeps the documented numbers
  honest.

Baselines are stable only for the pinned toolchain (Foundry v1.7.0,
solc 0.8.20, the committed `foundry.toml`) — regenerate with exactly
that toolchain.

**Reading a row.**  The user-tx column is the measured transaction
gas; the only arithmetic left to the reader is pricing:

```text
usd ≈ user-tx gas × gas-price-gwei × eth-usd × 10⁻⁹
```

(To recover the execution component:
`execution ≈ user-tx − 21 000 − calldata + refunds`.)  Worked
examples at 30 gwei and $3 000/ETH: a first-time `depositETHWithFee`
is a measured 66 261 gas ≈ **$6.0** of L1 gas, which the user absorbs
in their bridging UX; the `withdrawWithProof` exit leg is a measured
≈ 861 000–878 000 gas ≈ **$77.5–79.0** — the dominant cost of the
round trip (see §9.3).

### 9.2 Baseline table

<!-- BEGIN GP.11.9 GENERATED BASELINE TABLE (regenerate: cd solidity && make snapshot-gas) -->
*This table is generated from the committed baseline `solidity/test/BenchmarkGasV1_3.gas-baseline.json` by `solidity/scripts/generate_gas_runbook_table.py`; edit neither by hand.  The user-tx column is the value MEASURED under forge's isolated mode — the full transaction gas (intrinsic + calldata + execution, refunds netted); $ at 30 gwei and $3 000/ETH.*

| Operation (scenario) | User tx (gas, measured) | of which calldata (gas) | $ @ 30 gwei, $3k/ETH |
|---|---:|---:|---:|
| `depositETH` (v1.0 reference, first deposit) | 57 655 | 64 | ~$5.2 |
| `depositETHWithFee` (first deposit) | 66 261 | 204 | ~$6.0 |
| `depositETHWithFee` (repeat deposit) | 49 161 | 204 | ~$4.4 |
| `depositETHWithFee` (repeat, migration-wired bridge) | 52 268 | 204 | ~$4.7 |
| `depositBoldWithFee` (first deposit) | 94 242 | 416 | ~$8.5 |
| `depositBoldWithFee` (repeat deposit) | 77 142 | 416 | ~$6.9 |
| BOLD `approve` (prerequisite, fresh allowance) | 45 992 | 644 | ~$4.1 |
| `ammSwap` ETH→BOLD (first-ever BOLD recipient) | 75 726 | 684 | ~$6.8 |
| `ammSwap` ETH→BOLD (repeat recipient) | 58 626 | 684 | ~$5.3 |
| `ammSwap` ETH→BOLD (repeat, migration-wired bridge) | 61 736 | 684 | ~$5.6 |
| `ammSwap` BOLD→ETH (exact approval) | 68 204 | 708 | ~$6.1 |
| `ammSwap` BOLD→ETH (infinite approval) | 69 870 | 708 | ~$6.3 |
| `withdrawWithProof` ETH (canonical 64-sibling proof) | 861 392 | 37 844 | ~$77.5 |
| `withdrawWithProof` BOLD (canonical 64-sibling proof) | 877 759 | 37 868 | ~$79.0 |
| `closeBoldCircuit` | 44 825 | 64 | ~$4.0 |
| `openBoldCircuit` | 22 985 | 64 | ~$2.1 |
| `setBoldTvlCap` | 28 090 | 276 | ~$2.5 |
| `emergencyDisableAmm` | 49 623 | 64 | ~$4.5 |
| Auto-trigger close (first branch, ETH, in shutdown) | 53 834 | 64 | ~$4.8 |
| Auto-trigger close (last branch, rETH, in shutdown) | 69 037 | 64 | ~$6.2 |
| Auto-trigger probe (no shutdown — reverts) | 47 250 | 64 | ~$4.3 |
<!-- END GP.11.9 GENERATED BASELINE TABLE -->

### 9.3 Cost-structure observations

Deltas between rows (useful when judging a future regression; all from
the committed baseline, which is why adjacent variant rows exist):

* **First-interaction premium = 17 100 gas exactly.**  A depositor's
  first deposit writes a fresh `depositNonce` slot, and a swapper's
  first-ever BOLD credits a fresh ERC-20 balance slot; both pairs of
  rows differ by precisely the EVM's zero→non-zero SSTORE surcharge
  (22 100 − 5 000).  Quote first-time users the "first" rows.
* **Fee-split machinery overhead ≈ 8.6k gas.**  `depositETHWithFee`
  (first) minus the plain `depositETH` reference: the fee arithmetic,
  budget-grant conversion, AMM seeding, the richer event + receipt
  hash, and the slightly larger calldata, all-in.
* **BOLD-leg premium ≈ 28k gas.**  `depositBoldWithFee` minus
  `depositETHWithFee` (same shape): the `transferFrom` pull, the two
  `balanceOf` delta reads, the allowance write (its clear-to-zero
  refund already netted), and the per-BOLD TVL accounting.
* **Migration-wired premium ≈ 3.1k gas per operation.**  Production
  deployments that pre-wire a predicted `KnomosisMigration` successor
  (solidity/README, "Production deployment notes") pay one external
  `activated()` read in every `circuitOpen` operation and every
  `ammSwap` — measured by the two "migration-wired" rows (+3 107 on
  the deposit, +3 110 on the swap).  Initial deployments with
  `migration = address(0)` skip it.
* **Exact vs infinite approval: refunds invert the per-swap story.**
  Per transaction, the exact-approval BOLD→ETH swap (68 204) is
  ~1.7k CHEAPER than the infinite-approval one (69 870): clearing the
  allowance to zero earns a 4 800 EIP-3529 refund that outweighs the
  ~3.1k execution the infinite shape saves by skipping the allowance
  write.  Per FLOW the ranking flips back: the exact shape needs a
  fresh ~46k `approve` before every swap (~114k per swap all-in),
  while the infinite shape pays its ~46k approve once — so infinite
  approval wins from the second swap onward.  The same trade applies
  to `depositBoldWithFee`.
* **The exit leg dominates the round trip.**  `withdrawWithProof`
  costs a measured ~861–878k per transaction (~13× a repeat deposit),
  of which ~37.9k is the ~2.7 kB, 64-sibling proof calldata and the
  bulk of the execution is the byte-loop CBE decode of that blob (the
  64-keccak SMT walk itself is a few thousand gas).  Verification gas
  is essentially independent of tree population
  (`SmtVerifier.recomputeRoot` always walks all 64 levels over
  same-sized siblings).  Operators quoting "bridging cost" should
  quote deposit + withdrawal; a future calldata-slice decoder is the
  obvious optimisation target if exit costs ever matter commercially.
* **Keeper-probe budgeting.**  The no-shutdown probe row (a measured
  47 250 per probe ≈ $4.3 at the reference prices) is measured through
  a plain low-level call — no test cheatcode interferes with the
  revert — so it is the keeper bot's true recurring cost.

### 9.4 Caveats and calibration notes

* **Mock fidelity.**  BOLD is modelled by `MockBoldOz` — the real
  vendored OpenZeppelin v5 `ERC20` implementation (production BOLD's
  base), so storage-op behaviour including the infinite-approval skip
  is exact, and the benchmark's companion sanity test proves the skip.
  The Liquity TroveManagers are mocks whose `shutdownTime()` is a
  plain storage getter, like the real contracts'.  Residual divergence
  from production bytecode (larger dispatch tables, BOLD's recipient
  checks) is on the order of a few hundred gas per call, not
  thousands.
* **Refunds are netted.**  Under isolated mode each benchmark is its
  own transaction, so EIP-3529 refunds (allowance clears, the
  reentrancy-guard reset, `openBoldCircuit`'s flag clear) are already
  reflected in the measured numbers — there is no refund correction
  left for the reader to apply.  (The 1/5-of-used-gas refund cap is
  never binding for these shapes.)
* **UI guidance.**  Wallets / bridge UIs should compute the estimate
  at the *current* gas price using the §9.1 formula and display it
  before the user signs — at 100 gwei the typical first fee-split
  deposit is ~$20, the exit leg ~$258, not the reference-price
  figures.
* **Plan-sketch reconciliation.**  The GP.11.9 plan sketch quoted
  rough envelopes estimated before measurement.  The isolated-mode
  baselines here are the canonical numbers and land at or below every
  sketched envelope (e.g. deposits "~80–120k" vs a measured 66 261
  first fee-split deposit; the no-shutdown probe "up to ~100k" vs a
  measured 47 250).

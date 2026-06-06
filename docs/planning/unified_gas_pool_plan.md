<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Unified Gas Pool, Per-Actor Budgets, and DoS Resistance — Workstream Plan (Workstream GP)

**Document version:** v1.5 (revised from v1.4; deeper audit-pass
correcting bugs that v1.4's audit pass missed).  Critical bugs
fixed: gasPoolPolicy deny-list missed v1.3 action indices 21 and
22; bridge accounting equation didn't cover AMM swap flows;
bridgePolicy extension for new bridgeActor-signable actions was
implicit; `ammActive` modifier missing from `ammSwap` function
signature; `ammDisabled` interaction with deposit-time AMM
seeding undefined; `Action.toTransition` signer-threading not
specified.  See Appendix C's Optimisation Round 8 + Refinement
Pass 6 for the full audit-finding ledger.

**Document version:** v1.4 (superseded by v1.5; kept here for
amendment history):

The v1.4 revision is a refactoring pass, not a new mechanism
introduction.  The headline mechanism set is unchanged from v1.3
(embedded ETH↔BOLD AMM, pre-authorised delegated budget top-ups,
Liquity V2 redemption-trigger circuit breaker, multi-resource
gas pool with ETH + BOLD).  The v1.4 changes are:

* **Security fix (HIGH PRIORITY)**: `Action.topUpActionBudgetFor`
  is now default-deny rather than default-allow.  If the
  recipient has no `allowTopUpFrom` clause, admission rejects.
  This closes an identity-tagging / state-bloat / policy-bypass
  attack surface that v1.3 left open.
* **Security fix**: L1 `receiptHash` is now specified to include
  every emitted field (including the v1.3-added `ammSeedAmount`).
  v1.3 left this as `...` placeholder; v1.4 makes the spec
  explicit so an L2 ingestor that doesn't verify the hash
  correctly can't be tricked by an event with modified fields.
* **Security fix**: Liquity V2 read in
  `closeBoldCircuitIfRedeemingHeavily` is now wrapped in try /
  catch.  If Liquity V2's interface changes (e.g., via a future
  re-deployment), the auto-trigger reverts with
  `LiquityV2ReadFailed` rather than propagating an opaque
  underlying error.  Operator can then switch to manual mode
  cleanly.
* **Structural improvement**: the most complex WUs (GP.3.2,
  GP.5.1, GP.5.4, GP.5.5, GP.11.3, GP.11.4) are subdivided into
  granular sub-WUs (typically a, b, c, ... lettered suffixes).
  Each sub-WU is now 2-6 hours of work rather than 14-24 hours,
  making them tractable for individual contributors and
  amenable to parallel work on independent files.
* **Coverage gaps closed**: 5 new WUs cover state-root
  commitment integration with the AMM state, AMM disaster
  recovery, gas-cost benchmarks, operator runbook v1.3
  update, and TCB allowlist + Lake config updates.  These
  were implicit in v1.3 but unspecified.
* **Quick Reference tables**: a new section near the top lists
  all reserved `ActorId`s, all frozen Action constructor
  indices, all immutable constructor parameters, and all
  compile-time constants.  Eliminates the need to grep the
  document for these canonical values.
* **Best-practices audit**: every WU now explicitly lists
  testing coverage (positive cases, negative cases, edge
  cases, fuzz inputs), acceptance criteria with reviewer
  count, and effort estimate.  Cross-references between WUs
  are validated; the dependency graph in Appendix A is updated
  to reflect the new sub-WU breakdown.

No new mechanisms, no new theorems (the structural improvements
preserve the theorem catalogue at ~81 theorems).  Trust
assumptions unchanged from v1.3.

---

**Document version:** v1.3 (superseded by v1.4 — kept here for
amendment history):

The v1.3 revision incorporates three substantive design changes
that emerged from open-question resolution:

1. **Embedded constant-product AMM** (`Workstream BA`, previously
   deferred): the bridge gains an internal ETH↔BOLD swap function
   so the pool's USD-denominated gas pricing remains coherent
   under ETH/USD price drift.  The AMM uses Uniswap v2-style
   x*y=k math with a 0.30 % swap fee; permissionless swapping;
   the gas pool itself is the sole LP (no LP tokens, no external
   LPs).  Swap-fee revenue accrues to the gas pool exactly as
   bridge-skim does, providing a second income stream that
   compounds the pool's solvency margin.
2. **Pre-authorised delegated budget top-ups**: a new
   `LocalPolicyClause` (`allowTopUpFrom : List ActorId`) lets an
   actor whitelist specific delegate actors who may credit their
   budget via a new `Action.topUpActionBudgetFor`.  Enables
   service-provider funding flows while preserving the principle
   that budgets are mutated only with the actor's prior consent
   (declared via a signed `declareLocalPolicy`).
3. **Liquity V2 redemption-trigger as the BOLD depeg signal**:
   the BOLD circuit breaker (GP.5.5) is re-architected to read
   Liquity V2's own redemption-rate as the canonical depeg
   indicator.  When Liquity's redemption volume exceeds a
   threshold for sustained N blocks, the operator (or an
   automated keeper) triggers `closeBoldCircuit()`.  This avoids
   external oracle trust by using Liquity's internal
   price-discovery mechanism — when BOLD trades below peg,
   arbitrageurs redeem against the lowest-interest-rate troves,
   producing a measurable on-chain signal.

The embedded AMM is the largest single addition in v1.3 (~1000
lines of new content in Phase GP.11).  It's gated by careful
mathematical soundness analysis — the constant-product invariant
(k = R_eth × R_bold), the no-drain-to-zero property, slippage
protection, and reserve-consistency with the L2 gas-pool balance
all have theorem-level treatment.  Trust assumptions widen by one
(the AMM is a new attack surface) but the alternative external-
DEX path was already an unstated trust assumption on Uniswap v3;
the embedded version makes the trust surface explicit and
auditable as part of Knomosis's own codebase.

The v1.2 BOLD-specific safety hardening (GP.5.5) carries forward
unchanged in scope, with the depeg-detection mechanism upgraded
from "off-chain oracle + manual operator decision" to "Liquity V2
redemption-rate read + operator decision (or auto-trigger)."

The v1.2 multi-resource architecture (ETH at ResourceId 0, BOLD at
ResourceId 1) carries forward unchanged.  The v1.1 user-chosen-fee
mechanism, per-actor budgets, and lazy free-tier replenishment all
carry forward unchanged.

The v1.2 revision extends v1.1's single-resource gas pool to a
**two-resource** pool: native ETH at `ResourceId 0` (existing)
and **BOLD** (Liquity V2 stablecoin,
`0x6440f144b7e50d6a8439336510312d2f54beb01d` on L1) at
`ResourceId 1` (new).  Users pick the deposit currency at L1
bridge entry; the per-resource pool slots accumulate
independently; the per-actor budget grant is denomination-
agnostic (a single integer counter, denominated in abstract
"action units") with separate per-resource exchange rates
`weiPerBudgetUnitEth` and `weiPerBudgetUnitBold` calibrated so
1 unit ≈ 1 unit of L2 service regardless of payment currency.

This unlocks **stable-USD-denominated gas pricing** for users
who deposit BOLD (which trades near $1) while preserving the
ETH-denominated path for users who want native simplicity.  The
sequencer can claim from whichever pool slot the L1 publishing
cost calls for — typically ETH for `submitStateRoot` calls,
optionally swapped from BOLD via an **external** L1 DEX
(Uniswap v3, Cowswap with MEV protection) when needed.  No
bridge-embedded AMM in v1.2; that is explicitly deferred to a
future workstream (`Workstream BA`) scoped only after TVL and
volume justify the substantial audit cost.

Why BOLD specifically: BOLD is the native stablecoin of Liquity
V2 — decentralised, governance-minimised, backed by liquid
staking tokens (wstETH / rETH / etc) via a redemption mechanism
that maintains a soft $1 peg.  It carries less issuer risk than
USDC / USDT (no centralised mint authority can freeze bridge
funds), less collateral-concentration risk than v1 LUSD (multi-
collateral instead of ETH-only), and a credible track record
inherited from Liquity v1 LUSD.  The trade-off is moderately
lower liquidity than USDC and a wider depeg envelope (typically
$0.97–$1.03) — both acceptable for a gas-pool denomination
where the pool's USD value just needs to be stable, not
arbitrage-precise.

The v1.1 user-chosen-fee mechanism is preserved verbatim and
extends naturally: a user depositing BOLD picks `chosenFeeBps`
within `[minFeeBps, maxFeeBps]` just like an ETH depositor.

Naming note: `weiPerBudgetUnit` (how many wei of fee buys one
budget unit) is preferred over `budgetPerWei` (how many budget
units per wei) because the realistic operator range for the
former is in `[10⁹, 10¹⁵]` — comfortably fitting `uint64` — while
the latter would force fractional units.  `budgetGrant` is
computed by **floor division** (`poolAmount / weiPerBudgetUnit`)
which is well-defined for all `weiPerBudgetUnit ≥ 1` and produces
deterministic byte-equivalent results on both the L1 Solidity
side (Solidity's `/` is checked floor division on uint256) and
the L2 Lean side (Lean `Nat` division is floor by definition).
For BOLD, the same primitive operates over BOLD-token-wei
quantities (BOLD is 18-decimal) with a separately-calibrated
exchange rate.

Mathematically, v1.1 widens the fee parameter from a constructor
constant to an action-payload field bounded above and below by
two immutable constants; widens `DepositRecord` to carry the
budget grant; widens the admission pipeline to apply the budget
grant atomically with the deposit's balance credits; and adds two
new theorems (`depositWithFee_grants_budget` and
`depositWithFee_budget_locality`).  v1.2 then extends the
existing resource-parametric `Laws/DepositWithFee.lean` to cover
`ResourceId 1` (BOLD) via parameter substitution, generalises
the bridge accounting equation to per-resource projections,
extends `gasPoolPolicy` with parallel clauses for `ResourceId 1`,
and adds three new theorems
(`per_resource_pool_independence`, `gasPoolPolicy_bold_clauses`,
`bridge_accounting_per_resource`).  No new opaques, no kernel
TCB delta, no new axioms.  The §13.6 two-reviewer rule continues
to apply only to `Authority/SignedAction.lean` edits in GP.3.2
plus the new BOLD-specific Solidity amendments in GP.5.4 / GP.5.5.

This document plans the engineering effort to land a unified mechanism
that ties three currently-distinct concerns together by construction:

1. **User-chosen bridge fee with multi-currency support
   (v1.2)** — L1 → L2 deposits in **either** native ETH **or**
   BOLD; the user picks both the currency and the fee
   percentage within deployment-bounded ranges.  The split
   credits the recipient with the user-portion at the
   corresponding `ResourceId` (0 for ETH, 1 for BOLD) and
   credits the gas-pool actor with the fee-portion at the same
   `ResourceId`.  The recipient also receives an action-budget
   grant equal to `min(MAX_BUDGET_PER_DEPOSIT, poolAmount /
   weiPerBudgetUnit[ResourceId])`, allowing super-users to
   prepay for large action budgets in one bridge transaction
   regardless of which currency they brought.
2. **Multi-resource gas pool (v1.2)** — accumulates user-chosen
   fee revenue and post-deposit top-up payments at **both**
   `(gasPoolActor, ResourceId 0)` (ETH) and
   `(gasPoolActor, ResourceId 1)` (BOLD); the only kernel-
   permitted outflow path from either slot is sequencer
   L1-gas-reimbursement, gated by an actor-scoped `LocalPolicy`
   that enforces per-resource caps and per-resource recipient
   restrictions independently.
3. **Per-actor action budgets** — every admitted `SignedAction`
   consumes 1 unit of the signer's per-epoch budget; exhausted
   budget makes admission reject pre-`step_impl`.  Budgets are
   denomination-agnostic (a single integer counter regardless of
   which currency funded the grant), replenished by three
   mechanisms: lazy free-tier reset at epoch boundary,
   bridge-deposit budget grant (from either currency; the v1.1
   mechanism, generalised in v1.2), and on-L2 top-ups via
   `topUpActionBudget`.

The three mechanisms compose into a single closed-form economic loop:

```
   L1 ETH deposit V wei              L1 BOLD deposit V BOLD-wei
   (msg.value = V;                   (BOLD.transferFrom; user
    user picks chosenFeeBps)          picks chosenFeeBps)
       │                                  │
       │ bounds-check                     │ bounds-check
       │   [minFeeBps, maxFeeBps]         │   [minFeeBps, maxFeeBps]
       │                                  │
   ┌───┴───┐                          ┌───┴───┐
   │ split │ (× weiPerBudgetUnitEth)  │ split │ (× weiPerBudgetUnitBold)
   └───┬───┘                          └───┬───┘
       │                                  │
   poolAmount = V × chosenFeeBps / 10000  (same formula, same denom)
   userAmount = V − poolAmount
   budgetGrant = min(MAX_BUDGET_PER_DEPOSIT,
                     poolAmount / weiPerBudgetUnit[ResourceId])
       │                                  │
       │ ResourceId 0                     │ ResourceId 1
       ▼                                  ▼
 ┌─────────────┐                    ┌─────────────┐
 │ recipient   │                    │ recipient   │
 │   ETH slot  │                    │   BOLD slot │
 │   += uA     │                    │   += uA     │
 ├─────────────┤                    ├─────────────┤
 │ gasPoolActor│                    │ gasPoolActor│
 │   ETH slot  │                    │   BOLD slot │
 │   += pA     │                    │   += pA     │
 └──────┬──────┘                    └──────┬──────┘
        │                                  │
        └──────────────┬───────────────────┘
                       │ (recipient's L2 budget counter
                       │  += budgetGrant, denomination-
                       │  agnostic — single integer)
                       ▼
            recipient spends budget (1 unit/action)
                       │
                       ▼
       topUpActionBudget (post-deposit refill on L2:
                          user → pool, in whichever resource
                          they have balance in)
                       │
                       ▼
              sequencer L1-gas claim
                ↓
   Sequencer chooses which pool to claim from:
   - ETH pool: direct ETH → sequencer L1 address
   - BOLD pool: BOLD → sequencer L1 address; sequencer
     converts to ETH via external L1 DEX
     (Uniswap v3 / Cowswap with MEV protection)
     before paying L1 gas
   Both paths capped by gasPoolPolicy.capAmount
   (independent per resource);
   signed by sequencerActor;
   evidenced by L1 tx hash.
```

The diagram shows the dual nature of a single L1 bridge transaction:
* The kernel-`State` mutation: two `setBalance` operations
  (recipient credit, pool credit) — both well-trodden patterns
  already covered by the existing `deposit` law's proof machinery.
* The `EpochBudgetState` mutation: one `topUp` operation at the
  recipient's slot — identical in shape to the post-deposit
  `topUpActionBudget` action, but executed atomically with the
  deposit's balance updates at the admission layer.

The "super-user" UX flow has two parallel forms in v1.2:

**Path A (ETH deposit).**  Deposit 1 ETH at `chosenFeeBps =
1000` (10 %); recipient gets 0.9 ETH at L2 + 0.1 ETH of
pool-credit + `0.1 ETH / weiPerBudgetUnitEth` budget units.  At
`weiPerBudgetUnitEth = 10¹²` wei (≈ $0.000003 of ETH per budget
unit at $3000/ETH, a typical operator setting): `10¹⁷ wei /
10¹² wei per unit = 10⁵ units = 100 000 actions`.  At
`weiPerBudgetUnitEth = 10⁹` (cheaper budget): `10⁸` units —
clamped to `MAX_BUDGET_PER_DEPOSIT` if that is set lower.

**Path B (BOLD deposit).**  Deposit 1000 BOLD (≈ $1 000 at peg)
at `chosenFeeBps = 1000` (10 %); recipient gets 900 BOLD at L2 +
100 BOLD of pool-credit + `100 BOLD / weiPerBudgetUnitBold`
budget units.  At `weiPerBudgetUnitBold = 3 × 10¹⁵` BOLD-wei
(≈ $0.003 of BOLD per budget unit; calibrated so 1 budget unit
≈ same USD value as in Path A): `100 × 10¹⁸ BOLD-wei /
3 × 10¹⁵ BOLD-wei per unit ≈ 3.33 × 10⁴ units ≈ 33 000 actions`.

```
weiPerBudgetUnitBold = weiPerBudgetUnitEth × usdPerEth / usdPerBold
```

At ETH ≈ $3 000 / BOLD ≈ $1 and `weiPerBudgetUnitEth = 10¹²`:

```
weiPerBudgetUnitBold = 10¹² × 3000 / 1 = 3 × 10¹⁵
```

**Author's mathematical verification (parity sanity check).**
For an arbitrary fee value `F` USD:

  * ETH path: fee in wei = `F / 3000 × 10¹⁸ = F × 10¹⁵ / 3` wei.
    Budget grant = `(F × 10¹⁵ / 3) / 10¹² = F × 10³ / 3 =
    333.33 × F` units.
  * BOLD path: fee in BOLD-wei = `F × 10¹⁸` BOLD-wei.
    Budget grant = `(F × 10¹⁸) / (3 × 10¹⁵) = F × 10³ / 3 =
    333.33 × F` units.

  Both paths yield ≈ 333 budget units per USD of fee.  ✓ Parity
  confirmed.  Floor-division differences (a few units) are
  benign.

---

## Quick Reference (v1.4)

This section consolidates canonical values that appear throughout
the plan.  Treat as the single source of truth for these constants
and identifiers; any divergence elsewhere in the document is a bug.

### Reserved ActorIds

| ActorId | Name              | Role                                                              | Reserved by |
| ------- | ----------------- | ----------------------------------------------------------------- | ----------- |
| 0       | `bridgeActor`     | Signs L1-event-derived actions (deposits, identity ops)          | Pre-GP      |
| 1       | `gasPoolActor`    | Holds gas-pool reserves at both `ResourceId 0` and `1`           | GP.7.1      |
| 2       | `sequencerActor`  | Authorised recipient for gas-pool drains (L1-gas reimbursement)  | GP.7.1      |
| 3       | `ammReserveActor` | Holds L2 reflection of AMM reserves (v1.3, both resources)        | GP.11.5     |
| ≥ 4     | User actors       | Standard actors registered via `KnomosisIdentityRegistry`            | n/a         |

`AddressBook.empty.nextActorId` advances incrementally as each
reserved slot lands: `1` (pre-GP) → `3` (post-GP.7.1, reserving
`gasPoolActor` = 1 and `sequencerActor` = 2; **current Lean genesis**,
pinned by `addressBook_empty_nextActorId`) → `4` (post-v1.3 GP.11.5,
reserving `ammReserveActor` = 3).  Pre-existing deployments must remap
any user-allocated ActorIds in the reserved range via the migration
helper (GP.10.4).

The `ammReserveActor` row above describes the **post-v1.3 target**: its
`ActorId 3` is reserved only once GP.11.5 lands (see the `Reserved by`
column).  In the **current** post-GP.7.1 build — both the Lean genesis
and the Rust `knomosis-l1-ingest` adaptor — `ActorId 3` is the first
*user* actor a fresh deployment registers; GP.11.5 will advance the
genesis a further step (3 → 4) and re-home that slot to
`ammReserveActor`, at which point pre-GP.11.5 deployments remap via the
same GP.10.4 helper.

### Frozen Action constructor indices

Pre-GP indices 0–18 are unchanged.  GP-era additions:

| Index | Constructor                  | Introduced | Purpose                                              |
| ----- | ---------------------------- | ---------- | ---------------------------------------------------- |
| 19    | `Action.depositWithFee`      | v1.0       | Bridge deposit with fee split + recipient budget grant |
| 20    | `Action.topUpActionBudget`   | v1.0       | L2 user self-topup (signer credits own budget)        |
| 21    | `Action.topUpActionBudgetFor`| v1.3       | L2 delegated topup (signer credits recipient's budget; gated by `allowTopUpFrom`) |
| 22    | `Action.ammSwap`             | v1.3       | L2 mirror of L1 AMM swap (gas-pool reserves reshuffled) |

### Frozen Event indices

Pre-GP indices 0–15 are unchanged.  GP-era additions:

| Index | Event                              | Introduced | Purpose                                  |
| ----- | ---------------------------------- | ---------- | ---------------------------------------- |
| 16    | `Event.depositWithFeeCredited`     | v1.0       | Emitted on admitted depositWithFee       |
| 17    | `Event.actionBudgetTopUp`          | v1.0       | Emitted on admitted topUpActionBudget(For) |
| 18    | `Event.gasPoolClaim`               | v1.0       | Emitted on gas-pool → sequencer transfer |
| 19    | `Event.ammSwapExecuted` (L2)       | v1.3       | Emitted on admitted ammSwap              |
| 20    | `Event.boldCircuitClosed`          | v1.3       | Emitted when BOLD circuit-breaker fires  |
| 21    | `Event.boldCircuitOpened`          | v1.3       | Emitted when BOLD circuit-breaker reopens |

### Immutable L1 constructor parameters

| Parameter                          | Type     | Bounds                                       | Introduced |
| ---------------------------------- | -------- | -------------------------------------------- | ---------- |
| `minFeeBps`                        | `uint16` | `0 ≤ minFeeBps ≤ maxFeeBps`                  | v1.1       |
| `maxFeeBps`                        | `uint16` | `minFeeBps ≤ maxFeeBps ≤ MAX_FEE_BPS_CAP`    | v1.1       |
| `weiPerBudgetUnitEth`              | `uint64` | `≥ MIN_WEI_PER_BUDGET_UNIT = 1`              | v1.1       |
| `weiPerBudgetUnitBold`             | `uint64` | `≥ MIN_WEI_PER_BUDGET_UNIT = 1`              | v1.2       |
| `boldTokenAddress`                 | `address`| Must equal `BOLD_TOKEN_ADDRESS` (pin check)  | v1.2       |
| `ammSeedRatioBps`                  | `uint16` | `0 ≤ ammSeedRatioBps ≤ MAX_AMM_SEED_RATIO_BPS = 8000` | v1.3       |
| `enableLiquityAutoCircuitTrigger`  | `bool`   | Operator choice; affects Path B availability | v1.3       |

### Compile-time constants

| Constant                                | Value                                          | Purpose                                                | Introduced |
| --------------------------------------- | ---------------------------------------------- | ------------------------------------------------------ | ---------- |
| `MAX_FEE_BPS_CAP`                       | `5000` (50 %)                                  | Hard ceiling on `maxFeeBps`                            | v1.1       |
| `MIN_WEI_PER_BUDGET_UNIT`               | `1`                                            | Hard floor on either `weiPerBudgetUnit*`               | v1.1       |
| `MAX_BUDGET_PER_DEPOSIT`                | `10¹²` (1 trillion)                            | Per-deposit budget-grant clamp                         | v1.1       |
| `BOLD_TOKEN_ADDRESS`                    | `0x6440f144b7e50d6a8439336510312d2f54beb01d`   | Canonical Liquity V2 BOLD address                       | v1.2       |
| `EXPECTED_BOLD_SYMBOL`                  | `"BOLD"`                                       | Constructor cross-check                                | v1.2       |
| `MAX_AMM_SEED_RATIO_BPS`                | `8000` (80 %)                                  | Hard ceiling on `ammSeedRatioBps`                      | v1.3       |
| `AMM_SWAP_FEE_BPS`                      | `30` (0.30 %)                                  | AMM swap fee (per OQ-GP-15)                            | v1.3       |
| `LIQUITY_V2_TROVE_MANAGER_ETH`          | `0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A`   | Liquity V2 ETH-branch TroveManager (shutdownTime read) | v1.5       |
| `LIQUITY_V2_TROVE_MANAGER_WSTETH`       | `0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22`   | Liquity V2 wstETH-branch TroveManager                  | v1.5       |
| `LIQUITY_V2_TROVE_MANAGER_RETH`         | `0xb2B2ABEb5C357a234363FF5D180912D319e3e19e`   | Liquity V2 rETH-branch TroveManager                    | v1.5       |
| `LIQUITY_ORACLE_READ_GAS`               | `100_000`                                      | Gas-bound on each TroveManager staticcall (grief cap)  | v1.5       |
| `MAX_FREE_TIER`                         | `10_000`                                       | Hard ceiling on the deployment-set `freeTier`          | v1.0       |
| `MAX_TOPUP_BUDGET_PER_ACTION`           | `1_000_000`                                    | Hard ceiling on L2-side topup budgetIncrement          | v1.0       |

### Deployment-set runtime parameters

| Parameter                          | Set by         | Bounds                          | Introduced |
| ---------------------------------- | -------------- | ------------------------------- | ---------- |
| `freeTier`                         | CLI flag       | `1 ≤ freeTier ≤ MAX_FREE_TIER`  | v1.0       |
| `epochDurationBlocks`              | CLI flag       | `≥ 1`                           | v1.0       |
| `boldTvlCap`                       | `setBoldTvlCap` | `0 ≤ boldTvlCap ≤ tvlCap`       | v1.2       |
| `maxDrainPerActionEth` (in `gasPoolPolicy`) | `declareLocalPolicy` | `> 0`                | v1.0       |
| `maxDrainPerActionBold` (in `gasPoolPolicy`) | `declareLocalPolicy` | `> 0`               | v1.2       |

### Phase index

For navigation in the engineering plan below:

| Phase | Title                                              | WU count (post-v1.4) |
| ----- | -------------------------------------------------- | -------------------- |
| GP.0  | Foundations and design ratification                | 3                    |
| GP.1  | Kernel data structures                             | 6                    |
| GP.2  | New laws                                           | 3                    |
| GP.3  | Admission pipeline integration                     | 4 (incl. delegated topup) |
| GP.4  | Bridge accounting amendment                        | 2                    |
| GP.5  | Solidity L1 contract amendment                     | 5 + sub-WUs          |
| GP.6  | Rust runtime amendment                             | 6 (incl. BOLD)       |
| GP.7  | Pool actor governance                              | 5                    |
| GP.8  | Sequencer integration                              | 4 (incl. v1.3 runbook) |
| GP.9  | Optional improvements                              | 5 (deferred)         |
| GP.10 | Documentation, audits, landing                     | 6 (incl. Lake/TCB)   |
| GP.11 | Embedded ETH↔BOLD AMM                              | 10 (incl. v1.4 sub-WUs) |

Total mandatory WU count post-v1.4 subdivision: ~55 work units
across 11 phases, with effort estimates summing to ~480 hours
of focused engineering work (~12 weeks single-contributor;
~4-6 weeks with 2-3 parallel contributors on disjoint sub-WU
file partitions).

---

## Status

  * **Phase prefix:** `GP` — "Gas Pool".  Successor letter pair to
    the existing `SC` / `SVC` workstreams; parallel to, not a
    successor of, Genesis-Plan Phase 7.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`,
    `lake exe stub_audit`, `lake exe naming_audit`,
    `lake exe deferral_audit`, `lake exe lex_lint`,
    `lake exe lex_codegen --check` all green throughout; **no new
    sorries**; **no new axioms**; **no expansion of the kernel TCB**;
    **no new `opaque` declarations**.
  * **TCB delta:** zero.  Every new Lean module ships under
    `LegalKernel/Authority/ActorBudget.lean`,
    `LegalKernel/Laws/DepositWithFee.lean`,
    `LegalKernel/Laws/TopUpActionBudget.lean`, and their test
    companions.  None touches `Kernel.lean` or `RBMapLemmas.lean`.
    `Authority/SignedAction.lean` is modified to add the budget-check
    layer in the *admission* pipeline (not in `step_impl`); the
    existing `nonce_uniqueness` and `replay_impossible` theorems are
    preserved.
  * **Trust-assumption delta:** **strictly weaker.**  Four
    deployment-side trust assumptions are added — all four are
    immutable post-deployment, not opaques:
    (a) `MIN_FEE_BPS ≤ chosenFeeBps ≤ MAX_FEE_BPS` (constructor
    constants; hard caps `MIN_FEE_BPS ≥ 0`, `MAX_FEE_BPS ≤ 5000 =
    50 %`).  Note `MAX_FEE_BPS` is widened from v1.0's 500 to 5000
    because (i) the user picks the fee, not the deployer, so the
    deployer can no longer extract via a high default;
    (ii) a malicious user paying a 50 % fee *gifts* the
    sequencer, not the deployer;
    (b) `weiPerBudgetUnit ≥ 1` (immutable; bumping requires
    `KnomosisMigration` handoff);
    (c) `MAX_BUDGET_PER_DEPOSIT ≤ 2⁶³ − 1` (compile-time
    `uint64`-safety bound; one bit of headroom for safety
    arithmetic);
    (d) `freeTier ≥ 1` (otherwise newly-registered actors with
    zero deposit-budget are permanently locked out unless they
    receive an out-of-band top-up).
    The kernel proves none of these parameters are safe in
    absolute terms; it proves *consistent behaviour* given
    whatever values the deployment supplies, with the caps making
    every worst case bounded.
  * **Backwards-compat delta:** additive.  No existing `Action`
    constructor changes index; two new constructors are appended at
    indices 19 (`depositWithFee`) and 20 (`topUpActionBudget`).  The
    existing `deposit` (index 13) and `withdraw` (index 14)
    constructors are preserved and unchanged.
    Note (2026-05-22 amendment, GP.3 wiring closure): the planning
    document originally envisioned a two-variant `BudgetPolicy`
    inductive (`.unlimited | .bounded ...`) that would have let
    legacy deployments opt out of budget enforcement entirely.  The
    landed implementation drops the `.unlimited` variant — every
    deployment runs in `.bounded` mode — and the genesis default
    `.bounded 0 1 0` is *deny-by-default*: a `freeTier = 0` actor
    at `currentEpoch = 0` cannot consume budget through
    `EpochBudgetState.consume` (whose `normalise` only floors when
    `lastSeenEpoch < currentEpoch`).  Deployments MUST configure a
    sensible `BudgetPolicy.mkBounded` at bootstrap (e.g.
    `.bounded freeTier 1 currentEpoch` with `freeTier ≥ 1` and
    `currentEpoch ≥ 1`); a deployment that bootstraps from
    `ExtendedState.empty` without overriding `budgetPolicy` admits
    nothing.  This is mathematically strictly stronger than the
    original "legacy = unlimited" plan: there is no way to bypass
    the budget gate at the admission layer.  The test
    `genesisDefaultDeniesAdmission` in
    `LegalKernel/Test/Runtime/LoopHappyPath.lean` pins the
    deny-by-default behaviour at value level.
  * **Frozen indices reserved by this workstream:**
    * `Action.depositWithFee` at index 19
    * `Action.topUpActionBudget` at index 20
    * `Event.depositWithFeeCredited` at index 16
    * `Event.actionBudgetTopUp` at index 17
    * `Event.gasPoolClaim` at index 18
  * **Solidity-side scope:** one amended contract (`KnomosisBridge.sol`)
    with two parallel entry points (ETH + BOLD).  Immutable
    constructor parameters added by the workstream (current as of
    GP.11.1): the GP.5.1 / GP.5.4 fee-split set (`minFeeBps`,
    `maxFeeBps`, `weiPerBudgetUnitEth`, `weiPerBudgetUnitBold`,
    `boldTokenAddress` → `boldEnabled`), the GP.5.5 BOLD-safety roles
    (`boldCircuitBreaker`, `boldAdmin`, `enableLiquityAutoCircuitTrigger`),
    and the GP.11.1 `ammSeedRatioBps`.  Constitutional compile-time
    constants under the GP.5.2 audit gate (current): six `uintN` caps —
    `MAX_FEE_BPS_CAP = 5000`, `MIN_WEI_PER_BUDGET_UNIT = 1`,
    `MAX_BUDGET_PER_DEPOSIT = 1_000_000_000_000`,
    `LIQUITY_ORACLE_READ_GAS = 100_000` (GP.5.5),
    `AMM_SWAP_FEE_BPS = 30` (GP.11.1), `MAX_AMM_SEED_RATIO_BPS = 8000`
    (GP.11.1) — plus four address pins (`BOLD_TOKEN_ADDRESS` +
    three `LIQUITY_V2_TROVE_MANAGER_*`) and the `EXPECTED_BOLD_SYMBOL =
    "BOLD"` string pin.  Two new payable entry points
    (`depositETHWithFee` taking `chosenFeeBps`, `depositBoldWithFee`
    taking `chosenFeeBps` + `amount`); one new event
    (`DepositWithFeeInitiated`) with a `resourceId` field distinguishing
    ETH (0) from BOLD (1); and the GP.11.1 embedded-AMM state scaffold
    (`ammReserveEth` / `ammReserveBold` mutable reserves).  No new
    contracts.
  * **Rust-side scope:** four crates touched —
    `knomosis-l1-ingest` (decode new event, encode new Action variants),
    `knomosis-host` (admission policy with budget gate),
    `knomosis-event-subscribe` (new event variants on the wire),
    `knomosis-storage` / `knomosis-indexer` (epoch budget view, if a
    deployment wants a per-actor budget UI).
  * **DoS bounds reserved by this workstream:**
    * `MAX_FEE_BPS_CAP = 5000` — compile-time hard cap on the
      deployment's `maxFeeBps` constructor argument; the actual
      `maxFeeBps` may be set lower at deploy time.  Applies
      uniformly to ETH and BOLD entry points.
    * `MIN_WEI_PER_BUDGET_UNIT = 1` — compile-time minimum for
      both `weiPerBudgetUnitEth` and `weiPerBudgetUnitBold`;
      rules out the degenerate divide-by-zero shape on either
      leg.
    * `MAX_BUDGET_PER_DEPOSIT = 10¹²` — single-deposit budget
      grant ceiling; clamp (not revert).  Applies to both ETH
      and BOLD deposit paths.  Prevents super-deposits from
      minting unbounded budget that would inflate state size and
      amortise the Sybil-cost gate over too many actions.  The
      value `10¹²` is chosen so a deposit can buy 1 trillion
      actions max — easily enough for any honest super-user, far
      below the spam threshold even at 1 ms per action
      (~31 years of continuous spam).
    * `BOLD_TOKEN_ADDRESS = 0x6440f144b7e50d6a8439336510312d2f54beb01d`
      — compile-time pin on the canonical Liquity V2 BOLD token
      address.  Constructor reverts if the deployer passes a
      different address.
    * `EXPECTED_BOLD_SYMBOL = "BOLD"` — constructor calls
      `BOLD_TOKEN.symbol()` and reverts if the returned string
      is not `"BOLD"`; defence-in-depth against address-pin
      bypass.
    * `MAX_FREE_TIER = 10_000` — hard cap on per-epoch free
      budget to defend against accidental misconfiguration.
    * `MAX_TOPUP_BUDGET_PER_ACTION = 1_000_000` — caps the budget
      increment a single `topUpActionBudget` action can purchase,
      so the gas-pool exchange rate is bounded for the L2-side
      top-up path.  Distinct from `MAX_BUDGET_PER_DEPOSIT`; the
      two paths have different economic shapes (L2 top-up is
      effectively a transfer-with-discount; bridge deposit is a
      fresh inflow with an exchange rate).  Applies to both
      ETH and BOLD top-ups.
    * `MAX_POOL_DRAIN_PER_EPOCH` (per resource) — deployment-set;
      enforced by the gas-pool actor's `LocalPolicy.capAmount`
      clause; one clause per resource (ETH and BOLD); defaults to
      a small fraction of pool balance (e.g., 1 %).
    * `EPOCH_DURATION_SECONDS` — deployment-set; defaults to 86 400
      (one day).
    * `BOLD_DEPEG_CIRCUIT_BREAKER_BPS = 500` (5 % deviation) —
      operator-triggered circuit breaker that pauses BOLD
      deposits if BOLD trades >5 % off peg for >24 hours,
      consulted via an off-chain oracle feed.  Pause is on the
      BOLD entry point only; the ETH entry point remains open.
      Defence-in-depth against a slow-rolling BOLD depeg
      affecting pool real value.
  * **Test count target:** the Lean side should grow from
    ~2 257 (post-SVC.5.e+ audit-pass-3) to approximately 2 600
    (+ ~340 across new suites: `actor-budget`,
    `laws-deposit-with-fee`, `laws-top-up-action-budget`,
    `admission-budget-gate`, plus extensions to existing suites for
    cross-stack-equivalence and integration).  The Rust side should
    grow by ~120 tests across `knomosis-l1-ingest`, `knomosis-host`,
    `knomosis-event-subscribe`.  The Solidity side should grow by ~30
    tests in a new `BridgeFeeSplit.t.sol` suite plus cross-stack
    extensions.

---

## Executive summary

Workstream GP is structured as **eleven sequential phases** plus an
optional improvements phase (GP.9).  The eleven mandatory phases are:

  1. **GP.0 — Foundations.**  Genesis-Plan amendment §15E text;
     planning-doc cross-references; open-question resolutions.
  2. **GP.1 — Kernel data structures.**  `ActorBudget`,
     `EpochBudgetState`, the `ExtendedState` widening, and the
     normalise / consume / topUp state-machine lemmas.
  3. **GP.2 — New laws.**  `Laws/DepositWithFee.lean` and
     `Laws/TopUpActionBudget.lean` with their classification
     instances (`IsMonotonic` / `IsConservative` / `LocalTo` /
     `FreezePreserving`) and Lex re-expressions.
  4. **GP.3 — Admission pipeline.**  `Authority/SignedAction.lean`
     modification adding the budget-consumption layer.  Atomic with
     `step_impl` from a state-update standpoint, but layered above
     `step_impl` so the kernel TCB is unchanged.
  5. **GP.4 — Bridge accounting amendment.**  Widening
     `DepositRecord` with a `poolAmount` field; updating the
     §15B / §15D bridge accounting equation; per-resource
     bookkeeping proofs.
  6. **GP.5 — Solidity L1 contract amendment.**  Five sub-WUs:
     GP.5.1 user-chosen fee-split logic in new `depositETHWithFee`
     entry point; GP.5.2 audit gate for compile-time constants;
     GP.5.3 `KnomosisStepVM` extension for the two new Action
     variants; GP.5.4 (v1.2) parallel `depositBoldWithFee` entry
     point with BOLD ERC-20 integration and BOLD-leg exchange
     rate; GP.5.5 (v1.2) BOLD-specific safety hardening (per-
     currency circuit breaker, per-BOLD TVL cap,
     operator-triggered depeg pause).  Five immutable constructor
     arguments (`minFeeBps`, `maxFeeBps`, `weiPerBudgetUnitEth`,
     `weiPerBudgetUnitBold`, `boldTokenAddress`).  Four compile-
     time caps (`MAX_FEE_BPS_CAP`, `MIN_WEI_PER_BUDGET_UNIT`,
     `MAX_BUDGET_PER_DEPOSIT`, `EXPECTED_BOLD_SYMBOL`).
  7. **GP.6 — Rust runtime.**  `knomosis-l1-ingest` decode of the new
     event (with `resourceId` field distinguishing ETH vs BOLD);
     `knomosis-host` admission gate; `knomosis-event-subscribe` new
     event variants; cross-stack fixtures (ETH leg + BOLD leg).
  8. **GP.7 — Pool actor governance via LocalPolicy.**  Reservation
     of `ActorId 1` as `gasPoolActor`; declaration of the canonical
     `gasPoolPolicy` with `denyTags` + `requireRecipientIn` +
     `capAmount` clauses; theorems bounding pool outflow.
  9. **GP.8 — Sequencer integration.**  `knomosis-host` and operator
     runbook; free-tier configuration; sequencer-reward-claim
     mechanism.
 10. **GP.10 — Documentation, audits, landing.**  Final
     Genesis-Plan amendment; README / CLAUDE.md updates;
     `docs/abi.md` extensions; migration runbook; full audit pass.
 11. **GP.11 — Embedded ETH↔BOLD AMM (v1.3).**  Seven sub-WUs:
     state variables + reserves (GP.11.1); AMM seeding on
     deposit (GP.11.2); the constant-product swap function
     with Uniswap v2 math + slippage + deadline protection
     (GP.11.3); L2-side mirroring via new `Action.ammSwap`
     law (GP.11.4); `ammReserveActor` reservation (GP.11.5);
     reserve-actor LocalPolicy (GP.11.6); cross-stack AMM
     fixture corpus (GP.11.7).  Replaces v1.2's "external L1
     DEX" path with internal price discovery; gas pool
     captures swap fees in addition to deposit skim.
 12. **GP.9 (optional) — Improvements.**  Refund-on-exit;
     yield-bearing pool via Lido / Rocket Pool; tiered fee; dual
     pool for user rewards; stake-bonded identity registration.

The minimum-viable-product (MVP) is GP.0 – GP.8 + GP.10 + GP.11.
GP.9 is a v2 polish that can land separately.  Some deployments
may opt to deploy with `ammSeedRatioBps = 0` (effectively
disabling the AMM at construction); these deployments skip GP.11
operationally but the code remains in the contract.

The plan has **no cyclic dependencies**.  GP.1 must precede every
other phase except GP.0; GP.2 must precede GP.3; GP.5 must precede
GP.6's L1-ingest sub-WUs; GP.7 may proceed in parallel with GP.3 –
GP.6 after GP.1 lands.  The full dependency graph is in Appendix C.

---

## Architectural overview

### 1. The three-actor cast

| Actor                | Reserved `ActorId` | Role                                                                                         |
| -------------------- | ------------------ | -------------------------------------------------------------------------------------------- |
| `bridgeActor`        | 0 (existing)       | Signs `depositWithFee`, `registerIdentity`, `replaceKey` actions in response to L1 events.   |
| `gasPoolActor`       | 1 (**new**)        | Holds the skim and top-up revenue; can only emit `transfer` to `sequencerActor`, capped per epoch by `LocalPolicy`. |
| `sequencerActor`     | 2 (**new**)        | The deployment's sequencer key; can claim from `gasPoolActor` (with L1-attestation evidence in the v2 mechanism); can submit state roots to L1. |

`ActorId 0` is already reserved; `ActorId 1` and `ActorId 2` become
the next two reserved slots.  `AddressBook.empty.nextActorId` advances
from 1 to 3 in the post-GP-1 build; existing deployments that have
already assigned `ActorId 1` or `2` must migrate (Phase GP.10).

### 2. The gas resources

v1.2 supports two gas resources in parallel:

| `ResourceId` | Asset                                | L1 token address                                | Decimal | Pool-solvency relevance |
| ------------ | ------------------------------------ | ----------------------------------------------- | ------- | ----------------------- |
| 0            | Native ETH                           | (n/a — native asset)                            | 18      | Counts toward the ETH-leg pool-solvency invariant |
| 1            | BOLD (Liquity V2 stablecoin)         | `0x6440f144b7e50d6a8439336510312d2f54beb01d`    | 18      | Counts toward the BOLD-leg pool-solvency invariant |
| ≥ 2          | Other ERC-20 (per-deployment choice) | per-deployment AddressBook entry                | varies  | Out of scope for v1.2: does not contribute to the gas pool |

The L1 contract pins the BOLD token address as an `immutable`
constructor parameter, verifying at construction time that the
address resolves to a contract returning `"BOLD"` from
`.symbol()`.  (Defence-in-depth: if a future Liquity V2
deployment changes the canonical address, the bridge fails
construction loudly rather than silently treating an attacker
token as BOLD.)

**Mathematical contract.**  The pool's per-resource solvency
invariants are stated independently:

```
For each r ∈ {0, 1}:
  poolBalance(r) = totalPoolDeposited(r) - totalPoolDrained(r)
                 + totalTopUpsReceived(r)
```

where the per-resource sums project out the records matching
that resource via the `DepositRecord.resource` field.  The two
invariants do not interact — a drain on the BOLD leg cannot
affect the ETH leg, and vice versa.  This independence is the
formal counterpart of the "multi-currency, no AMM" design choice:
without cross-currency conversion happening inside the bridge,
the two pool legs are mathematically separate accounting domains.

ERC-20s other than BOLD that flow through the bridge (e.g.,
generic project tokens via `depositERC20`) do *not* contribute
to the gas pool; their deposits emit the legacy
`DepositInitiated` event and credit the recipient at the
appropriate `ResourceId` without any pool skim.  This preserves
v1.2's calibration discipline — only the two gas-pool resources
participate in the budget-grant calculus.

### 3. The four state extensions

```lean
-- Pre-GP (existing):
structure ExtendedState where
  kernel : State
  bridge : BridgeState
  -- (other existing fields)

-- Post-GP:
structure ExtendedState where
  kernel       : State
  bridge       : BridgeState
  epochBudgets : EpochBudgetState  -- NEW (GP.1)
  -- (other existing fields)
```

`EpochBudgetState` is a `TreeMap ActorId ActorBudget compare`.  Empty
on genesis.  Lazy-evaluated: an absent entry means "fresh actor,
budget = freeTier at current epoch."

`currentEpoch` is a *runtime* parameter, not a state field.  It is
threaded through the admission pipeline from the sequencer's clock /
L1 block number.  This avoids needing an `Action.advanceEpoch` law
and the associated O(n) state rewrite.

### 4. The data-flow contract

A new deposit produces this state delta:

```
L1: msg.value = V                                 (user pays V)
    chosenFeeBps = K                              (user picks K)
    require minFeeBps ≤ K ≤ maxFeeBps             (constructor bounds)
    poolAmount = V × K / 10000                    (floor division)
    userAmount = V − poolAmount                   (always V − fee ≥ 0)
    rawBudgetGrant = poolAmount / weiPerBudgetUnit   (uint256 → clamp)
    budgetGrant = min(MAX_BUDGET_PER_DEPOSIT, rawBudgetGrant)
    emit DepositWithFeeInitiated(
      user, userAmount, poolAmount, budgetGrant, depositId
    )

L2: ingest produces SignedAction Action.depositWithFee
      (resource=0, recipient=user, poolActor=gasPoolActor,
       userAmount, poolAmount, budgetGrant, depositId)
    step_impl applies (State):
      s' = setBalance s 0 user (gB s 0 user + userAmount)
      s'' = setBalance s' 0 gasPoolActor (gB s' 0 gasPoolActor + poolAmount)
    Admission layer applies (EpochBudgetState):
      ebs' = ebs.topUp user now freeTier budgetGrant
    BridgeState updated:
      consumed[depositId] := DepositRecord r=0
        userAmount = userAmount, poolAmount = poolAmount,
        budgetGrant = budgetGrant
```

The kernel-level `step_impl` is responsible only for the balance
mutations.  The budget mutation is handled at the same admission
layer that processes the `nonceMatches` / `localPolicyOk` /
`bridgeAdmissibleWith` checks.  This keeps the kernel TCB
unchanged (the budget-state mutation lives in `Authority/
SignedAction.lean`, not in `Kernel.lean`) while preserving
atomicity from the caller's perspective: either the entire bundle
(balance + budget + bridge consumed-set) commits, or none of it
does.

A normal user action produces this state delta:

```
L2: ingest SignedAction sa from user u with action a
    Admission:
      1. verifySignature sa  --- existing
      2. nonceOk(es.kernel, sa)  --- existing
      3. localPolicyOk(es.kernel.policies, sa.signer, a)  --- existing
      4. budgetConsume(es.epochBudgets, u, now, freeTier, cost=1)  --- NEW
         → if exhausted, reject with NotAdmissible "InsufficientBudget"
    step_impl applies (existing semantics)
    State delta:
      kernel: a's apply_impl (existing)
      epochBudgets: u's budget decreases by 1
      bridge: per existing rules
```

A user top-up:

```
L2: user u submits SignedAction Action.topUpActionBudget
      (gasResource=0, gasAmount=10, budgetIncrement=100, poolActor=gasPoolActor)
    Admission:
      1-4 as above; topUp consumes 1 budget unit (i.e., the action of
         topping up costs 1 unit; the action mints 100 new units)
    step_impl applies topUpActionBudget's apply_impl:
      s' = setBalance s 0 u (gB s 0 u - 10)
      s'' = setBalance s' 0 gasPoolActor (gB s' 0 gasPoolActor + 10)
    State delta:
      kernel: balance flipped from u to gasPoolActor
      epochBudgets: u's budget decreases by 1 then increases by 100
                    → net +99
      bridge: unchanged
```

The asymmetry "consume 1, mint many" is deliberate: it makes top-up
itself cheap to execute (one budget unit) but adds substantial budget
for downstream actions.

---

## Trust assumptions

The kernel itself proves several properties unconditionally given
**propext, Classical.choice, Quot.sound** as the only axioms (the
canonical three).  The properties that depend on deployment-side
configuration are:

| Property                                       | Trust assumption                                                          |
| ---------------------------------------------- | ------------------------------------------------------------------------- |
| Per-deposit fee bounded                        | `MIN_FEE_BPS ≤ maxFeeBps ≤ MAX_FEE_BPS_CAP = 5000` (immutable on L1 `KnomosisBridge` constructor) |
| Budget-grant bounded (both resources)          | `MAX_BUDGET_PER_DEPOSIT = 10¹²` (compile-time constant, applies to both ETH and BOLD paths) |
| ETH-leg exchange rate sane                     | `weiPerBudgetUnitEth ≥ 1` (immutable on L1 `KnomosisBridge` constructor)     |
| BOLD-leg exchange rate sane                    | `weiPerBudgetUnitBold ≥ 1` (immutable on L1 `KnomosisBridge` constructor)    |
| BOLD token authenticity                        | Constructor verifies `BOLD_TOKEN_ADDRESS = 0x6440f144b7e50d6a8439336510312d2f54beb01d` and `BOLD_TOKEN.symbol() == "BOLD"` |
| BOLD ERC-20 conformance                        | BOLD is standard ERC-20: no fee-on-transfer, no rebase, no transfer blocklist for the bridge address (Liquity V2 design) |
| BOLD peg stability                             | BOLD trades within `[0.95, 1.05]` USD (historical norm); larger depeg events trigger operator-level circuit-breaker actions |
| Liquity V2 governance neutrality               | Liquity V2 governance does not freeze, blocklist, or otherwise modify the bridge's BOLD position; defence-in-depth via TVL cap |
| Free-tier DoS resistance                       | `freeTier × admittedActorCount` is sustainable for the sequencer          |
| Per-actor honest accounting                    | `Authority.Crypto.Verify` is EUF-CMA secure (existing)                    |
| Pool drain bound (both resources)              | Sequencer key cannot mint identities (existing identity-registration gate); per-resource caps in `gasPoolPolicy` |
| Sequencer-claim soundness (v1.2)               | Sequencer is trusted to claim only what it actually spent (operator-level); external L1 DEX trusted for ETH↔BOLD conversions during reimbursement |
| Sequencer-claim soundness (v2 / optional)      | L1 receipt verifier proves the claimed L1 gas usage (cryptographic)       |

The v1 sequencer-claim mechanism is *honour-system* w.r.t. how much
the sequencer claims — it is bounded by `capAmount` per claim and per
epoch, but a fully-malicious sequencer could over-claim within the cap.
This is acceptable because:

1. The cap bounds the absolute loss.
2. The dispute pipeline can challenge over-claims (deployment-level).
3. The sequencer is a single party already trusted for liveness.
4. The v2 cryptographic-receipt mechanism is straightforward to add
   once it becomes operationally important.

---

## Out-of-scope items for this workstream

The following items are **intentionally excluded** from Workstream GP
and tracked separately:

  * **Cryptographically-verified sequencer L1-gas claims.**  v2 work,
    not v1; mentioned in §GP.9 as an optional improvement.
  * **Refund-on-exit for bridge withdrawals.**  v2 work; §GP.9.1.
  * **Yield-bearing pool via Lido / Rocket Pool.**  v2 work; §GP.9.2;
    requires a new staking-provider trust assumption.
  * **Tiered fee curve / deployment-defined budget-grant
    schedules.**  v2 work; §GP.9.3.  v1.1 already provides a
    user-chosen `chosenFeeBps`; v2 would add a *piecewise*
    `weiPerBudgetUnit` schedule (cheaper budget grants at higher
    fee tiers, encouraging super-user deposits) — layerable on
    top of v1.1's mechanism without breaking byte-equivalence.
  * **Stake-bonded identity registration.**  Independent workstream
    (call it `Workstream SB`); §GP.9.5 sketches the integration but
    SB itself is out of scope here.
  * **Cross-resource gas payment.**  All gas payments and pool
    balances are denominated in `ResourceId 0` (bridged native ETH)
    in v1.  ERC-20 gas payment is v2 work.
  * **Per-action variable cost.**  Every admitted action consumes
    exactly **1** budget unit in v1.  Per-action variable cost (e.g.,
    `distributeOthers` costs more than `transfer`) is a v2 polish.
  * **Formal action-complexity ceiling theorem.**  The "action cost
    is bounded by `K` elementary operations per variant" theorem
    sketched in the design discussion is genuinely useful but
    requires complexity-reasoning machinery Lean 4 does not natively
    support; tracked as Phase 7 future work.

---

## Engineering plan

### Phase GP.0 — Foundations and design ratification

#### WU GP.0.1: Genesis-Plan amendment §15E text

  * **Goal.**  Author the §15E section of `docs/GENESIS_PLAN.md`
    formalising the unified gas-pool / budget mechanism at the
    plan-level (not the implementation level).
  * **File:** `docs/GENESIS_PLAN.md` (new §15E, inserted after §15D
    Ethereum integration; line offset will be ~6500 post-§15D).
  * **Deliverables.**
    * §15E.1 motivation: closing the DoS-funding circularity gap
      and adding a "pay-up-front for capacity" user-experience tier.
    * §15E.2 the three reserved actors and their roles.
    * §15E.3 the per-deposit user-chosen fee equation (extends
      §15D bridge accounting equation with the `poolAmount`,
      `budgetGrant`, and `chosenFeeBps` terms; states the
      fee-bounds-check invariant
      `minFeeBps ≤ chosenFeeBps ≤ maxFeeBps`).
    * §15E.4 the per-actor budget state machine specification
      (normalise / consume / topUp).
    * §15E.5 the L1-side per-resource `weiPerBudgetUnitEth` /
      `weiPerBudgetUnitBold` exchange rates and the
      `MAX_BUDGET_PER_DEPOSIT` clamp semantics; the clamp is
      always **non-revert** (a deposit at a high fee never fails
      due to budget cap, it just receives a clamped grant).
    * §15E.6 the gas-pool actor's canonical `LocalPolicy` template
      and the resulting drain bound.
    * §15E.7 the two new opaques' status (none — only typeclass
      parameters are added).
    * §15E.8 amended trust-assumption summary (the table in §1.4 of
      the plan).
  * **Acceptance criteria.**
    * Two reviewers sign off (no TCB delta, but per
      §13.6 the planning document itself names new mechanisms in
      the Genesis-Plan body, which is a §13.6 amendment surface).
    * `docs/audits/` cross-reference index updated to point at
      §15E for any subsequent gas-pool audit.
  * **Dependencies.**  None.
  * **Estimated effort.**  1 reviewer-day for drafting, 1
    reviewer-day for review.

#### WU GP.0.2: Planning-doc cross-references

  * **Goal.**  Update `docs/planning/open_questions.md`,
    `docs/planning/deferred_work_index.md`, and `docs/planning/
    phase_7_plan.md` to reference this workstream.
  * **Files:** the three files above.
  * **Deliverables.**
    * `open_questions.md` adds OQ-GP-1 through OQ-GP-10 (see §10).
    * `deferred_work_index.md` lists Workstream GP under "active".
    * `phase_7_plan.md` references GP as a Phase-7-prerequisite
      (variable-cost actions in Phase 7 depend on GP's budget
      infrastructure).
  * **Acceptance criteria.** One reviewer; `lake build` green.
  * **Dependencies.**  GP.0.1 (so §15E exists to reference).
  * **Estimated effort.**  ~half a reviewer-day.

#### WU GP.0.3: Action-index registry pre-reservation

  * **Goal.**  Append indices 19 and 20 to `Lex/IndexRegistry.txt` as
    reserved-but-unfilled entries.  Append event indices 16, 17, 18.
  * **Files:** `Lex/IndexRegistry.txt`,
    `LegalKernel/Events/Types.lean` (event-index registry comment).
  * **Deliverables.**  Two index-registry append-only updates that
    `lake exe lex_lint` accepts.  Reservation-only entries with the
    bodies populated in GP.2 / GP.6 — the registry append-only
    discipline (LX.1) permits this.
  * **Acceptance criteria.**  `lake exe lex_lint` and `lake exe
    lex_codegen --check` both green.
  * **Dependencies.**  None.
  * **Estimated effort.**  ~0.5 hours.

---

### Phase GP.1 — Kernel data structures

This phase introduces the `ActorBudget` type, the `EpochBudgetState`
map, and the state-machine operations (`normalise`, `consume`,
`topUp`) with their correctness lemmas.  No new actions, no
admission-pipeline integration yet — just the standalone
state-machine library.

#### WU GP.1.1: `ActorBudget` and `EpochBudgetState` types

> **Implementation note (2026-05-21):** `LegalKernel/Authority/ActorBudget.lean` now lands the GP.1.1–GP.1.5 core data structures and map operations (`ActorBudget`, `EpochBudgetState`, `normalise`, `consume`, `topUp`, and map-level wrappers), and `ExtendedState` in `Authority/Nonce.lean` now carries `epochBudgets`.


  * **Goal.**  Define the budget state-machine data carrier and the
    per-actor budget map.
  * **File:** `LegalKernel/Authority/ActorBudget.lean` (new).
  * **Deliverables.**

    ```lean
    namespace LegalKernel.Authority

    /-- A per-actor action-budget record carrying the last epoch
        in which this actor was touched, and the budget balance
        carried forward (top-ups carry across epochs; free-tier
        resets the balance to at least `freeTier` on first touch
        in a new epoch). -/
    structure ActorBudget where
      /-- The last epoch in which this actor's budget was
          observed or mutated.  Used by `normalise` to detect
          stale entries that need a free-tier reset. -/
      lastSeenEpoch : Nat
      /-- The budget balance carried forward into / accumulated
          during `lastSeenEpoch`. -/
      budgetBalance : Nat
      deriving Repr, DecidableEq

    namespace ActorBudget

    /-- The canonical empty budget: epoch 0, balance 0.  An actor
        absent from `EpochBudgetState` is semantically equivalent
        to this value with the `normalise` operation applied. -/
    def empty : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }

    end ActorBudget

    /-- Per-actor budget map.  Keyed by `ActorId` in canonical
        order; an absent actor defaults to `ActorBudget.empty`. -/
    abbrev EpochBudgetState := Std.TreeMap ActorId ActorBudget compare

    namespace EpochBudgetState

    /-- The genesis budget state: empty map.  Every actor reads as
        absent → `ActorBudget.empty` → `freeTier` at the current
        epoch under `normalise`. -/
    def empty : EpochBudgetState := ∅

    end EpochBudgetState

    end LegalKernel.Authority
    ```
  * **Theorems / lemmas.**
    * `ActorBudget.empty_lastSeenEpoch_zero : ActorBudget.empty.lastSeenEpoch = 0 := rfl`
    * `ActorBudget.empty_budgetBalance_zero : ActorBudget.empty.budgetBalance = 0 := rfl`
    * `EpochBudgetState.empty_is_empty : ∀ a, EpochBudgetState.empty[a]? = none`
  * **Tests.**  3 smoke tests confirming the trivial structural
    properties.
  * **Acceptance criteria.**  One reviewer; `lake build LegalKernel.
    Authority.ActorBudget` green; `lake exe naming_audit` green.
  * **Dependencies.**  GP.0.3 (index reservation only — no actual
    use yet).
  * **Estimated effort.**  ~2 hours.

#### WU GP.1.2: `normalise` operation and its lemmas

  * **Goal.**  Define `normalise` (apply free-tier reset if entering
    a new epoch) and prove its idempotence + monotonicity lemmas.
  * **File:** `LegalKernel/Authority/ActorBudget.lean` (extended).
  * **Deliverables.**

    ```lean
    /-- Normalise an `ActorBudget` against a current epoch and
        free-tier value.  If the budget is stale (its
        `lastSeenEpoch < now`), advance it to `now` and floor its
        balance at `freeTier`.  Otherwise leave it alone.

        Mathematical contract:
          * `(normalise b now ft).lastSeenEpoch = max b.lastSeenEpoch now`
          * `b.lastSeenEpoch < now → (normalise b now ft).budgetBalance ≥ ft`
          * `b.lastSeenEpoch ≥ now → normalise b now ft = b`
          * `normalise (normalise b now ft) now ft = normalise b now ft`
    -/
    def ActorBudget.normalise (b : ActorBudget) (now : Nat)
        (freeTier : Nat) : ActorBudget :=
      if b.lastSeenEpoch < now then
        { lastSeenEpoch := now,
          budgetBalance := max b.budgetBalance freeTier }
      else
        b
    ```
  * **Theorems.**
    * `normalise_idempotent : ∀ b now ft, normalise (normalise b now ft) now ft = normalise b now ft`
    * `normalise_lastSeenEpoch_eq_max : ∀ b now ft, (normalise b now ft).lastSeenEpoch = max b.lastSeenEpoch now`
    * `normalise_floors_at_freeTier : ∀ b now ft, b.lastSeenEpoch < now → (normalise b now ft).budgetBalance ≥ ft`
    * `normalise_noop_if_current : ∀ b now ft, b.lastSeenEpoch ≥ now → normalise b now ft = b`
    * `normalise_balance_lower_bound : ∀ b now ft, (normalise b now ft).budgetBalance ≥ b.budgetBalance` *(this fails when `b.lastSeenEpoch < now` and `b.budgetBalance > freeTier`; rephrase as `≥ min b.budgetBalance freeTier` if we want a strict lower bound on the original; instead state as two separate lemmas — the `b.budgetBalance` lower bound and the `freeTier` lower bound)*

    *(Author's verification: the unified `≥ b.budgetBalance` lemma
    is true because `max b.budgetBalance freeTier ≥ b.budgetBalance`
    by `Nat.le_max_left`.  Both lemmas hold.  The "rephrase" comment
    above is a self-correction that the reader can skip.)*
  * **Tests.**  10 cases covering: (a) `b.lastSeenEpoch = now`,
    (b) `b.lastSeenEpoch = now - 1`, (c) `b.lastSeenEpoch = 0`,
    (d) `b.budgetBalance > freeTier`, (e) `b.budgetBalance <
    freeTier`, (f) idempotence at fresh epoch, (g) idempotence at
    stale epoch, (h) `freeTier = 0`, (i) `now = 0`, (j) absent →
    empty → normalised → freeTier.
  * **Acceptance criteria.**  One reviewer; all lemmas pass
    elaboration + tests; `lake exe count_sorries` green.
  * **Dependencies.**  GP.1.1.
  * **Estimated effort.**  ~4 hours.

#### WU GP.1.3: `consume` operation and its lemmas

  * **Goal.**  Define `consume` (attempt to debit the budget) and
    prove its correctness.
  * **File:** `LegalKernel/Authority/ActorBudget.lean` (extended).
  * **Deliverables.**

    ```lean
    /-- Attempt to consume `cost` units of budget from `b` at epoch
        `now`.  Normalises first (so stale entries are floored at
        `freeTier`), then debits if and only if the post-normalise
        balance is ≥ `cost`.

        Returns `none` iff the budget is insufficient — this is
        the kernel's DoS gate.

        Mathematical contract (proven below):
          * `consume b now ft cost = some b' → b'.budgetBalance + cost = (normalise b now ft).budgetBalance`
          * `consume b now ft cost = some b' → b'.lastSeenEpoch = (normalise b now ft).lastSeenEpoch`
          * `consume b now ft cost = none → (normalise b now ft).budgetBalance < cost`
    -/
    def ActorBudget.consume (b : ActorBudget) (now : Nat)
        (freeTier : Nat) (cost : Nat) : Option ActorBudget :=
      let b' := b.normalise now freeTier
      if b'.budgetBalance ≥ cost then
        some { b' with budgetBalance := b'.budgetBalance - cost }
      else
        none
    ```
  * **Theorems.**
    * `consume_some_preserves_epoch`
    * `consume_some_decreases_balance_by_cost`
    * `consume_none_iff_insufficient`
    * `consume_zero_is_normalise : ∀ b now ft, consume b now ft 0 = some (normalise b now ft)`
    * `consume_monotone_in_cost : ∀ b now ft c₁ c₂, c₁ ≤ c₂ → consume b now ft c₂ = some b' → ∃ b'', consume b now ft c₁ = some b''`
  * **Tests.**  12 cases covering exact-fit, insufficient,
    over-debit, zero-cost, free-tier interaction, distinct epochs.
  * **Acceptance criteria.**  One reviewer; all lemmas pass; `lake
    exe count_sorries` green.
  * **Dependencies.**  GP.1.2.
  * **Estimated effort.**  ~5 hours.

#### WU GP.1.4: `topUp` operation and its lemmas

  * **Goal.**  Define `topUp` (add to budget) and prove its
    correctness.
  * **File:** `LegalKernel/Authority/ActorBudget.lean` (extended).
  * **Deliverables.**

    ```lean
    /-- Add `amount` units of budget to `b` at epoch `now`.
        Normalises first (so the free-tier floor applies), then
        adds.

        Mathematical contract:
          * `(topUp b now ft amt).budgetBalance = (normalise b now ft).budgetBalance + amt`
          * `(topUp b now ft amt).lastSeenEpoch = (normalise b now ft).lastSeenEpoch`
    -/
    def ActorBudget.topUp (b : ActorBudget) (now : Nat)
        (freeTier : Nat) (amount : Nat) : ActorBudget :=
      let b' := b.normalise now freeTier
      { b' with budgetBalance := b'.budgetBalance + amount }
    ```
  * **Theorems.**
    * `topUp_preserves_epoch`
    * `topUp_increases_balance_by_amount`
    * `topUp_zero_is_normalise`
    * `topUp_then_consume_roundtrip : ∀ b now ft amt cost, cost ≤ (normalise b now ft).budgetBalance + amt → ∃ b', consume (topUp b now ft amt) now ft cost = some b'`
  * **Tests.**  8 cases.
  * **Acceptance criteria.**  One reviewer; all lemmas pass; `lake
    exe count_sorries` green.
  * **Dependencies.**  GP.1.3.
  * **Estimated effort.**  ~3 hours.

#### WU GP.1.5: `EpochBudgetState` map operations

  * **Goal.**  Define the lookup / update helpers that wrap
    `ActorBudget` operations over the per-actor map.
  * **File:** `LegalKernel/Authority/ActorBudget.lean` (extended).
  * **Deliverables.**

    ```lean
    namespace EpochBudgetState

    /-- Look up an actor's current effective budget (post-normalise).
        Absent actor → `freeTier` (fresh slot, normalised). -/
    def currentBudget (ebs : EpochBudgetState) (a : ActorId)
        (now : Nat) (freeTier : Nat) : Nat :=
      ((ebs[a]?.getD ActorBudget.empty).normalise now freeTier).budgetBalance

    /-- Attempt to consume `cost` units for actor `a`.  Returns
        either an updated `EpochBudgetState` or `none` on
        insufficient budget. -/
    def consume (ebs : EpochBudgetState) (a : ActorId)
        (now : Nat) (freeTier : Nat) (cost : Nat) :
        Option EpochBudgetState :=
      match (ebs[a]?.getD ActorBudget.empty).consume now freeTier cost with
      | none    => none
      | some b' => some (ebs.insert a b')

    /-- Add `amount` units of budget to actor `a`. -/
    def topUp (ebs : EpochBudgetState) (a : ActorId)
        (now : Nat) (freeTier : Nat) (amount : Nat) :
        EpochBudgetState :=
      let b' := (ebs[a]?.getD ActorBudget.empty).topUp now freeTier amount
      ebs.insert a b'

    end EpochBudgetState
    ```
  * **Theorems.**
    * `consume_other_actor_unchanged : ∀ ebs a a' now ft cost ebs', a ≠ a' → consume ebs a now ft cost = some ebs' → ebs'[a']? = ebs[a']?`
    * `topUp_other_actor_unchanged : analogous`
    * `currentBudget_after_consume : ∀ ebs a now ft cost ebs', consume ebs a now ft cost = some ebs' → currentBudget ebs' a now ft + cost = currentBudget ebs a now ft`
    * `currentBudget_after_topUp : ∀ ebs a now ft amt, currentBudget (topUp ebs a now ft amt) a now ft = currentBudget ebs a now ft + amt`
    * `currentBudget_freeTier_floor : ∀ ebs a now ft, ebs[a]?.getD ActorBudget.empty |>.lastSeenEpoch < now → currentBudget ebs a now ft ≥ ft` (renaming the floor lemma to its map-level form)
  * **Tests.**  20 cases covering locality, epoch transitions,
    map-empty case, absent-actor case.
  * **Acceptance criteria.**  One reviewer; all theorems pass;
    `lake exe count_sorries` green; `lake exe naming_audit` green.
  * **Dependencies.**  GP.1.4.
  * **Estimated effort.**  ~6 hours.

#### WU GP.1.6: CBE encoding for `ActorBudget` / `EpochBudgetState`

  * **Goal.**  Extend the CBE encoder to cover the new types so
    they participate in log-replay determinism and Merkle commits.
  * **File:** `LegalKernel/Encoding/ActorBudget.lean` (new).
  * **Deliverables.**
    * `Encodable ActorBudget` instance: concatenate `8-byte
      lastSeenEpoch ‖ 8-byte budgetBalance` (LE-Nat heads).
    * `Encodable EpochBudgetState` instance: same shape as
      `LocalPolicies` (`Encoding/LocalPolicy.lean`'s `encodeMap`
      pattern).
    * `ActorBudget.encode_injective` theorem.
    * `EpochBudgetState.encode_injective` theorem (mirrors EI.5
      `LocalPolicies.encodeMap_injective`).
  * **Tests.**  15 cases: round-trip, injectivity witnesses,
    cross-encoding distinctness between `ActorBudget` /
    `LocalPolicy` (defence-in-depth against tag collisions in any
    container that might hold both).
  * **Acceptance criteria.**  One reviewer; encode/decode round-trip
    smoke + injectivity theorem green.
  * **Dependencies.**  GP.1.5.
  * **Estimated effort.**  ~4 hours.

---

### Phase GP.2 — New laws

Two new `Transition` definitions: `depositWithFee` (the bridge-skim
form) and `topUpActionBudget` (user-initiated budget purchase).

#### WU GP.2.1: `Laws/DepositWithFee.lean`

  * **Goal.**  Define `depositWithFee` and prove the full theorem
    catalogue (mirrors `Laws/Deposit.lean`'s shape exactly).
  * **File:** `LegalKernel/Laws/DepositWithFee.lean` (new).
  * **Deliverables.**

    ```lean
    namespace LegalKernel.Laws

    /-- Bridge deposit with user-chosen fee split: credit
        `userAmount` to `recipient` and `poolAmount` to
        `poolActor` under resource `r`.  The action additionally
        carries `_budgetGrant` (consumed at the admission layer,
        not by `step_impl`), which credits the recipient's per-
        epoch action budget by that amount.

        The L1-side `KnomosisBridge` contract computes
        `(userAmount, poolAmount, budgetGrant)` from the user's
        deposit amount (`msg.value` for ETH, transferred `amount`
        for BOLD) and the user-supplied `chosenFeeBps`, clamped
        by the immutable per-resource exchange rate
        (`weiPerBudgetUnitEth` for resource 0,
        `weiPerBudgetUnitBold` for resource 1) and the
        compile-time `MAX_BUDGET_PER_DEPOSIT`; the L2-side law
        trusts the L1
        contract's computation (the L1 contract is in scope of
        Workstream-E's immutability discipline).

        Kernel precondition: `True`.  The deposit-id uniqueness
        check lives in `BridgeAdmissibleWith` (§7.0); we do NOT
        require `recipient ≠ poolActor` — the case where they
        coincide is well-defined and means "all credit went to the
        recipient, who happens to be the pool actor."

        Effect on `State`: two `setBalance` operations, applied in
        order.  Order is deliberate: `recipient` first, then
        `poolActor` re-reads from the post-recipient state.
        When `recipient = poolActor`, the second setBalance
        overwrites with the sum of the first two updates
        (verified in the `totalSupply` theorem below).

        Effect on `EpochBudgetState`: handled in
        `Authority/SignedAction.lean` (see GP.3.2).  The
        `_budgetGrant` field is named with an underscore here to
        signal that the kernel `Transition` does not directly
        consume it — it is read off the action payload at the
        admission layer.

        Soundness check (author): the `_budgetGrant` argument is
        kept in the constructor for cross-stack byte-equivalence
        (the field must appear at the same position in both Lean
        and Solidity step-VM payloads).  Removing it would break
        the SVC step-VM coherence theorem chain for action index
        19. -/
    def depositWithFee (r : ResourceId) (recipient : ActorId)
        (poolActor : ActorId) (userAmount poolAmount : Amount)
        (_budgetGrant : Nat) (_depositId : Bridge.DepositId) :
        Transition where
      pre        := fun _ => True
      decPre     := fun _ => inferInstance
      apply_impl := fun s =>
        let s1 := setBalance s r recipient (getBalance s r recipient + userAmount)
        setBalance s1 r poolActor (getBalance s1 r poolActor + poolAmount)

    end LegalKernel.Laws
    ```
  * **Theorems** (mirroring `Laws/Deposit.lean`):

    1. **`totalSupply_after_depositWithFee`**:
       ```
       TotalSupply (step_impl s (depositWithFee r rec pool uA pA d)) r =
         TotalSupply s r + uA + pA
       ```
       Proof sketch: two applications of `totalSupply_setBalance` +
       `omega`.  Case split on `rec = pool` is unnecessary because
       both telescopes collapse to the same arithmetic identity
       when omega is given both equations.
    2. **`depositWithFee_other_resource_untouched`**:  at any
       `r' ≠ r`, the per-resource map is unchanged.  Proof: two
       applications of `RBMap.find?_insert_other`.
    3. **`depositWithFee_recipient_credited`**:
       `getBalance (step_impl s _) r recipient = getBalance s r recipient + userAmount`
       when `recipient ≠ poolActor`.  (The general case is more
       subtle and lives in (5).)
    4. **`depositWithFee_pool_credited`**:
       `getBalance (step_impl s _) r poolActor = getBalance s r poolActor + poolAmount`
       when `recipient ≠ poolActor`.
    5. **`depositWithFee_self_credit_collapses`**:
       when `recipient = poolActor`,
       `getBalance (step_impl s _) r recipient = getBalance s r recipient + userAmount + poolAmount`.
    6. **`depositWithFee_other_actor_untouched`**:  for any
       `a ∉ {recipient, poolActor}`,
       `getBalance (step_impl s _) r a = getBalance s r a`.
    7. **`depositWithFee_isMonotonic`** instance.
    8. **`depositWithFee_localTo`** instance for `[r]`.
    9. **`depositWithFee_freezePreserving`** theorem for any
       `S ∌ r`.
    10. **`depositWithFee_not_conservative`** witness (when at
       least one of `userAmount, poolAmount` is positive).
  * **Mathematical-soundness double-check.**
    Suppose `recipient = poolActor = a`.  Pre-state balance at `a`
    is `v`.  After step 1: `v + userAmount`.  After step 2 (which
    re-reads): `(v + userAmount) + poolAmount`.  Total supply
    delta: `((v + userAmount) + poolAmount) - v = userAmount +
    poolAmount`.  ✓.
    Suppose `recipient ≠ poolActor`.  Pre-state balances `vᵣ, vₚ`.
    After step 1: `vᵣ → vᵣ + userAmount`, `vₚ` unchanged.
    After step 2: `vₚ → vₚ + poolAmount`.  Total supply delta:
    `userAmount + poolAmount`.  ✓.
  * **Lex re-expression.**  Mirrors `Laws/Deposit.lean:86-103`
    with `lex_action_index 19` and the same five satisfies-tags
    (`monotonic, «local», freeze_preserving, nonce_advances,
    registry_preserving`).
  * **Tests.**  ~30 cases covering all theorems plus edge cases
    (`recipient = poolActor`, `userAmount = 0`, `poolAmount = 0`,
    both zero, both maximal `Amount`).
  * **Acceptance criteria.**  One reviewer; `lake build LegalKernel.
    Laws.DepositWithFee` green; `lake exe lex_lint` green.
  * **Dependencies.**  GP.0.3 (index 19 reserved), GP.1.6 (encoding
    plumbing for related types — not strictly required for the law
    itself, but the test suite uses it).
  * **Estimated effort.**  ~6 hours (modelled after `Laws/Deposit.
    lean`, which is ~270 lines).

#### WU GP.2.2: `Laws/TopUpActionBudget.lean`

  * **Goal.**  Define `topUpActionBudget` and prove the classification
    theorems.
  * **File:** `LegalKernel/Laws/TopUpActionBudget.lean` (new).
  * **Deliverables.**

    ```lean
    namespace LegalKernel.Laws

    /-- User-initiated top-up of action budget.  The kernel-level
        effect is **only** a balance transfer: `gasAmount` flows
        from the signer `a` to `poolActor` under `gasResource`.
        The matching budget mutation (incrementing `a`'s budget
        by `budgetIncrement`) happens at the admission layer
        (`SignedAction`), NOT at the kernel `step_impl` level.

        This separation keeps the kernel TCB unchanged: every
        kernel-level invariant about `step_impl` continues to
        depend only on `State`, not `ExtendedState`.  The
        admission-layer side of `topUpActionBudget` is proved
        separately (WU GP.3.3).

        Kernel precondition: `getBalance s r a ≥ gasAmount`.
        Conservation at `r`: this is a transfer-shape law — it
        moves `gasAmount` from `a` to `poolActor` without minting
        or burning.  Hence `IsConservative`. -/
    def topUpActionBudget (a : ActorId) (gasResource : ResourceId)
        (gasAmount : Amount) (_budgetIncrement : Nat)
        (poolActor : ActorId) : Transition where
      pre        := fun s => getBalance s gasResource a ≥ gasAmount
      decPre     := fun _ => inferInstance
      apply_impl := fun s =>
        let s1 := setBalance s gasResource a
                    (getBalance s gasResource a - gasAmount)
        setBalance s1 gasResource poolActor
          (getBalance s1 gasResource poolActor + gasAmount)

    end LegalKernel.Laws
    ```
  * **Theorems.**
    1. **`totalSupply_after_topUpActionBudget`**:
       ```
       TotalSupply (step_impl s (topUpActionBudget a r gA bI pA)) r =
         TotalSupply s r
       ```
       (conservation at the gas resource).
    2. **`topUpActionBudget_other_resource_untouched`**.
    3. **`topUpActionBudget_signer_debited`** when `a ≠ poolActor`.
    4. **`topUpActionBudget_pool_credited`** when `a ≠ poolActor`.
    5. **`topUpActionBudget_self_topup_is_noop`** when `a = poolActor`:
       *(this is a corner case — a user topping up THEIR OWN pool
       slot does nothing balance-wise; mathematically the law's
       apply_impl debits then credits the same slot, net zero;
       this is provable and worth pinning.)*

       *Author's mathematical check:* if `a = poolActor`, then
       step 1 debits slot `a` by `gasAmount` (assuming `pre` holds,
       so `getBalance s r a ≥ gasAmount`); step 2 reads from the
       post-step-1 state, where `getBalance s1 r poolActor =
       getBalance s r a - gasAmount`.  Step 2 sets it to
       `(getBalance s r a - gasAmount) + gasAmount = getBalance s
       r a`.  Net: the balance at slot `a` is restored.  ✓
       (relies on `Nat` truncated subtraction being non-trivial,
       which the precondition ensures.)
    6. **`topUpActionBudget_other_actor_untouched`** for
       `a' ∉ {a, poolActor}`.
    7. **`topUpActionBudget_isConservative`** instance.
    8. **`topUpActionBudget_isMonotonic`** instance (via
       `monotonic_of_conservative`).
    9. **`topUpActionBudget_localTo`** instance for
       `[gasResource]`.
    10. **`topUpActionBudget_freezePreserving`** theorem for
       `S ∌ gasResource`.
  * **Mathematical-soundness double-check.**  This law is exactly
    the existing `transfer` law (`Laws/Transfer.lean:60-71`)
    re-parameterised with named participants — `a → poolActor`,
    fixed resource = `gasResource`.  Every theorem follows from
    the corresponding `transfer` theorem by parameter substitution.
    The author should be able to import `Laws.Transfer` and derive
    each theorem in a one-line application.

    *Caveat:* `transfer` (`Laws/Transfer.lean:283-290`) is a
    `class IsConservative` instance with a specific shape; replicating
    that exactly may require a fresh proof rather than parameter
    forwarding, depending on how the original is bound.  Estimate
    accordingly.
  * **Lex re-expression.**  `lex_action_index 20`; satisfies
    `conservative, monotonic, «local», freeze_preserving,
    nonce_advances, registry_preserving`.
  * **Tests.**  ~25 cases including all theorems + the
    self-topup corner case + insufficient-balance rejection.
  * **Acceptance criteria.**  One reviewer; `lake build` green;
    `lake exe lex_lint` green.
  * **Dependencies.**  GP.0.3 (index 20 reserved), GP.1.6 (only
    for cross-file consistency in tests).
  * **Estimated effort.**  ~6 hours.

#### WU GP.2.3: Action-layer integration

  * **Goal.**  Extend the `Action` inductive with the two new
    constructors and update the existing dispatch / encoding /
    compile machinery to cover them.
  * **Files:**
    * `LegalKernel/Authority/Action.lean` (extend the `Action`
      inductive with constructors 19 and 20).
    * `LegalKernel/Encoding/Action.lean` (encode/decode + injectivity
      extension).
    * `LegalKernel/Events/Types.lean` (add the three new event
      variants 16/17/18).
    * `LegalKernel/Events/Extract.lean` (wire `extractEvents` to
      emit the new events).
  * **Deliverables.**
    * Action inductive extension:
      ```lean
      inductive Action where
        | ...  -- existing 0..18
        | depositWithFee (resource : ResourceId) (recipient : ActorId)
                         (poolActor : ActorId) (userAmount : Amount)
                         (poolAmount : Amount) (depositId : Bridge.DepositId)
        | topUpActionBudget (gasResource : ResourceId)
                            (gasAmount : Amount) (budgetIncrement : Nat)
                            (poolActor : ActorId)
      ```
      Note that `topUpActionBudget` does NOT carry the signer as a
      field; the signer is captured by the enclosing `SignedAction`.
    * AR.5 / AR.6 regression-pin update to cover indices 19, 20.
    * Updated `Action.compile_injective` proof (extension of an
      existing exhaustive case-analysis).
    * Updated `kernelOnlyApply`'s exhaustive match (AR.17).
  * **Theorems.**
    * `Action.compile_injective` re-extended (mechanical).
    * `Action.tag_depositWithFee_eq_19` (regression pin).
    * `Action.tag_topUpActionBudget_eq_20` (regression pin).
  * **Tests.**  20 cases covering the two new constructors'
    encode/decode round-trip, injectivity, tag pinning, and that
    the existing 0..18 constructors are unaffected.
  * **Acceptance criteria.**  One reviewer (this is a non-TCB
    change; constructor-index additions are append-only and have
    a well-trodden review path); `lake build` green; `lake exe
    naming_audit` green; `lake exe lex_lint` green; `lake exe
    lex_codegen --check` green.
  * **Dependencies.**  GP.2.1, GP.2.2.
  * **Estimated effort.**  ~6 hours.

---

### Phase GP.3 — Admission pipeline integration

This phase wires `ActorBudget` into the `SignedAction` admission
pipeline.  The key principle is **layered enforcement**: the kernel's
`step_impl` is unchanged; budget consumption happens at the same
admission layer that already houses nonce / signature / local-policy
checks.

**v1.4 sub-WU subdivision.**  Phase GP.3 touches
`Authority/SignedAction.lean` — a high-criticality file housing
the `nonce_uniqueness` and `replay_impossible` theorems.  Even
though it's not in the TCB-core file list, modifications here
trigger the two-reviewer rule.  The sub-WU breakdown below makes
each change small enough to review thoroughly:

| Sub-WU      | Scope                                                                              | Effort (h) | Reviewers | Files (planned → actual)               |
| ----------- | ---------------------------------------------------------------------------------- | ---------- | --------- | -------------------------------------- |
| GP.3.1.a    | `BudgetPolicy` inductive type definition + smart-constructor                       | 2          | 1         | `Authority/Nonce.lean` (canonical home of `ExtendedState`) |
| GP.3.1.b    | `ExtendedState` struct extension (add `epochBudgets`, `budgetPolicy` fields)       | 1          | 1         | `Authority/Nonce.lean`                 |
| GP.3.1.c    | Genesis defaults (`BudgetPolicy.bounded 0 1 0`; empty `EpochBudgetState`)         | 1          | 1         | `Authority/Nonce.lean`                 |
| GP.3.1.d    | `BudgetPolicy` + `ActorBudget` encoder injectivity                                | 2          | 1         | `Encoding/State.lean`                  |
| **GP.3.1 total** |                                                                               | **6**      |           |                                        |
| GP.3.2.a    | `processSignedActionWithBudget` skeleton (no budget logic yet; legacy passthrough) | 1          | 1         | `Authority/SignedAction.lean`          |
| GP.3.2.b    | Budget gate (consume-only path, non-bridgeActor)                                   | 3          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.c    | bridgeActor exemption (per OQ-GP-6)                                                | 1          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.d    | Per-action budget-grant match (topUpActionBudget, depositWithFee, delegated)       | 3          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.e    | Theorem: `admission_consumes_budget_on_success`                                    | 2          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.f    | Theorem: `admission_rejected_when_budget_zero`                                     | 2          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.g    | Theorems: `depositWithFee_grants_budget`, `_budget_locality`, `bridgeActor_exempt` | 3          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.h    | Theorems: `topUpActionBudget_net_budget_change`, `admission_legacy_compat`         | 2          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.i    | Theorems: `replenishment_via_epoch_advance`, `admission_locality_in_budget`        | 2          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.j    | Theorems: `nonce_uniqueness_preserved`, `replay_impossible_preserved`              | 4          | 2         | `Authority/SignedAction.lean`          |
| GP.3.2.k    | Tests: 55 cases (admission behaviour + theorem regression pins)                    | 6          | 1         | `Authority/Test/SignedActionBudget.lean` |
| **GP.3.2 total** |                                                                               | **29**     |           |                                        |
| GP.3.3.a    | `kernelOnlyApply` extension: `depositWithFee` arm (variant 19)                     | 2          | 2         | `FaultProof/StepVMCoherence.lean`      |
| GP.3.3.b    | `kernelOnlyApply` extension: `topUpActionBudget` arm (variant 20)                  | 2          | 2         | `FaultProof/StepVMCoherence.lean`      |
| GP.3.3.c    | `kernelOnlyApply` extension: `topUpActionBudgetFor` arm (variant 21)               | 2          | 2         | `FaultProof/StepVMCoherence.lean`      |
| GP.3.3.d    | `kernelOnlyApply` extension: `ammSwap` arm (variant 22)                            | 2          | 2         | `FaultProof/StepVMCoherence.lean`      |
| GP.3.3.e    | `stepVMHash_<variant>_kind` rfl proofs for 19, 20, 21, 22                          | 2          | 2         | `FaultProof/StepVMCoherence.lean`      |
| GP.3.3.f    | `recomputeCommitment_coherent_with_kernelOnlyApply` extension                      | 2          | 2         | `FaultProof/StepVMCoherence.lean`      |
| **GP.3.3 total** |                                                                               | **12**     |           |                                        |
| GP.3.4.a    | `LocalPolicyClause.allowTopUpFrom` variant + decidability instance                 | 2          | 2         | `Authority/LocalPolicy.lean`           |
| GP.3.4.b    | `positivelyGatedActionOk` admission helper (v1.4 default-deny semantics)           | 3          | 2         | `Authority/LocalPolicy.lean`           |
| GP.3.4.c    | `Action.topUpActionBudgetFor` constructor at frozen index 21                       | 2          | 2         | `Authority/Action.lean`                |
| GP.3.4.d    | `Laws/TopUpActionBudgetFor.lean` definition                                        | 2          | 1         | `Laws/TopUpActionBudgetFor.lean`       |
| GP.3.4.e    | Theorem ladder (8 classification theorems via parameter substitution from transfer)| 4          | 2         | `Laws/TopUpActionBudgetFor.lean`       |
| GP.3.4.f    | Admission-layer consent check integration                                          | 2          | 2         | `Authority/SignedAction.lean`          |
| GP.3.4.g    | Theorems: `delegatedTopUp_grants_budget`, `_requires_allowTopUpFrom`, `_signer_balance_debited` | 3 | 2 | `Authority/SignedAction.lean`          |
| GP.3.4.h    | Tests: 30 cases (consent positive / negative, revocation, multi-delegate)          | 4          | 1         | `Authority/Test/DelegatedTopup.lean`   |
| **GP.3.4 total** |                                                                               | **22**     |           |                                        |
| **Phase GP.3 total post-subdivision** |                                                            | **~69**    |           |                                        |

**Two-reviewer scope.**  Sub-WUs that touch
`Authority/SignedAction.lean` directly (b, c, d, e, f, g, h, i, j
in GP.3.2; f, g in GP.3.4; and any GP.3.3 work) require two
reviewers per the CODEOWNERS / §13.6 discipline.  Sub-WUs that
only add new files (GP.3.4.d, GP.3.4.h, GP.3.4.a — new file)
can use the one-reviewer path.

#### WU GP.3.1: `BudgetPolicy` configuration field on `ExtendedState`

> Implementation note (2026-05-21): `BudgetPolicy` and the
> `ExtendedState.budgetPolicy` default were landed in
> `LegalKernel/Authority/Nonce.lean` (current canonical
> `ExtendedState` definition location), with bounded-mode smart
> constructor `BudgetPolicy.mkBounded` enforcing `actionCost ≥ 1`.
>
> Implementation note (2026-05-22, GP.3.1.d closure):
> `actorBudget_roundtrip`, `actorBudget_encode_injective`,
> `budgetPolicy_bounded_roundtrip`, and
> `budgetPolicy_encode_injective` ship in
> `LegalKernel/Encoding/State.lean` immediately downstream of the
> `BudgetPolicy.encode` / `ActorBudget.encode` definitions.  These
> are the per-field encoder-injectivity theorems the GP.3.1.d
> deliverable calls for; their proofs route through `nat_roundtrip`
> (`Encoding/Encodable.lean`) plus `Except.ok.inj`.  `#print axioms`
> on each new theorem returns `[propext, Quot.sound]` — a strict
> subset of the canonical three `[propext, Classical.choice,
> Quot.sound]`, so the GP.3.1.d additions introduce no new
> axiomatic dependencies beyond what the encoding ladder already
> required.  `ExtendedState.encode` itself remains too coarse to
> admit a unified structural-equality conclusion (the embedded
> `TreeMap`-backed sub-states require the extensional `Equiv`-
> shaped lemmas of the EI.8 ladder in
> `LegalKernel/FaultProof/Commit.lean`); a future GP work-unit
> may lift the EI.8 chain to include `epochBudgets` and
> `budgetPolicy` once `commitExtendedState` is extended to bind
> them.  Value-level coverage: `actorBudgetEncodeDistinguishesFields`,
> `budgetPolicyEncodeDistinguishesFields`, and
> `extendedStateEncodeSensitiveToBudgetFields` in
> `LegalKernel/Test/Encoding/State.lean` verify the encoder
> contrapositive (distinct values → distinct bytes), guarding
> against future encoder-collapse regressions that would not
> trip the theorem-level type-checks.

  * **Goal.**  Extend `ExtendedState` with a per-deployment
    `BudgetPolicy` and the `EpochBudgetState` field.
  * **Files:**
    * `LegalKernel/Runtime/Replay.lean` (the canonical
      `ExtendedState` location; extend the structure).
    * `LegalKernel/Encoding/State.lean` (extend the encoder /
      decoder; update `State.encode_injective` proof).
  * **Deliverables.**

    ```lean
    /-- Per-deployment budget enforcement mode. -/
    inductive BudgetPolicy
      /-- Legacy / migration mode: no budget enforcement.  Every
          action admitted regardless of budget state.  Equivalent
          to the pre-Workstream-GP behaviour. -/
      /-- Bounded mode: every action consumes one budget unit;
          actor with insufficient budget at the current epoch is
          rejected. -/
      | bounded (freeTier : Nat) (epochDurationSeconds : Nat)
      deriving Repr, DecidableEq

    structure ExtendedState where
      kernel       : State
      bridge       : BridgeState
      epochBudgets : EpochBudgetState     -- NEW
      budgetPolicy : BudgetPolicy         -- NEW
      -- (other existing fields)
    ```
  * **Theorems.**
    * `ExtendedState.encode_injective` extended to cover the
      new fields (mechanical Σ-encoding extension; mirrors
      EI.8.b's pattern in `FaultProof/Commit.lean`).
    * `ExtendedState.genesis_has_bounded_budget_policy` (genesis
      defaults to bounded mode with conservative parameters).
  * **Tests.**  15 cases including genesis defaults, policy
    switching, encode/decode round-trip.
  * **Acceptance criteria.**  One reviewer; `lake exe count_sorries`
    green; `lake exe naming_audit` green.
  * **Dependencies.**  GP.1.5, GP.1.6.
  * **Estimated effort.**  ~5 hours.

#### WU GP.3.2: `Authority/SignedAction.lean` admission gate

> **Status: complete (2026-05-22).**  All ten admission-gate
> theorems land in `LegalKernel/Authority/SignedAction.lean`
> (§15E v1.0):
>
>   * `admission_consumes_budget_on_success` — every non-bridge,
>     non-deposit, non-topup admitted action reduces the signer's
>     `currentBudget` by `actionCost`.
>   * `admission_rejected_when_budget_zero` — non-bridge actor
>     with `currentBudget < actionCost` is rejected at the gate.
>   * `bridgeActor_budget_exempt` — every bridgeActor-signed
>     admitted action leaves bridgeActor's own budget unchanged
>     (per OQ-GP-6).
>   * `depositWithFee_grants_budget` — successful depositWithFee
>     credits recipient's budget by exactly `budgetGrant`.
>   * `depositWithFee_budget_locality` — successful depositWithFee
>     leaves every non-recipient (and non-consuming-signer) actor's
>     budget unchanged.
>   * `topUpActionBudget_net_budget_change` — successful
>     topUpActionBudget produces net change of
>     `budgetIncrement - actionCost` on the signer's slot.
>   * `admission_locality_in_budget` — non-deposit non-topup
>     admission only mutates the signer's budget slot.
>   * `replenishment_via_epoch_advance` — actor with
>     `lastSeenEpoch < currentEpoch` sees `currentBudget ≥ freeTier`
>     (epoch boundary auto-replenishes).
>   * `nonce_uniqueness_preserved` — `nonce_uniqueness` carries
>     through the budget gate (gate is downstream of nonce check).
>   * `replay_impossible_preserved` — `replay_impossible` carries
>     through the budget gate (post-state nonce strictly greater
>     than pre-state's).
>
> Body of `apply_admissible_with_budget` includes (a) **two named
> action-specific signer-correlation safety gates at the head**,
> each rejecting one or more critical-severity DoS amplifiers
> uncovered during the five-round adversarial audit:
>
>   **Gate 1: `topUpActionBudget_gasCheck`** (four conjuncts on the
>   topUpActionBudget signer):
>   - The `signer ≠ Bridge.bridgeActor` conjunct defends against
>     the **bridgeActor self-topup attack** (round 3 — defense in
>     depth): without it, the bridgeActor's consume-exemption
>     combined with the budget-grant arm would credit
>     `budgetIncrement` budget to bridgeActor's own slot for free
>     (skipping the per-action 1-budget cost).  The production
>     `bridgePolicy` already rejects this at the authorization
>     layer (`bridgeAuthorizedAction` does not list
>     `topUpActionBudget`), but under `unrestricted` (tests / dev)
>     the gate-level rejection is the only line of defense.
>   - The `signer ≠ poolActor` conjunct defends against the
>     **self-pool attack** (round 4): `Laws.topUpActionBudget`'s
>     `apply_impl` is the two-step `setBalance s gr signer
>     (balance - ga); setBalance s gr pa (balance' + ga)`.  When
>     `pa = signer`, the second `setBalance` re-credits the signer
>     the same gas just debited — net zero kernel-state effect on
>     the signer's balance, yet the budget arm STILL credits
>     `budgetIncrement` budget.  Without this conjunct, a user
>     could sign `topUpActionBudget gr ga huge signer` repeatedly
>     to accumulate unbounded free budget.
>   - The `gasAmount > 0` conjunct defends against the
>     **zero-gas attack** (round 2): signing
>     `topUpActionBudget gr 0 huge pa` would otherwise pass the
>     `getBalance ≥ 0` check trivially, the kernel step is a no-op
>     (debit 0 / credit 0), and the budget grant would still credit
>     `huge` for free.
>   - The `getBalance ≥ gasAmount` conjunct defends against the
>     **insufficient-gas attack** (round 1): signing
>     `topUpActionBudget gr (balance+1) bi pa` would otherwise pass
>     the (old, vacuous) `AdmissibleWith`'s compile-transition
>     precondition, the kernel step would safely no-op via
>     `step_impl`'s underflow guard (gas not debited), and the
>     budget grant would still credit `bi` budget for free.
>
>   **Gate 2: `depositWithFee_signerCheck`** (single conjunct on the
>   depositWithFee signer):
>   - The `signer = Bridge.bridgeActor` conjunct defends against the
>     **non-bridge depositWithFee attack** (round 5): a
>     non-bridgeActor signer who could sign a depositWithFee action
>     would have the kernel step credit `userAmount + poolAmount` to
>     the recipient's balance AND have the budget-grant arm credit
>     `budgetGrant` to the recipient's budget — a free balance + free
>     budget injection on top of the existing four-vector free-budget
>     hierarchy.  In production the `bridgePolicy` admission layer
>     rejects this earlier (`bridgeAuthorizedAction` admits
>     depositWithFee only from bridgeActor), but under `unrestricted`
>     (tests / dev) and to future-proof against `bridgePolicy`
>     extensions, the gate hard-codes the requirement that
>     depositWithFee MUST be signed by bridgeActor.
>
> (b) bridgeActor exemption per OQ-GP-6 (applies only to non-topUp
> non-depositWithFee-by-non-bridge actions; topUp signed by
> bridgeActor is rejected by gate 1's first conjunct; non-bridge
> depositWithFee is rejected by gate 2 entirely), (c) consume step
> on non-bridge signers, (d) per-action budget-grant arm for
> `depositWithFee` (credits recipient) and `topUpActionBudget`
> (credits signer).  The bridge-aware mirror in
> `LegalKernel/Bridge/Admissible.lean`'s
> `apply_bridge_admissible_with_budget` carries the same two-gate +
> exemption + budget-grant structure for production runtime paths.
>
> `processSignedActionWith` (`LegalKernel/Runtime/Loop.lean`) and
> `processPure` both thread through `apply_bridge_admissible_with_budget`,
> so production IO and pure test paths see identical budget
> behaviour.  The replay-tool entries (`replayStepWith` /
> `replayLoopWith` / `replayFromSeedWith`) in
> `LegalKernel/Runtime/Replay.lean` are wired to the budget gate;
> the only remaining `apply_admissible` (non-budget-gated) call
> sites are dispute-pipeline helpers and pure-proof scaffolding
> below the admission-layer boundary.
>
> Value-level coverage in
> `LegalKernel/Test/Authority/SignedActionBudget.lean` (41 cases,
> suite name `authority-signed-budget`): all ten theorems are
> exercised at the value level (including topUpActionBudget
> insufficient-gas REJECTION, zero-gas REJECTION,
> bridgeActor-topup REJECTION, self-pool REJECTION, non-bridge
> depositWithFee REJECTION, self-topup chain, cross-actor budget
> isolation, genesis-default rejection) plus term-level API
> stability pins for every theorem.  Each of the five attack
> vectors discovered during the adversarial audit has a
> matched-pair kernel-only + bridge-aware mirror regression
> (`topupInsufficientGasRejected` +
> `bridgeAdmissibleTopupInsufficientGasRejected`,
> `topupZeroGasRejected` +
> `bridgeAdmissibleTopupZeroGasRejected`,
> `topupByBridgeActorRejected` +
> `bridgeAdmissibleTopupByBridgeActorRejected`,
> `topupSelfPoolRejected` +
> `bridgeAdmissibleTopupSelfPoolRejected`,
> `depositWithFeeNonBridgeSignerRejected` +
> `bridgeAdmissibleDepositWithFeeNonBridgeSignerRejected`).
> Additional production-path coverage in
> `LegalKernel/Test/Runtime/LoopHappyPath.lean`
> (`budgetGateFirstActionSucceeds` /
> `budgetGateExhaustionRejects` / `budgetGateOtherActorUnaffected` /
> `genesisDefaultDeniesAdmission`).
>
> **GP.2.3 sibling closure (2026-05-22).**  The `Action` inductive
> now has frozen constructors at indices 19 (`depositWithFee`) and
> 20 (`topUpActionBudget`), with byte-stable CBE encoding (round-
> trip + injectivity proven), `Action.tag` regression pins, new
> Event variants 16 / 17 / 18 (`depositWithFeeCredited` /
> `actionBudgetTopUp` / `gasPoolClaim`), and `extractEvents`
> coverage.  `apply_admissible_with` and `kernelOnlyApply`
> (`Disputes/Evidence.lean`) BOTH use a signer-aware kernel step
> for `topUpActionBudget` (via `Laws.topUpActionBudget st.signer
> ...`), wrapped in `step_impl` for insufficient-gas safety; both
> functions agree definitionally (preserving the dispute pipeline's
> `apply_admissible_with_eq_kernelOnlyApply` equivalence).  Plus
> `RegistryPreserving` instances for both new constructors.

  * **Goal.**  Add the budget-consumption layer to the existing
    `processSignedAction` admission flow.
  * **File:** `LegalKernel/Authority/SignedAction.lean` (modified).
  * **Deliverables.**

    ```lean
    /-- Admission pipeline with the budget gate.  Existing checks
        (signature, nonce, local policy, bridge admissibility)
        retain their current order; the budget check is appended
        last because it is the most likely cause of rejection in
        steady state and we want the cheaper checks to fail first
        for performance.

        Returns:
        * `some es'` if the action is admissible AND the signer's
          budget is sufficient (under bounded policy) OR the
          policy is unlimited.
        * `none` otherwise.

        The budget MUTATION happens atomically with `step_impl`
        from the caller's perspective: if `step_impl` is invoked,
        the budget has been decremented; if `none` is returned,
        no state changes.

        For `topUpActionBudget` specifically: the budget mutation
        is a *consume-then-increment* pair, applied in two steps:
        (a) consume 1 unit (the cost of executing the topUp
        action itself); (b) increment by `budgetIncrement` (the
        purchased amount).  The order matters in the degenerate
        case where the signer has exactly 0 budget — they cannot
        top up while at zero budget unless `freeTier ≥ 1`.
    -/
    def processSignedActionWithBudget
        (es : ExtendedState) (sa : SignedAction) (now : Nat)
        (verify : VerifyFn) (d : ByteArray) :
        Option ExtendedState := do
      -- Existing checks (verbatim from current processSignedAction):
      guard (verify sa.signed sa.signer sa.signature)
      guard (nonceMatches es.kernel sa)
      guard (localPolicyOk es.kernel sa)
      guard (bridgeAdmissibleWith es.bridge d sa)
      -- NEW: budget gate.  Bridge-signed actions (signer =
      -- bridgeActor) are exempted per OQ-GP-6.  This keeps
      -- depositWithFee admissible even when bridgeActor's
      -- budget would otherwise be empty (bridgeActor's
      -- depositWithFee actions are L1-gas-gated upstream
      -- anyway, so a separate budget gate would be redundant).
      let actor := sa.signer
      let cost  := 1  -- v1: every action costs 1 unit
      let ebs'  ← match es.budgetPolicy with
                  | .unlimited => some es.epochBudgets
                  | .bounded ft _ =>
                    if actor = bridgeActor then
                      some es.epochBudgets  -- exempt
                    else
                      es.epochBudgets.consume actor now ft cost
      -- Apply step_impl.
      --
      -- v1.5 clarification: `Action.toTransition` is the
      -- existing Knomosis function that constructs the
      -- `Transition` from an Action payload.  For actions
      -- whose law depends on the signer (e.g.,
      -- `topUpActionBudget`'s `a` parameter,
      -- `topUpActionBudgetFor`'s `signer` parameter), the
      -- toTransition function takes the signer from
      -- `sa.signer` and threads it into the law's parameter
      -- list.  This is the existing pattern for `transfer`
      -- (whose `sender` field must match `sa.signer`) and
      -- carries forward to v1.3+ actions.  Specifically:
      --   * `Action.transfer (r, sender, receiver, amount)`
      --     → constructs `transfer r sender receiver amount`
      --     with admission verifying `sender == sa.signer`.
      --   * `Action.topUpActionBudget (gasRes, amt, incr, pool)`
      --     → constructs `topUpActionBudget sa.signer gasRes
      --     amt incr pool` (signer comes from sa, not Action).
      --   * `Action.topUpActionBudgetFor (recipient, gasRes, amt,
      --     incr, pool)`
      --     → constructs `topUpActionBudgetFor recipient
      --     sa.signer gasRes amt incr pool` (recipient from
      --     Action, signer from sa).
      --   * `Action.ammSwap (fromR, toR, amtIn, amtOut, amm)`
      --     → constructs `ammSwap fromR toR amtIn amtOut amm`
      --     (signer not used in this law's apply_impl).
      -- The toTransition spec lives in `Authority/Action.lean`;
      -- v1.5's WU GP.2.3 extension covers the new variants.
      let kernel' := step_impl es.kernel (Action.toTransition sa.action sa.signer)
      -- Apply per-Action budget mutation AFTER the consume.
      -- Two cases produce budget increments:
      --   (a) topUpActionBudget: actor's own budget += budgetIncrement
      --   (b) depositWithFee:    recipient's budget += budgetGrant
      let ebs'' :=
        match sa.action with
        | Action.topUpActionBudget _ _ budgetIncrement _ =>
          match es.budgetPolicy with
          | .unlimited      => ebs'
          | .bounded ft _   => ebs'.topUp actor now ft budgetIncrement
        | Action.depositWithFee _ recipient _ _ _ budgetGrant _ =>
          match es.budgetPolicy with
          | .unlimited      => ebs'
          | .bounded ft _   => ebs'.topUp recipient now ft budgetGrant
        | _ => ebs'
      let bridge' := applyToBridgeState es.bridge sa
      some { kernel := kernel', bridge := bridge',
             epochBudgets := ebs'', budgetPolicy := es.budgetPolicy }
    ```

    **Mathematical-soundness double-check (author).**
    * The `bridgeActor` exemption is keyed on `signer`, not on
      action variant; this is correct because `bridgeActor` is
      the only authorised signer of `depositWithFee` (per
      `bridgePolicy_*` family — `Bridge/BridgeActor.lean:139-143`).
      A non-bridge actor cannot forge a `depositWithFee` signed
      action through this path.
    * In the `depositWithFee` arm: the budget is granted to
      `recipient` (read from the action payload), not to
      `actor = bridgeActor`.  This is the intended semantics.
    * The `topUp` is applied to `ebs'`, which is identical to
      `es.epochBudgets` in the `bridgeActor`-exempted path.
      So the recipient's budget after a deposit equals
      `(currentBudget es.epochBudgets recipient now ft) +
      budgetGrant` (via `currentBudget_after_topUp`).
    * The order matters: consume-then-topUp-then-credit ensures
      a bridgeActor cannot exhaust their own (exempt) budget
      before applying the recipient's budget grant — but since
      the consume is no-op for bridgeActor anyway, the order
      could be swapped without semantic change.  Maintaining the
      consume-first ordering for ALL admitted actions keeps the
      admission pipeline single-shape.
  * **Theorems.**

    1. **`admission_consumes_budget_on_success`**: every admitted
       SignedAction (non-`topUpActionBudget`, non-`depositWithFee`,
       non-bridgeActor-signed) under `bounded` policy reduces the
       signer's `currentBudget` by exactly 1.
    2. **`admission_rejected_when_budget_zero`**: under `bounded`
       policy, a non-bridge actor with `currentBudget = 0` cannot
       get a non-`topUpActionBudget` action admitted, regardless
       of signature / nonce.
    3. **`topUpActionBudget_net_budget_change`**: under `bounded`
       policy, a successfully admitted `topUpActionBudget` action
       with `budgetIncrement = k` produces a net budget change of
       `+k - 1` (one consumed by the action itself, `k` minted).
       Specifically, **the topUp succeeds iff `currentBudget ≥ 1`**
       — the new actor must have at least their free-tier worth.
    3'. **`depositWithFee_grants_budget`** (NEW v1.1): under
       `bounded` policy, a successfully admitted `depositWithFee`
       action with `budgetGrant = g` produces a net budget change
       of exactly `+g` at the *recipient's* slot (NOT the signer's
       slot).  The signer is `bridgeActor`, who is exempt from
       budget consumption; the recipient is read from the action
       payload.  Proof: applies `currentBudget_after_topUp` at
       `recipient` after the no-op consume on `bridgeActor`.
    3''. **`depositWithFee_budget_locality`** (NEW v1.1): a
       successfully admitted `depositWithFee` action does not
       change the budget of any actor other than `recipient`.
       Proof: applies `topUp_other_actor_unchanged` (GP.1.5).
    3'''. **`bridgeActor_budget_exempt`** (NEW v1.1): under
       `bounded` policy, every admitted bridgeActor-signed
       action leaves `bridgeActor`'s own budget slot unchanged.
       Defence-in-depth against the case where bridgeActor's
       budget is accidentally populated (e.g., a misconfigured
       deployment).
    4. **`admission_legacy_compat`**: under `unlimited` policy,
       `processSignedActionWithBudget` is byte-equivalent to the
       existing `processSignedAction` (the budget gate is a no-op).
    5. **`admission_locality_in_budget`**: an admitted non-deposit
       action by actor `a` does not change the budget of any other
       actor `a' ≠ a`.  (Deposits change the recipient's budget
       per theorem 3'; this theorem covers all other paths.)
    6. **`replenishment_via_epoch_advance`**: if the same actor
       attempts an action at `now+1` after exhausting budget at
       `now`, AND `now+1 > now`, AND `freeTier ≥ 1`, the action
       succeeds (epoch boundary auto-replenishes via `normalise`).
    7. **`nonce_uniqueness_preserved`**: the existing
       `nonce_uniqueness` theorem (`Authority/SignedAction.lean`,
       §8.5.2) continues to hold for `processSignedActionWithBudget`.
       (Proof: budget gate is downstream of nonce gate; rejection
       at budget gate does not change the nonce state.)
    8. **`replay_impossible_preserved`**: the existing
       `replay_impossible` theorem continues to hold.
  * **Mathematical-soundness double-check.**
    * Theorem 1 follows from `currentBudget_after_consume` (WU
      GP.1.5).
    * Theorem 3 follows from chaining `currentBudget_after_consume`
      (consume 1) and `currentBudget_after_topUp` (add `k`):
      `(B - 1) + k = B + k - 1` (truncated-Nat-subtraction-safe
      because `consume` only returns `some` when `B ≥ 1`).
    * Theorem 3' (`depositWithFee_grants_budget`) follows from
      the bridgeActor-exempt path: `consume` is a no-op for
      `bridgeActor`, so `ebs' = es.epochBudgets` exactly; then
      `topUp recipient now ft budgetGrant` applied to `ebs'`
      produces `currentBudget ebs'' recipient now ft =
      currentBudget es.epochBudgets recipient now ft + budgetGrant`
      via `currentBudget_after_topUp` (GP.1.5).
    * Theorem 3'' (`depositWithFee_budget_locality`) follows from
      `topUp_other_actor_unchanged` (GP.1.5).
    * Theorem 3''' (`bridgeActor_budget_exempt`) follows directly
      from the `if actor = bridgeActor then some es.epochBudgets`
      branch in the consume step.
    * Theorem 6 follows from `normalise_floors_at_freeTier` (WU
      GP.1.2).
    * Theorem 7 / 8 follow from the layering structure: the budget
      gate operates AFTER nonce verification and BEFORE any state
      mutation that the nonce-uniqueness theorem reasons about.
  * **Tests.**  ~55 cases (+10 vs v1.0 for the depositWithFee
    budget grant paths):
    * Happy-path: admit, consume, repeat until exhausted.
    * Exhausted-budget rejection (non-bridge actor).
    * Top-up restores budget.
    * Epoch boundary auto-replenishes.
    * Multiple actors don't interfere.
    * Legacy / unlimited policy bypasses everything.
    * `topUpActionBudget` self-topup (signer = poolActor).
    * Insufficient gas balance: `topUpActionBudget` rejected at
      the existing precondition step, before the budget gate runs.
    * **NEW v1.1:** `depositWithFee` with `budgetGrant = 0`:
      recipient gets balance credit, no budget effect.
    * **NEW v1.1:** `depositWithFee` with `budgetGrant > 0`:
      recipient's budget increases by exactly `budgetGrant`.
    * **NEW v1.1:** `depositWithFee` does NOT consume
      bridgeActor's budget (bridgeActor exemption).
    * **NEW v1.1:** `depositWithFee` to a previously-budget-
      exhausted actor restores their budget — they can act
      immediately in the same epoch.
    * **NEW v1.1:** Sequential deposits to the same recipient
      accumulate budget (`topUp` is additive).
    * **NEW v1.1:** Locality regression: depositWithFee to A
      does not change budget at B.
    * **NEW v1.1:** `MAX_BUDGET_PER_DEPOSIT` is applied at L1;
      L2 just receives the clamped `budgetGrant` — verify that
      L2 doesn't double-clamp (`topUp` simply adds, no clamp).
  * **Acceptance criteria.**  **Two reviewers** (this WU modifies
    `Authority/SignedAction.lean`, which while not in the TCB-core
    file list, is a high-criticality file housing
    `nonce_uniqueness` and `replay_impossible`); `lake exe
    count_sorries` green; `lake exe tcb_audit` green; full `lake
    test` green.
  * **Dependencies.**  GP.3.1, GP.2.3.
  * **Estimated effort.**  ~12 hours (proofs of theorems 7 / 8
    require careful rephrasing of the existing theorems to thread
    the budget-state argument through).

#### WU GP.3.3: `kernelOnlyApply` extension — **Complete**

  * **Goal.**  Update `LegalKernel/FaultProof/StepVMCoherence.lean`'s
    step-VM dispatcher and `LegalKernel/Disputes/Evidence.lean`'s
    `kernelOnlyApply` exhaustive match to handle the two new
    constructors at the L1 step VM level.

    *Author's note.*  The plan's original phrasing localised
    `kernelOnlyApply` to `StepVMCoherence.lean`, but the function
    actually lives in `Disputes/Evidence.lean`.  The landed work
    touches both files (matching the de-facto module layout).
  * **Files:** `LegalKernel/FaultProof/StepVMCoherence.lean`,
    `LegalKernel/Disputes/Evidence.lean`,
    `LegalKernel/FaultProof/PerVariantCoherence.lean`,
    `LegalKernel/Test/Bridge/CrossCheck/StepVM.lean`,
    `solidity/test/CrossCheck/StepVM.t.sol`.
  * **Deliverables.**
    * Two new exhaustive arms in `kernelOnlyApply` matching
      `depositWithFee` and `topUpActionBudget` (already landed
      under GP.2.3's `kernelOnlyApply` audit-paranoia gate; the
      arms are now exercised in the test corpus).
    * `stepVMHash_<variant>_kind` for variants 19, 20 — two
      `rfl` proofs in `StepVMCoherence.lean`.
    * `step_vm_dispatch_well_typed` remains `rfl` (the new arms
      are uniformly dispatched via `actionKindByte` +
      `stepVMHash`, so no proof extension was needed).
    * `crosscheck-step-vm` fixture corpus header counters
      updated from 218 → 238 entries; new `countDepositWithFee`
      and `countTopUpActionBudget` fields added to the JSON
      header.
    * `coherence_depositWithFee` /
      `coherence_topUpActionBudget` per-variant specialisations
      added to `PerVariantCoherence.lean`; matching
      `cellwrites_depositWithFee` / `cellwrites_topUpActionBudget`
      shipped alongside.
    * Solidity-side `StepVM.t.sol` extended: corpus size 218 →
      238, `actionKindByte` range 0..18 → 0..20, happy count
      134 → 146, adversarial count 84 → 92, `variantKeys` array
      from 17 → 19 entries.
  * **Theorems shipped.**
    * `stepVMHash_depositWithFee_kind` (rfl): dispatcher reduces
      to the two-arm credit pattern matching
      `Laws.depositWithFee`'s sequential `setBalance` semantics.
    * `stepVMHash_topUpActionBudget_kind` (rfl): dispatcher
      reduces to the debit-then-credit pattern; defends the
      `signer = poolActor` self-pool corner via an explicit
      no-op branch.
    * `coherence_depositWithFee` / `cellwrites_depositWithFee`:
      specialisations of the universal #225 / #251 lemmas to
      the new constructor.
    * `coherence_topUpActionBudget` /
      `cellwrites_topUpActionBudget`: same for the second
      constructor.
    * `recomputeCommitment_coherent_with_kernelOnlyApply`
      retained its universal-arm form (it operates on any
      `SignedAction` carrier and unfolds to the same
      `commitExtendedState ∘ kernelOnlyApply` definition); the
      per-variant specialisations above are the audit-aid
      access points for the two new constructors.
  * **Tests.**  29 new cases across:
    * `faultproof-stepvm-coherence` (+12): per-variant
      `actionKindByte` pins, value-level dispatch tests for
      kinds 19 / 20 (distinct, self-credit / self-pool defended,
      `budgetGrant` / `budgetIncrement` admission-only design
      property), plus four end-to-end `stepVMHashFromAction`
      production-path tests that verify the full
      `commitExtendedState` + `actionFieldsForL1` +
      `buildObserverCellProofs` + dispatcher chain reads the
      correct pre-balances from the observer-built bundle
      (distinct, self-credit, topUp, zero/absent-pre-balance).
    * `faultproof-pervariant-coherence` (+4): API-stability
      pins for the four new per-variant theorems.
    * `faultproof-coherence` (+9): value-level
      `kernelOnlyApply` tests on the new variants — balance
      mutation, nonce advance, resource-locality, self-credit
      collapsing, and #225 universal-lemma agreement.
    * `faultproof-terminate-bundle` (+2): the off-chain
      observer's terminate-move payload builder for the new
      variants — `actionKind`, L1 field-layout width,
      `claimedPostCommit = stepVMHashFromAction`, and cell-proof
      bundle validity against the pre-state commit.
    * `crosscheck-step-vm` (+2): per-variant fixture-count
      pins; the corpus-size pin is updated from 218 → 238.
  * **Acceptance criteria met.**  `lake build` green; `lake test`
    green (2382 cases); all seven audit binaries
    (`count_sorries`, `tcb_audit`, `stub_audit`, `naming_audit`,
    `deferral_audit`, `lex_lint`, `lex_codegen --check`) green;
    Solidity `StepVMCrossCheck` suite green (9 passed, 1
    skipped under FNV-1a-64 fallback).
  * **Dependencies satisfied.**  GP.2.3 (Action layer integration
    extended to indices 19 / 20).
  * **Effort.**  ~6 hours actual (plan estimate: ~10 hours).
    The shorter actual effort reflects that several
    deliverables were already partially landed under GP.2.3
    (kernelOnlyApply arms, stepVMHash dispatch arms, Solidity
    step functions); GP.3.3 closed the remaining audit aid,
    cross-stack corpus extension, and Solidity-side test
    updates.

#### WU GP.3.4: Delegated `topUpActionBudgetFor` (v1.3) — **Complete**

> **Status: complete (Lean side).**  The `allowTopUpFrom` positive
> clause (frozen clause index 3, `MAX_DELEGATES_PER_ALLOW = 64`),
> the `Action.topUpActionBudgetFor` constructor (frozen index 21),
> the `Laws.topUpActionBudgetFor` law + full §4.11 classification
> ladder, the default-deny recipient-consent gate
> (`topUpActionBudgetFor_gate` + `delegatedTopUpConsentBool` /
> `delegatedTopUpConsentBool_iff`) wired into both the kernel-only
> and bridge-aware budget entries, the recipient-targeted budget
> grant, the three headline admission theorems
> (`delegatedTopUp_grants_budget_to_recipient`,
> `delegatedTopUp_requires_allowTopUpFrom`,
> `delegatedTopUp_signer_balance_debited`,
> `delegatedTopUp_signer_budget_consumed`,
> `delegatedTopUp_budget_locality`), the
> `Event.delegatedActionBudgetTopUp` semantic event (frozen event
> index 19), the variant-21 cell-write / commit coherence theorems
> (`cellwrites_topUpActionBudgetFor`, `coherence_topUpActionBudgetFor`),
> and the 56-case `authority-delegated-topup` suite all landed.  The
> CBE codecs, `Action.tag`, `kernelOnlyApply`, the dispute-pipeline
> equivalence, and the step-VM static cell declarations
> (`actionKindByte` = 21, `actionFieldsForL1`, `readOnlyCells` /
> `writeCells`) were extended append-only.
>
> **Production-path coverage (GP.3.2 completion).**  Every kernel-only
> GP.3.2 *and* GP.3.4 budget theorem now has a bridge-aware (`*_bridge`)
> mirror in `Bridge/Admissible.lean` pinning the SAME property on the
> production entry `apply_bridge_admissible_with_budget` (which the
> runtime actually uses).  All are lifted DRY through one structural
> lemma — `apply_bridge_admissible_with_budget_epochBudgets_eq` — proving
> the bridge budget gate equals the kernel budget gate up to the single
> `bridge`-field stamp; this closes the bridge-side coverage GP.3.2 had
> left to value-level tests only.
>
> **Closed by GP.5.3:** the L1 step-VM *execution* arm for kind 21
> is now wired on both stacks.  The Lean `stepVMHash` kind-21 arm
> dispatches to `stepCommitTopUpActionBudgetFor`
> (`FaultProof/SolidityStepVMCommit.lean` +
> `FaultProof/StepVMCoherence.lean`), the Solidity
> `_stepTopUpActionBudgetFor` decoder + dispatcher arm ship in
> `KnomosisStepVM.sol` (the `ActionKind` enum and `_toActionKind`
> bound widened to 21), and the cross-stack corpus grew from 238 to
> 248 entries (`+topUpActionBudgetFor` at 6 happy + 4 adversarial).
> So `topUpActionBudgetFor` is now L1-fault-proof-executable; the
> `stepVMHash` catch-all (empty-hash sentinel) only fires for kinds
> `≥ 22`.  See WU GP.5.3 below.

  * **Goal.**  Add the pre-authorised delegated budget top-up
    mechanism resolved in OQ-GP-7: a new `LocalPolicyClause`
    variant `allowTopUpFrom : List ActorId` and a new
    `Action.topUpActionBudgetFor` variant at frozen index 21.
  * **Files:**
    * `LegalKernel/Authority/LocalPolicy.lean` (extend the
      `LocalPolicyClause` inductive).
    * `LegalKernel/Authority/Action.lean` (add the index-21
      constructor).
    * `LegalKernel/Laws/TopUpActionBudgetFor.lean` (new law).
    * `LegalKernel/Authority/SignedAction.lean` (admission
      layer: add the consent check; extend the budget-grant
      logic to target the recipient).
  * **Deliverables.**

    ```lean
    -- Extension to LocalPolicyClause (Authority/LocalPolicy.lean):
    inductive LocalPolicyClause where
      | denyTags          (tags : List Nat)
      | requireRecipientIn (resource : ResourceId) (allowed : List ActorId)
      | capAmount         (resource : ResourceId) (max : Amount)
      | allowTopUpFrom    (delegates : List ActorId)  -- NEW v1.3
    ```

    The semantics — **DEFAULT-DENY**, critical to security:

    For `Action.topUpActionBudgetFor(recipient = R, ...)`
    signed by `S`, admission must verify ALL of:

    1. `R`'s `LocalPolicy` exists AND contains *some*
       `allowTopUpFrom delegates` clause.
    2. `S ∈ delegates` for that clause.

    If `R` has NO `allowTopUpFrom` clause at all (the default
    state for a newly-registered actor), the action is
    **rejected**.  This is "default-deny": a recipient must
    explicitly opt in to delegation via a prior signed
    `Action.declareLocalPolicy`.

    **Why default-deny matters (security analysis):**

    The opposite — default-allow — would mean "any third party
    can credit any actor's budget at any time".  That's
    superficially harmless (the third party pays their own
    balance; the recipient only gains budget) but it enables:

    * **Identity-tagging attacks**: an attacker tops up budget
      for an L2 actor whose identity they want to confirm,
      then watches mempool admission to see if that actor
      ever uses the budget — revealing whether the identity
      is active.
    * **Unwanted state growth**: an attacker tops up budget
      for many actors, growing the `EpochBudgetState` map
      and bloating storage.  Per-actor state-growth attacks
      are mitigated by Sybil cost (each recipient has to be a
      real registered actor, gated by L1 identity registration),
      but the asymmetric cost is real.
    * **Bypass of per-actor policy choices**: an actor who
      configures a non-default deny posture (e.g., capping
      their own activity to a small budget) loses that
      control if anyone can top them up.

    Default-deny eliminates all three.  The recipient's prior
    signed `declareLocalPolicy` action IS their consent; no
    one can fake it.

    **Implementation note:** the `allowTopUpFrom` clause is a
    *positive* policy clause (it grants permission), unlike
    `denyTags` / `requireRecipientIn` / `capAmount` which are
    *restrictive* clauses (they constrain).  This is the first
    positive clause in `LocalPolicyClause`.  The
    `localPolicyOk` function must therefore be extended:

    ```lean
    def localPolicyOk (policy : LocalPolicy) (action : Action) : Prop :=
      -- Existing: every restrictive clause must pass.
      (∀ c ∈ policy.clauses, restrictiveClauseOk c action) ∧
      -- NEW v1.3: for positively-gated actions, the relevant
      -- positive clause must EXIST and PASS.
      positivelyGatedActionOk policy action

    def positivelyGatedActionOk (policy : LocalPolicy) (action : Action) : Prop :=
      match action with
      | Action.topUpActionBudgetFor recipient signer _ _ _ _ =>
        -- Requires the recipient's policy to contain an
        -- allowTopUpFrom clause that includes the signer.
        ∃ c ∈ policy.clauses, ∃ delegates,
          c = LocalPolicyClause.allowTopUpFrom delegates ∧
          signer ∈ delegates
      -- (Future positively-gated actions extend here)
      | _ => True
    ```

    The `positivelyGatedActionOk` function is the *new* gate;
    `restrictiveClauseOk` is the existing logic restated under a
    name that makes the distinction explicit.  The combination
    is a conjunction: an action passes iff every restrictive
    clause permits it AND every positive clause that *applies*
    to this action is satisfied.

    **Decidability:** `positivelyGatedActionOk` for
    `topUpActionBudgetFor` is decidable via `List.any` over the
    clause list and `List.contains` for the delegate-set
    membership.  No quantifier elimination needed.

    ```lean
    -- New law at Laws/TopUpActionBudgetFor.lean:
    def topUpActionBudgetFor
        (recipient : ActorId) (signer : ActorId)
        (gasResource : ResourceId) (gasAmount : Amount)
        (_budgetIncrement : Nat) (poolActor : ActorId) :
        Transition where
      pre := fun s =>
        getBalance s gasResource signer ≥ gasAmount ∧
        recipient ≠ signer  -- can't delegate to self via this path
      decPre := fun _ => inferInstance
      apply_impl := fun s =>
        -- Identical kernel-state mutation to topUpActionBudget:
        -- debit signer, credit poolActor.  The recipient's
        -- budget grant happens at the admission layer.
        let s1 := setBalance s gasResource signer
                    (getBalance s gasResource signer - gasAmount)
        setBalance s1 gasResource poolActor
          (getBalance s1 gasResource poolActor + gasAmount)
    ```

    The `recipient ≠ signer` precondition prevents using the
    delegated path for self-topup (which should go through
    `Action.topUpActionBudget` directly).

    ```lean
    -- Admission-layer extension to processSignedActionWithBudget:
    let ebs'' :=
      match sa.action with
      | Action.topUpActionBudget _ _ budgetIncrement _ =>
        match es.budgetPolicy with
        | .unlimited      => ebs'
        | .bounded ft _   => ebs'.topUp actor now ft budgetIncrement
      | Action.depositWithFee _ recipient _ _ _ budgetGrant _ =>
        match es.budgetPolicy with
        | .unlimited      => ebs'
        | .bounded ft _   => ebs'.topUp recipient now ft budgetGrant
      | Action.topUpActionBudgetFor recipient _ _ budgetIncrement _ =>
        -- NEW v1.3 arm: budget grant targets RECIPIENT, not signer.
        -- The consent check (signer ∈ recipient's
        -- allowTopUpFrom list) happens during the
        -- bridgeAdmissibleWith / localPolicyOk pipeline above.
        match es.budgetPolicy with
        | .unlimited      => ebs'
        | .bounded ft _   => ebs'.topUp recipient now ft budgetIncrement
      | _ => ebs'
    ```

  * **Mathematical soundness double-check.**

    1. **Consent gate operates BEFORE state mutation.**  The
       `localPolicyOk` check for `Action.topUpActionBudgetFor`
       reads the recipient's current `LocalPolicy`, verifies
       the signer is in `allowTopUpFrom`, and only then allows
       the action through.  The pre-emptive consent declaration
       (via `Action.declareLocalPolicy`) must have been admitted
       in a prior state.

    2. **No back-door bypass.**  Even if the signer constructs
       the action with valid signature + nonce, if the
       recipient hasn't pre-authorised them, admission rejects
       with `NotAdmissible` + reason
       `TopUpDelegationNotAuthorized`.

    3. **Signer pays.**  The kernel-level law debits the
       signer's `gasResource` balance, not the recipient's.
       The recipient can never lose funds via this mechanism.

    4. **Revocation latency.**  If the recipient revokes
       delegation via `Action.revokeLocalPolicy`, the
       revocation takes effect from the next admitted
       SignedAction.  No mid-action atomicity issue because
       each action is admitted independently.

    5. **Conservation classification.**  Same as
       `topUpActionBudget`: kernel-state-wise, it's a
       `transfer` (conservative at gasResource).  Budget
       state, mutated at the admission layer, is separate.
       Inherits `IsConservative`, `IsMonotonic`, `LocalTo`,
       `FreezePreserving` from the underlying transfer shape.

  * **Theorems.**
    * `topUpActionBudgetFor_totalSupply_invariant`: gas-resource
      total supply preserved.
    * `topUpActionBudgetFor_signer_debited` (when `signer ≠
      poolActor`).
    * `topUpActionBudgetFor_pool_credited`.
    * `topUpActionBudgetFor_other_resource_untouched`.
    * `topUpActionBudgetFor_other_actor_untouched`.
    * `topUpActionBudgetFor_isConservative` instance.
    * `topUpActionBudgetFor_isMonotonic` instance.
    * `topUpActionBudgetFor_localTo [gasResource]` instance.
    * `topUpActionBudgetFor_freezePreserving S` for `S ∌
      gasResource`.
    * `delegatedTopUp_grants_budget_to_recipient`: admission
      crediting the recipient's slot.
    * `delegatedTopUp_requires_allowTopUpFrom`: the signer
      must be in the recipient's whitelist.
    * `delegatedTopUp_signer_balance_debited`: signer pays the
      gas-resource cost, not the recipient.

  * **Tests.**  30 cases:
    * Happy path: delegate is whitelisted, top-up succeeds.
    * Unauthorised: delegate not in whitelist, top-up rejected.
    * Recipient declares + signer tops up + recipient revokes
      + signer attempts again, rejected.
    * Recipient declares with multiple delegates; each can
      top up independently.
    * Self-delegation (recipient == signer): rejected by the
      law's precondition.
    * Insufficient signer balance: rejected at precondition.
    * Multiple sequential delegated topups: accumulate
      correctly.
    * Cross-delegate isolation: delegate A topping up
      recipient R doesn't affect delegate B's budget.
    * Locality at non-gas resources.
    * Free-tier interaction: a recipient with zero existing
      budget receives `budgetIncrement` via delegation +
      free-tier on epoch advance.

  * **Acceptance criteria.**  Two reviewers (touches
    `Authority/SignedAction.lean` AND adds a new
    LocalPolicyClause variant which is a non-trivial extension
    of the policy system).  Full Lean test suite green.
  * **Dependencies.**  GP.3.2 (the admission gate), GP.2.3
    (Action layer integration extended to index 21).
  * **Estimated effort.**  ~14 hours.

---

### Phase GP.4 — Bridge accounting amendment

#### WU GP.4.1: Widen `DepositRecord` with `poolAmount` — **Complete**

> **Status: complete (Lean side).**  `DepositRecord` is widened from
> the two-field `(resource, amount)` shape to the four-field
> `(resource, userAmount, poolAmount, budgetGrant)` record in
> `LegalKernel/Bridge/State.lean`, with the `LegacyDepositRecord`
> compatibility type and the `DepositRecord.fromLegacy` /
> `DepositRecord.toLegacy` lift certified lossless by
> `DepositRecord.toLegacy_fromLegacy`.  The CBE codec
> (`Bridge.DepositRecord.encode` / `decode`) and the
> `depositRecord_roundtrip` theorem (`LegalKernel/Encoding/State.lean`)
> are extended to the four-segment wire form; the EI.6.a / EI.6.b /
> EI.6.c inner-record + framing + outer-map injectivity ladder and the
> EI.7.e full-`BridgeState` injectivity headline
> (`LegalKernel/Encoding/BridgeInjective.lean`) carry the widened
> per-field canonical bounds, as does the
> `ExtendedState.CanonicalBounds.bs_cons_rec` field
> (`LegalKernel/FaultProof/Commit.lean`).  `applyActionToBridgeState`'s
> `deposit` / `depositWithFee` arms record the
> `(userAmount, poolAmount, budgetGrant)` split rather than the
> collapsed sum (`LegalKernel/Bridge/Admissible.lean`), and
> `DepositRecord.amountAt` recombines `userAmount + poolAmount` so the
> existing `totalDeposited` fold is value-preserving on every state
> (`LegalKernel/Bridge/Accounting.lean`) — the GP.4.2 accounting split
> into `totalUserDeposited` / `totalPoolDeposited` builds on this.  The
> `bridge-state`, `bridge-accounting`, `bridge-admissible`,
> `encoding-injectivity`, and `runtime-bridge-admission` suites cover
> the widening (encoder round-trips with non-zero pool / budget legs,
> per-field encode-distinctness, `fromLegacy` round-trip, and the
> per-split consumed-record assertions).

  * **Goal.**  Extend `DepositRecord` to carry both the
    user-credited amount and the pool-credited amount per deposit.
  * **Files:**
    * `LegalKernel/Bridge/State.lean` (extend the struct).
    * `LegalKernel/Encoding/Bridge.lean` (extend the encoder; update
      `BridgeState.encodeConsumed_injective` / EI.6).
  * **Deliverables.**

    ```lean
    structure DepositRecord where
      /-- The resource that was credited. -/
      resource    : ResourceId
      /-- The amount credited to the user-facing recipient. -/
      userAmount  : Amount
      /-- The amount credited to the gas-pool actor.
          Zero for legacy `Action.deposit` events. -/
      poolAmount  : Amount
      /-- The action-budget grant credited to the recipient at the
          admission layer.  Equals
          `min(MAX_BUDGET_PER_DEPOSIT, poolAmount / weiPerBudgetUnit)`
          as computed by the L1 contract.  Zero for legacy
          `Action.deposit` events.  Persisted in the bridge state
          so a re-org or replay can reconstruct the recipient's
          budget timeline without re-deriving from the L1
          exchange rate (which is constant per deployment but
          immutable across deployments → recoverable but
          inconvenient to derive). -/
      budgetGrant : Nat
      deriving Repr, DecidableEq
    ```

    *Author's mathematical-soundness note:* persisting
    `budgetGrant` in the record (rather than re-deriving it from
    `poolAmount / weiPerBudgetUnit` on each read) buys two
    properties:
    1. **Cross-stack byte-equivalence under deployment migration.**
       If a deployment migrates to a new `KnomosisBridge` with
       different `weiPerBudgetUnitEth` or `weiPerBudgetUnitBold`
       (via `KnomosisMigration`), the pre-migration deposit records
       keep their original
       `budgetGrant` rather than retroactively re-deriving at the
       new rate.
    2. **Idempotent replay.**  An `applyTrace` over the deposit
       history reproduces the recipient's budget exactly, without
       needing access to the deployment's `weiPerBudgetUnit`
       (which is L1 contract state, not L2 state).
  * **Theorems.**
    * `DepositRecord.encode_injective` (extended to cover the new
      field).
    * `BridgeState.encodeConsumed_injective` (EI.6 extension).
    * Legacy compat:
      `DepositRecord.fromLegacy : LegalKernel.Bridge.LegacyDepositRecord → DepositRecord`
      sets `poolAmount := 0`; round-trip preservation.
  * **Tests.**  ~15 cases for the encoder extension.
  * **Acceptance criteria.**  One reviewer; EI.6 / EI.7 regression
    tests green.
  * **Dependencies.**  None (independent of admission pipeline).
  * **Estimated effort.**  ~5 hours.

#### WU GP.4.2: Bridge accounting equation amendment

> **Status: complete (Lean side, v1.2 core).**  The deposit ledger is
> split into per-leg sums in `LegalKernel/Bridge/Accounting.lean`:
> `DepositRecord.userAmountAt` / `DepositRecord.poolAmountAt`
> projections (with the per-record split
> `DepositRecord.userAmountAt_add_poolAmountAt`), the
> `totalUserDeposited` / `totalPoolDeposited` functionals (with genesis
> lemmas, list-fold forms, and `*_unchanged_when_bridge_eq` lemmas),
> and the headline split identity
> `totalUserDeposited_plus_pool_eq_totalDeposited`
> (`totalUserDeposited es r + totalPoolDeposited es r = totalDeposited
> es r`).  The amended accounting equation is `bridge_accounting_equation_balanced`:
> given the legacy equation `totalDeposited es r = rhs` (the §15D
> right-hand side `totalWithdrawn + bridgeEscrowBalance`, promoted
> inductively by the §7.6.4 / §7.6.5 follow-up), the split equation
> `totalUserDeposited es r + totalPoolDeposited es r = rhs` holds with
> the *same* right-hand side — the deposit-fee split is a bookkeeping
> split, not an escrow split, so it leaves the equation balanced.
> Per-action deltas: `totalUserDeposited_step_eq` /
> `totalPoolDeposited_step_eq` (fee deposit), their `*_step_eq_deposit`
> legacy specialisations (`poolAmount = 0` ⇒ pool leg unchanged), the
> fresh-insert `*_markConsumed` deltas (via a generic projected-fold
> insert-absent lemma mirroring `RBMapLemmas.sumValues_insert_absent`),
> and `accounting_userpool_delta_non_bridge` (both legs unchanged on
> non-bridge actions).  Pool solvency:
> `depositWithFee_credits_poolActor` (the kernel-level pool credit),
> `depositWithFee_pool_credit_matches_ledger_delta` (every wei credited
> to the pool actor's L2 balance is matched, wei-for-wei, by the
> ledger's recorded pool deposit), and
> `pool_balance_eq_totalPoolDeposited_minus_payouts` (+ its genesis
> base case) — the solvency identity, parameterised over an arbitrary
> pool actor (no dependency on the GP.7.1 `gasPoolActor` reservation).
>
> *Audit follow-up (production-faithful forms).*  A post-implementation
> audit added the **atomic admitted-step** forms, stated over the real
> `apply_bridge_admissible_with` step (the function the runtime
> `processSignedActionWith` and the dispute pipeline execute) rather
> than its constituent transformers, and **deriving deposit-id
> freshness from the `BridgeAdmissibleWith` witness** (conjunct 6b)
> instead of taking it as a hypothesis:
> `totalUserDeposited_admissible_depositWithFee`,
> `totalPoolDeposited_admissible_depositWithFee`,
> `depositWithFee_admissible_credits_poolActor` (post-step pool balance
> via `apply_bridge_admissible_with_base_agrees` +
> `step_impl`-collapses-to-`apply_impl`), and
> `depositWithFee_admissible_pool_credit_matches_ledger` (the live pool
> balance and the `totalPoolDeposited` ledger move in lockstep,
> wei-for-wei, over the *same* admitted step).  The audit also closed
> the per-action-coverage gap by adding `accounting_userpool_delta_withdraw`
> (a `withdraw` touches only `pending`, so both deposit folds are
> unchanged — completing coverage over every `Action` constructor) and
> the `totalUserDeposited`/`totalPoolDeposited_unchanged_when_consumed_eq`
> "depends only on `consumed`" lemmas it rests on.
>
> *Optimal-closure follow-up.*  A second audit closed the remaining
> faithfulness gaps in the headline theorems:
> `bridge_accounting_equation_balanced_iff` restates the balanced
> equation as an **iff** that names `totalWithdrawn` explicitly and
> leaves only the L1 escrow term abstract (legacy and split LHS are
> interchangeable for any §15D-shaped RHS — strictly more faithful than
> the one-directional, fully-abstract-RHS form).
> `pool_solvency_preserved_by_admitted_depositWithFee` supplies a
> **genuine inductive step**: pool-solvency reconciliation
> (`getBalance poolActor + payouts = totalPoolDeposited`) is *preserved*
> across an admitted `depositWithFee` with the same payouts — a real
> proof obligation about the admitted step (the GP.7.3 trace invariant's
> inflow case), not a hypothesis rearrangement.  And the coherence is
> lifted onto the *literal* budget-gated runtime entry: the reusable
> `apply_bridge_admissible_with_budget_base_bridge_eq`
> (`Bridge/Admissible.lean`) proves the production gate overwrites only
> `epochBudgets` (so every accounting delta transfers verbatim), and
> `depositWithFee_budget_admitted_pool_credit_matches_ledger` states the
> pool-credit / ledger coherence over `apply_bridge_admissible_with_budget`
> itself — closing the accounting end-to-end on the function the runtime
> actually executes.
> The `bridge-accounting` suite gains 38 GP.4.2 cases (59 total).  All
> theorems depend only on `propext`, `Classical.choice`, `Quot.sound`.
>
> *Naming note.*  The split identity is named
> `totalUserDeposited_plus_pool_eq_totalDeposited` rather than the
> deliverable sketch's `..._eq_legacy_totalDeposited`: `_legacy` is a
> forbidden temporal-marker token under the `naming_audit` gate
> (CLAUDE.md "Names describe content, never provenance").  The
> docstring records that `totalDeposited` is the WU-C.6 single-term
> functional the split recovers.
>
> *Scope note (deferred to later WUs, not this one).*  The full
> *inductive* promotion of the reconciliation hypothesis in
> `pool_balance_eq_totalPoolDeposited_minus_payouts` — that the live
> `getBalance gasPoolActor` balance stays reconciled with the ledger
> across an entire trace — constrains the pool actor's outflows to the
> sequencer-payout path, which is the `gasPoolPolicy` (GP.7.2) drain
> bound; the trace-level invariant ships as
> `pool_balance_lower_bound_via_trace` in GP.7.3 once `gasPoolActor`
> (GP.7.1) is reserved.  The **v1.5 AMM-aware** extension below
> (`bridge_strong_conservation_under_ammSwap` et al.) depends on
> `Action.ammSwap` + `ammReserveActor`, which are GP.11; it is out of
> scope for this WU and lands with the AMM workstream.

  * **Goal.**  Update the bridge accounting equation in
    `LegalKernel/Bridge/Accounting.lean` to account for the new
    `poolAmount` term.
  * **File:** `LegalKernel/Bridge/Accounting.lean` (modified).
  * **Deliverables.**

    The original equation (§15D, Lean form):

    ```
    totalDeposited bs.consumed = totalWithdrawn bs.pending + bridgeEscrowBalance bs
    ```

    where `totalDeposited` summed `DepositRecord.amount`.  The
    amended form splits the LHS into two terms:

    ```
    totalUserDeposited bs.consumed + totalPoolDeposited bs.consumed =
      totalWithdrawn bs.pending + bridgeEscrowBalance bs
    ```

    The RHS is unchanged in *structure* — it is still the bridge's
    L1 escrow balance — because the L1 contract still escrows the
    full `msg.value`, the split into user-credit / pool-credit is
    a *bookkeeping* split, not an escrow split.

    Proven:
    * `totalUserDeposited_step_eq` (per-action delta).
    * `totalPoolDeposited_step_eq` (per-action delta).
    * `totalUserDeposited_plus_pool_eq_totalDeposited` — the split
      identity (renamed from the sketch's `..._eq_legacy_totalDeposited`
      to satisfy the `naming_audit` gate; see the status note above).
      For `Action.deposit` (legacy) actions (`poolAmount = 0`) this
      specialises to `totalUserDeposited = totalDeposited` via
      `totalPoolDeposited_step_eq_deposit`.
  * **Theorems.**
    * `bridge_accounting_equation_balanced` (the equation holds
      after any single bridge action, modulo the L1-side escrow
      change).
    * `pool_balance_eq_totalPoolDeposited_minus_payouts`: the L2
      `gasPoolActor` balance equals
      `Σ poolAmount in consumed records - Σ pool outflows to
      sequencer`.  This is the **pool solvency** invariant — a
      lower bound on pool balance given known outflows.

  * **v1.5 extension: AMM-aware accounting equation.**
    v1.3 introduced `Action.ammSwap` and the `ammReserveActor`,
    which mutate L2 balances at `(ammReserveActor, r)` and
    correspondingly mutate L1 reserves.  The original v1.2
    equation doesn't account for these flows.  v1.5 extends:

    ```
    ∀ r ∈ {ResourceId 0, ResourceId 1}:
      totalUserDeposited(r)
      + totalPoolFreeDeposited(r)     -- excludes ammSeedAmount
      + totalAmmSeeded(r)             -- ammSeedAmount from deposits
      + totalAmmInbound(r)            -- amountIn over swaps where fromResource = r
      = totalWithdrawn(r)
        + bridgeEscrowBalance(r)
        + totalAmmOutbound(r)         -- amountOut over swaps where toResource = r
    ```

    Equivalently and more compactly: the L1 escrow balance
    equals the sum of L2 balances across all actors:

    ```
    bridgeEscrowBalance(r) = Σ getBalance s r a  over all actors a
                           = getBalance s r gasPoolActor       -- free pool
                           + getBalance s r ammReserveActor    -- AMM portion
                           + Σ getBalance s r u  over user actors u
    ```

    This is the **strong conservation property**: the bridge's
    L1 holdings always equal the sum of L2 balances at every
    actor.  Trades within the bridge (deposits, swaps,
    withdrawals) shuffle between actors and resources but
    never break this identity.

  * **Author's soundness verification:**
    * For a `depositWithFee` action with `(userAmount,
      freePoolAmount, ammSeedAmount)` split:
      - L1 ETH balance += msg.value = userAmount + freePoolAmount + ammSeedAmount
      - L2 user balance += userAmount
      - L2 gasPoolActor balance += freePoolAmount
      - L2 ammReserveActor balance += ammSeedAmount
      - Sum: L2 balances increase by msg.value ✓ matches L1 increase
    * For an `ammSwap` ETH→BOLD with `(amountIn, amountOut)`:
      - L1 ETH balance += amountIn (user paid)
      - L1 BOLD balance −= amountOut (user received)
      - L2 ammReserveActor ETH balance += amountIn
      - L2 ammReserveActor BOLD balance −= amountOut
      - Per-resource conservation holds independently for ETH
        and BOLD ✓
    * For a withdrawal action with `amount`:
      - L1 ETH balance −= amount (sent to user on L1)
      - L2 user balance −= amount (debited via withdraw law)
      - Net per-resource: L1 balance change matches L2 ✓

  * **v1.5 new theorems (AMM extension):**
    * `bridge_strong_conservation_under_ammSwap`: an admitted
      `ammSwap` preserves the strong conservation property
      (L1 balance = sum of L2 balances) per-resource.
    * `bridge_strong_conservation_under_depositWithFee`: same
      for `depositWithFee` (including the freePool/ammSeed
      split).
    * `bridge_strong_conservation_inductive`: the property
      holds inductively over any trace of admitted actions.
  * **Tests.**  ~30 cases (v1.5 expansion from v1.2's 20):
    deposits, mixed legacy / GP deposits, withdrawals, pool
    drains, AMM swaps in both directions, AMM swap + deposit
    interleaved, AMM-disabled deposits skip the seed.
  * **Acceptance criteria.**  One reviewer; full Lean test suite
    green; AMM-extension theorems explicitly verified.
  * **Dependencies.**  GP.4.1.
  * **Estimated effort.**  ~6 hours.

---

### Phase GP.5 — Solidity L1 contract amendment

**v1.4 sub-WU subdivision.**  The Solidity-side amendments are
the largest single-phase scope in the workstream.  For
contributor tractability, each WU is split into focused sub-WUs
that can be picked up independently.  The original WU specs
(below) serve as design context; the sub-WUs are the actual
implementation tickets.

| Sub-WU      | Scope                                                                              | Effort (h) | Reviewers | Files                                  |
| ----------- | ---------------------------------------------------------------------------------- | ---------- | --------- | -------------------------------------- |
| GP.5.1.a    | Constructor signature + immutable param assignments (all v1.0 → v1.4 immutables)   | 3          | 1         | `KnomosisBridge.sol` (constructor only)   |
| GP.5.1.b    | Compile-time constants block (`MAX_FEE_BPS_CAP`, `MIN_WEI_PER_BUDGET_UNIT`, etc.)  | 1          | 1         | `KnomosisBridge.sol`                      |
| GP.5.1.c    | `depositETHWithFee` function body (with v1.4 receiptHash spec)                     | 4          | 2         | `KnomosisBridge.sol`                      |
| GP.5.1.d    | `_registerDepositWithFee` shared helper                                            | 3          | 2         | `KnomosisBridge.sol`                      |
| GP.5.1.e    | Event declarations (`DepositWithFeeInitiated`, error types)                        | 2          | 1         | `KnomosisBridge.sol`                      |
| GP.5.1.f    | Forge tests: happy-path (30 cases)                                                 | 4          | 1         | `test/BridgeFeeSplit.t.sol`            |
| GP.5.1.g    | Forge tests: error / revert cases (15 cases)                                       | 3          | 1         | `test/BridgeFeeSplit.t.sol`            |
| GP.5.1.h    | Forge fuzz test: `userAmount + poolAmount = msg.value` over 1000+ inputs           | 2          | 1         | `test/BridgeFeeSplit.t.sol`            |
| GP.5.1.i    | Lean cross-stack fixture generation                                                | 3          | 1         | `LegalKernel/Test/Bridge/CrossCheck/`  |
| **GP.5.1 total** | (subsumed by sub-WUs above)                                                    | **25**     | mixed     |                                        |

| GP.5.2.a    | `MAX_FEE_BPS_CAP` constant placement + NatSpec rationale                           | 0.5        | 1         | `KnomosisBridge.sol`                      |
| GP.5.2.b    | `MIN_WEI_PER_BUDGET_UNIT` constant placement + NatSpec                             | 0.5        | 1         | `KnomosisBridge.sol`                      |
| GP.5.2.c    | `MAX_BUDGET_PER_DEPOSIT` constant placement + NatSpec                              | 0.5        | 1         | `KnomosisBridge.sol`                      |
| GP.5.2.d    | CI gate script (`scripts/audit_compile_time_caps.sh`)                              | 1          | 1         | `solidity/scripts/`                    |
| **GP.5.2 total** |                                                                                | **2.5**    | 1 each    |                                        |

| GP.5.3.a    | (done in GP.3.3) Solidity step-VM: depositWithFee (variant 19) execution           | 4          | 2         | `KnomosisStepVM.sol`                      |
| GP.5.3.b    | (done in GP.3.3) Solidity step-VM: topUpActionBudget (variant 20) execution        | 3          | 2         | `KnomosisStepVM.sol`                      |
| GP.5.3.a′   | Solidity step-VM: topUpActionBudgetFor (variant 21) execution + dispatcher + enum   | 4          | 2         | `KnomosisStepVM.sol`                      |
| GP.5.3.c    | Cross-stack fixture corpus extension (238 → 248; +topUpActionBudgetFor 6+4) + data-flow packed-layout goldens (`packedLayoutGoldens` / `variant21TailGolden`) | 4 | 1 | `solidity/test/CrossCheck/`, `LegalKernel/Test/Bridge/CrossCheck/` |
| GP.5.3.d    | Lean-side `stepVMHash_topUpActionBudgetFor_kind` proof + `stepCommitTopUpActionBudgetFor` recipe | 3 | 2 | `FaultProof/StepVMCoherence.lean`, `FaultProof/SolidityStepVMCommit.lean` |
| GP.5.3.e    | RH-G observer `ActionKind` enum extension (consistency mirror)                     | 0.5        | 1         | `runtime/knomosis-faultproof-observer/`   |
| GP.5.3.f    | Keccak-linked dynamic byte-equivalence verification (throwaway build) + `OQ-GP-11` scope-boundary registry entry | 1 | 1 | (verification run) + `open_questions.md` |
| **GP.5.3 total** |                                                                                | **15**     | mixed     |                                        |

> **Scope note.**  The original GP.5.3.a / .b / .d rows named
> variants 19 / 20; those execution arms actually landed in GP.3.3.
> The work GP.5.3 genuinely delivered is the **variant-21
> (`topUpActionBudgetFor`) execution arm** (rows GP.5.3.a′ / .c / .d /
> .e above) — see WU GP.5.3 below.

| GP.5.4.a    | BOLD-specific construction checks (address pin + symbol cross-check)               | 3          | 2         | `KnomosisBridge.sol` (constructor)        |
| GP.5.4.b    | `depositBoldWithFee` function body (with `transferFrom` + balance-delta check)     | 4          | 2         | `KnomosisBridge.sol`                      |
| GP.5.4.c    | Forge tests: BOLD-path mirror of GP.5.1.f (25 cases)                               | 4          | 1         | `test/BridgeFeeSplitBold.t.sol`        |
| GP.5.4.d    | Forge tests: non-conformant BOLD mock (fee-on-transfer, rebase) revert testing     | 2          | 1         | `test/BridgeFeeSplitBold.t.sol`        |
| GP.5.4.e    | Cross-stack fixture generation for BOLD path                                       | 3          | 1         | `LegalKernel/Test/Bridge/CrossCheck/`  |
| **GP.5.4 total** |                                                                                | **16**     | mixed     |                                        |

| GP.5.5.a    | `boldCircuitClosed` storage + `boldCircuitOpen` modifier                           | 1          | 1         | `KnomosisBridge.sol`                      |
| GP.5.5.b    | Per-BOLD TVL cap (`boldTvlCap`, `boldTotalLockedValue`, `setBoldTvlCap`)           | 2          | 2         | `KnomosisBridge.sol`                      |
| GP.5.5.c    | Manual circuit-breaker functions (`closeBoldCircuit`, `openBoldCircuit`)           | 2          | 2         | `KnomosisBridge.sol`                      |
| GP.5.5.d    | Liquity V2 auto-trigger (`closeBoldCircuitIfAnyLiquityBranchShutdown` with v1.5 branch-shutdown semantics) | 4          | 2         | `KnomosisBridge.sol`                      |
| GP.5.5.e    | Forge tests: circuit-breaker behavioural (18 cases)                                | 3          | 1         | `test/BoldCircuitBreaker.t.sol`        |
| GP.5.5.f    | Liquity V2 mock for testing the auto-trigger                                       | 2          | 1         | `test/mocks/MockLiquityV2.sol`         |
| **GP.5.5 total** |                                                                                | **14**     | mixed     |                                        |

**Phase GP.5 total post-subdivision:** ~71.5 hours across 26 sub-
WUs.  Most sub-WUs are 2-4 hours; the longest is GP.5.1.f at 4
hours (the test suite).  This subdivision enables 2-3 parallel
contributors working on disjoint files (e.g., one on
`KnomosisBridge.sol` constructor + storage, another on the deposit
function bodies, a third on the test suites).

The original WU specs that follow remain authoritative for
*design rationale* (what each sub-WU is trying to achieve).
The sub-WU table above is the *implementation roadmap* (who
does what, in what file, in what order).

---

#### WU GP.5.1: `KnomosisBridge.depositETHWithFee` user-chosen fee split

  * **Status (ETH path): COMPLETE.**  `depositETHWithFee(uint16
    chosenFeeBps)`, the shared resource-generic
    `_registerDepositWithFee` helper, the three compile-time caps
    (`MAX_FEE_BPS_CAP` / `MIN_WEI_PER_BUDGET_UNIT` /
    `MAX_BUDGET_PER_DEPOSIT`), the `(minFeeBps, maxFeeBps,
    weiPerBudgetUnitEth)` immutables + constructor guards, the
    `DepositWithFeeInitiated` event, and the six fee-split errors all
    ship in `solidity/src/contracts/KnomosisBridge.sol`.  Coverage:
    `test/BridgeFeeSplit.t.sol` (44 behavioural cases — happy path,
    revert / constructor guards, cross-function integration (migration
    circuit-breaker, shared deposit nonce, forced-zero-fee), a
    near-`uint64`-max exchange rate, a gas-regression smoke test,
    explicit receiptHash replay-resistance (nonce-binding +
    deploymentId-binding), and three fuzz properties incl. the
    `userAmount + poolAmount == msg.value` conservation fuzz and a
    cross-rate differential) plus the
    80-entry cross-stack corpus `deposit_fee_split.json` (Lean generator
    `LegalKernel/Test/Bridge/CrossCheck/DepositFeeSplit.lean`, Solidity
    consumer `test/CrossCheck/DepositFeeSplit.t.sol` (8 cases), shared
    reference `test/utils/FeeSplitMath.sol`).  The cross-check pins the
    split + receiptHash three ways: arithmetic recompute against
    `FeeSplitMath`; a hash-independent byte-match of the Lean-emitted
    224-byte receiptHash preimage tail against `abi.encode` (runs in
    every binding mode); and a DIRECT live-contract check that deploys
    the bridge per fixture entry, calls `depositETHWithFee`, and asserts
    the emitted split equals the Lean values (no `FeeSplitMath`
    intermediary).  The Lean generator additionally proves the
    spec-level guarantees `feeSplit_conserves`, `feeSplit_pool_le`, and
    `feeSplit_budget_le_max`, making the contract's conservation +
    budget-bound proof-carrying up to the cross-stack equivalence.  Two
    implementation
    notes vs. the design sketch below: (1) the ETH-only scope defers
    `depositBoldWithFee` and the BOLD constructor checks to GP.5.4 /
    GP.5.5 (adding the BOLD address pin now would break every existing
    non-BOLD deployment), so only `weiPerBudgetUnitEth` (not
    `weiPerBudgetUnitBold`) is added here; (2) the `receiptHash`
    additionally binds `deploymentId` as its first field — matching
    the existing `_registerDeposit` recipe — for deployment-replay
    resistance, strengthening the §22.7b every-field cover; and the
    per-depositor `depositNonce` mapping is used (matching
    `_registerDeposit`), not a single global counter.  The
    `depositERC20WithFee` generic-ERC-20 variant in the sketch below is
    superseded by GP.5.4's BOLD-specific `depositBoldWithFee`.
  * **Goal.**  Amend `KnomosisBridge` with a new pair of payable
    entry points — `depositETHWithFee(uint16 chosenFeeBps)` and
    `depositERC20WithFee(uint64 resourceId, IERC20 token,
    uint256 amount, uint16 chosenFeeBps)` — that let the user
    choose the fee at deposit time within the
    `[minFeeBps, maxFeeBps]` constructor-fixed range.  The
    pool-credit amount is then converted to a budget grant at
    the constructor-fixed `weiPerBudgetUnit` exchange rate,
    clamped at `MAX_BUDGET_PER_DEPOSIT`.
  * **File:** `solidity/src/contracts/KnomosisBridge.sol`.
  * **Deliverables.**

    ```solidity
    /// @notice Compile-time hard cap on the deployment's
    /// maxFeeBps constructor argument.  No deployment can set a
    /// max fee above 50% — at 50% the user is gifting half their
    /// deposit; UI friction beyond this point is the right
    /// limiter.
    uint16 public constant MAX_FEE_BPS_CAP = 5000;

    /// @notice Compile-time minimum for the exchange rate.  Rules
    /// out the degenerate divide-by-zero shape.
    uint64 public constant MIN_WEI_PER_BUDGET_UNIT = 1;

    /// @notice Compile-time per-deposit budget-grant ceiling.
    /// 10^12 budget units = 1 trillion actions; vastly more than
    /// any honest user needs, far below state-bloat danger
    /// thresholds.
    uint64 public constant MAX_BUDGET_PER_DEPOSIT = 1_000_000_000_000;

    /// @notice Immutable deployment lower bound on user-chosen
    /// fee.  Typically 0 (allow purely-balance deposits) or a
    /// small positive value (force minimum pool contribution).
    uint16 public immutable minFeeBps;

    /// @notice Immutable deployment upper bound on user-chosen
    /// fee.  Capped above by MAX_FEE_BPS_CAP.
    uint16 public immutable maxFeeBps;

    /// @notice Immutable ETH-leg exchange rate: how many wei of
    /// ETH pool credit produces one unit of action budget.
    /// Bumping requires a KnomosisMigration handoff.
    uint64 public immutable weiPerBudgetUnitEth;

    /// @notice Immutable BOLD-leg exchange rate: how many wei of
    /// BOLD pool credit produces one unit of action budget.
    /// (BOLD is 18-decimal; the rate is per BOLD-wei.)  Bumping
    /// requires a KnomosisMigration handoff.
    uint64 public immutable weiPerBudgetUnitBold;

    /// @notice Compile-time pin on the canonical Liquity V2 BOLD
    /// token address.  Constructor reverts if the deployer
    /// passes a different address.
    address public constant BOLD_TOKEN_ADDRESS =
        0x6440f144B7e50d6a8439336510312D2F54Beb01D;

    /// @notice Compile-time pin on the expected BOLD token
    /// symbol.  Constructor reverts if BOLD_TOKEN.symbol() does
    /// not match this string.
    string public constant EXPECTED_BOLD_SYMBOL = "BOLD";

    /// @notice ResourceId for native ETH (existing constant).
    uint64 public constant RESOURCE_ID_NATIVE_ETH = 0;

    /// @notice ResourceId for BOLD (NEW v1.2).
    uint64 public constant RESOURCE_ID_BOLD = 1;

    constructor(
        ...,
        uint16 _minFeeBps,
        uint16 _maxFeeBps,
        uint64 _weiPerBudgetUnitEth,
        uint64 _weiPerBudgetUnitBold,
        address _boldTokenAddress
    ) {
        // Constructor bounds checks — all five immutable params
        // validated at deploy time; once past construction, every
        // path computes deterministically from these values.
        if (_minFeeBps > _maxFeeBps)
            revert MinFeeBpsExceedsMax(_minFeeBps, _maxFeeBps);
        if (_maxFeeBps > MAX_FEE_BPS_CAP)
            revert MaxFeeBpsExceedsCap(_maxFeeBps);
        if (_weiPerBudgetUnitEth < MIN_WEI_PER_BUDGET_UNIT)
            revert WeiPerBudgetUnitTooSmall(_weiPerBudgetUnitEth);
        if (_weiPerBudgetUnitBold < MIN_WEI_PER_BUDGET_UNIT)
            revert WeiPerBudgetUnitTooSmall(_weiPerBudgetUnitBold);
        // BOLD token authenticity check — defence in depth.
        // The constant address pin is the primary check; the
        // symbol check is the secondary check; both must pass.
        if (_boldTokenAddress != BOLD_TOKEN_ADDRESS)
            revert BoldTokenAddressMismatch(_boldTokenAddress);
        // The symbol() call is wrapped in try/catch because
        // arbitrary tokens may revert or return non-string data;
        // we treat any failure as a "this is not BOLD" signal.
        try IERC20Metadata(_boldTokenAddress).symbol()
            returns (string memory sym)
        {
            if (keccak256(bytes(sym)) !=
                keccak256(bytes(EXPECTED_BOLD_SYMBOL)))
                revert BoldTokenSymbolMismatch(sym);
        } catch {
            revert BoldTokenSymbolUnavailable();
        }
        minFeeBps = _minFeeBps;
        maxFeeBps = _maxFeeBps;
        weiPerBudgetUnitEth = _weiPerBudgetUnitEth;
        weiPerBudgetUnitBold = _weiPerBudgetUnitBold;
        // (existing constructor body — BOLD_TOKEN_ADDRESS is a
        // compile-time constant so no storage write needed)
    }

    function depositETHWithFee(uint16 chosenFeeBps)
        external payable nonReentrant circuitOpen
    {
        if (msg.value == 0) revert ZeroDeposit();
        if (chosenFeeBps < minFeeBps) revert FeeBpsBelowMin(chosenFeeBps);
        if (chosenFeeBps > maxFeeBps) revert FeeBpsAboveMax(chosenFeeBps);

        uint256 v = msg.value;

        // Floor division: poolAmount ≤ v * maxFeeBps / 10000
        // ≤ v * 5000 / 10000 = v / 2 always (since maxFeeBps
        // ≤ MAX_FEE_BPS_CAP = 5000).  So userAmount = v -
        // poolAmount ≥ v / 2 always.  Safe under unchecked.
        uint256 poolAmount = (v * uint256(chosenFeeBps)) / 10_000;
        uint256 userAmount;
        unchecked { userAmount = v - poolAmount; }

        // Compute budget grant using the ETH-leg exchange rate.
        // rawBudgetGrant ≤ v / MIN_WEI_PER_BUDGET_UNIT = v, well
        // below uint256.max for any realistic v.  Then clamp to
        // MAX_BUDGET_PER_DEPOSIT (≤ uint64.max so the cast is
        // safe).
        uint256 rawBudgetGrant =
            poolAmount / uint256(weiPerBudgetUnitEth);
        uint64 budgetGrant;
        if (rawBudgetGrant > uint256(MAX_BUDGET_PER_DEPOSIT)) {
            budgetGrant = MAX_BUDGET_PER_DEPOSIT;
        } else {
            budgetGrant = uint64(rawBudgetGrant);
        }

        _registerDepositWithFee(
            RESOURCE_ID_NATIVE_ETH,
            address(0),
            userAmount,
            poolAmount,
            budgetGrant
        );
    }

    function _registerDepositWithFee(
        uint64 resourceId,
        address token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant
    ) internal {
        uint256 newTvl = totalLockedValue + userAmount + poolAmount;
        if (newTvl > tvlCap) revert TvlCapReached();
        totalLockedValue = newTvl;

        bytes32 receiptHash = _computeReceiptHash(
            msg.sender, resourceId, token,
            userAmount, poolAmount, budgetGrant, depositNonce
        );
        emit DepositWithFeeInitiated(
            msg.sender, resourceId, token,
            userAmount, poolAmount, budgetGrant,
            depositNonce, receiptHash
        );
        depositNonce++;
    }
    ```
  * **Mathematical-soundness double-check.**

    1. **Fee-split underflow safety.**
       `poolAmount = ⌊v × chosenFeeBps / 10000⌋`.  Bounded above
       by `⌊v × maxFeeBps / 10000⌋ ≤ ⌊v × 5000 / 10000⌋ = ⌊v /
       2⌋ ≤ v`.  Therefore `userAmount = v - poolAmount ≥ 0`,
       safe under `unchecked`.

    2. **Round-trip exactness.**
       Let `r = v × chosenFeeBps mod 10000` (the floor-division
       residue).  Then `poolAmount = (v × chosenFeeBps − r) /
       10000`.  Since `r ≥ 0`, `poolAmount × 10000 ≤ v ×
       chosenFeeBps`.  And `userAmount + poolAmount =
       (v − poolAmount) + poolAmount = v` exactly.  ✓
       The residue (a few wei at most, bounded by
       `10000 − 1 = 9999` wei) accrues to `userAmount`, favouring
       the user.

    3. **`budgetGrant` overflow safety (ETH leg).**
       `rawBudgetGrant = poolAmount / weiPerBudgetUnitEth ≤
       poolAmount ≤ v ≤ uint256.max` (since
       `weiPerBudgetUnitEth ≥ MIN_WEI_PER_BUDGET_UNIT = 1`).
       No uint256 overflow.  The cast to `uint64` is gated by
       the explicit `> MAX_BUDGET_PER_DEPOSIT` check, where
       `MAX_BUDGET_PER_DEPOSIT = 10¹² < 2⁶³ − 1`.  So the
       only `uint64`-bound value ever cast is in `[0, 10¹²]`,
       well within range.  ✓ The BOLD-leg analysis is identical
       in shape with `weiPerBudgetUnitBold` substituted for
       `weiPerBudgetUnitEth` (see GP.5.4).

    4. **Zero-deposit guard.**
       `msg.value == 0` reverts.  Defends against a
       degenerate-deposit DoS where an attacker would otherwise
       be able to consume the L1 contract's `depositNonce`
       indefinitely at zero cost.  (The existing v1.0 plan
       missed this; v1.1 adds it.)

    5. **Reentrancy.**  `nonReentrant` modifier applied as
       before.  `_registerDepositWithFee` is internal, no
       external calls.

    6. **TVL cap.**  Enforced on `userAmount + poolAmount = v`.
       Independent of `chosenFeeBps` — cannot be bypassed by
       fee manipulation.

    7. **No frontrun attack via gas-pool inflation.**
       A user paying a higher `chosenFeeBps` gifts more to the
       pool.  This is benign from a security standpoint — the
       pool is sequencer-drainable via `gasPoolPolicy`, not
       attacker-controllable.  Cannot be used as a free
       griefing vector against the sequencer; if anything, the
       sequencer benefits from over-fee deposits.

  * **Events.**

    ```solidity
    event DepositWithFeeInitiated(
        address indexed sender,
        uint64 indexed resourceId,
        address indexed token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64  budgetGrant,
        uint64  depositNonce,
        bytes32 receiptHash
    );

    error ZeroDeposit();
    error FeeBpsBelowMin(uint16 chosenFeeBps);
    error FeeBpsAboveMax(uint16 chosenFeeBps);
    error MinFeeBpsExceedsMax(uint16 minFeeBps, uint16 maxFeeBps);
    error MaxFeeBpsExceedsCap(uint16 maxFeeBps);
    error WeiPerBudgetUnitTooSmall(uint64 weiPerBudgetUnit);
    error BoldTokenAddressMismatch(address provided);
    error BoldTokenSymbolMismatch(string actualSymbol);
    error BoldTokenSymbolUnavailable();
    error BoldTransferAmountMismatch(uint256 expected, uint256 actual);
    error BoldDepositPaused();
    ```

    Legacy `DepositInitiated` is retained for chain-state
    backwards-compat reads; new deployments emit only
    `DepositWithFeeInitiated`.

  * **Tests.**  `solidity/test/BridgeFeeSplit.t.sol` (new), 30+
    cases:
    * `chosenFeeBps = 0`: pure deposit, `poolAmount = 0`,
      `budgetGrant = 0`.  Allowed iff `minFeeBps == 0`.
    * `chosenFeeBps = minFeeBps`: minimum allowed; smallest
      possible pool contribution.
    * `chosenFeeBps = maxFeeBps`: maximum allowed; largest
      possible budget grant in one transaction.
    * `chosenFeeBps = minFeeBps - 1`: reverts `FeeBpsBelowMin`.
    * `chosenFeeBps = maxFeeBps + 1`: reverts `FeeBpsAboveMax`.
    * `chosenFeeBps = 10001`: still reverts `FeeBpsAboveMax`
      (defence in depth — the boundary check fires before any
      arithmetic).
    * `msg.value = 0`: reverts `ZeroDeposit`.
    * Tiny amount: `msg.value = 1`, `chosenFeeBps = 100`
      → `poolAmount = 0`, `userAmount = 1`, `budgetGrant = 0`
      (rounding favours user; budgetGrant rounds to zero).
    * `weiPerBudgetUnit = 1`: maximum budget-grant rate;
      `budgetGrant = poolAmount` (clamped at
      `MAX_BUDGET_PER_DEPOSIT`).
    * `weiPerBudgetUnit = 10^12`: realistic operator setting;
      `budgetGrant = poolAmount / 10^12`.
    * **Clamp-vs-revert behaviour:** at the maximum fee with a
      huge deposit, `rawBudgetGrant > MAX_BUDGET_PER_DEPOSIT`;
      verify the budget is clamped (NOT revert); the deposit
      still succeeds at the clamped grant.
    * Round-trip: `userAmount + poolAmount = msg.value`
      exactly for 100+ fuzz inputs.
    * Receipt-hash bound: `receiptHash` includes all of
      `(sender, resource, token, userAmount, poolAmount,
      budgetGrant, depositNonce)` — verify two deposits with
      identical other fields but different `chosenFeeBps`
      produce different receipt hashes.
    * Constructor argument validation: `minFeeBps > maxFeeBps`
      reverts; `maxFeeBps > MAX_FEE_BPS_CAP` reverts;
      `weiPerBudgetUnit = 0` reverts.
    * Reentrancy attempt: blocked.
    * TVL-cap interaction: cap fires on `userAmount + poolAmount
      = msg.value`.
    * ERC-20 variant: same logic via `depositERC20WithFee`.
    * Differential: same `(msg.value, chosenFeeBps)` produces
      identical Solidity vs Lean-fixture `(userAmount,
      poolAmount, budgetGrant)`.

  * **Acceptance criteria.**  Two reviewers (touches the L1
    bridge contract, which is a critical security surface);
    `forge test --match-path test/BridgeFeeSplit.t.sol` green;
    gas snapshot baseline updated.  Fuzz test with at least
    1000 inputs across `(msg.value, chosenFeeBps,
    weiPerBudgetUnit)` triples passes byte-equivalence against
    a Lean reference computation.
  * **Dependencies.**  GP.4.1 (Lean side ready to accept the new
    event shape).
  * **Estimated effort.**  ~14 hours including Forge tests
    (v1.0 estimated 10; +4 for the additional bounds checks
    and the cross-stack fuzz harness).

#### WU GP.5.2: Constructor-cap constants — rationale and audit gate — **Complete**

  * **Status: COMPLETE.**  All three compile-time caps —
    `MAX_FEE_BPS_CAP = 5000`, `MIN_WEI_PER_BUDGET_UNIT = 1`,
    `MAX_BUDGET_PER_DEPOSIT = 10¹²` — ship in
    `solidity/src/contracts/KnomosisBridge.sol` (GP.5.1) with the
    per-value NatSpec rationale below (GP.5.2.a / .b / .c).  The audit
    gate `solidity/scripts/audit_compile_time_caps.sh` (GP.5.2.d, run
    via `make audit-caps`) asserts each `(name, type, value)` triple
    against the canonical source declaration, reading each value *by
    name* (anchored on `constant <name> =`, so it reads exactly that
    constant — not the last number on the line), checking the declared
    `uintN` width, and matching over a comment-stripped view of the
    source (so a canonical-looking line hidden in a `//` or multi-line
    `/* */` comment cannot mask a drifted real declaration): pure
    `grep`/`sed`/`awk`, no `solc` dependency, well under a second.  It
    fails closed on a missing or duplicated declaration, a type
    narrowing, a non-decimal / constant-expression reformat, a
    comment-masked drift, or any value drift, while tolerating
    underscore-separator reformatting of an unchanged value.  This is
    the source-level complement to the compiled-contract pin
    `test/BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned`; both
    layers are green.  A companion self-test
    (`solidity/scripts/audit_compile_time_caps_selftest.sh`, `make
    audit-caps-selftest`, 18 cases) proves the gate accepts the
    canonical source and rejects every drift class — including the
    comment-masking false-pass surfaced in PR review — guarding against
    a future edit that silently disables the tripwire.  Both layers are
    enforced in CI by the new `.github/workflows/ci-solidity.yml` (the
    repo's first Solidity-side workflow, path-filtered to
    `solidity/**`): a toolchain-free `caps-audit` job runs the gate +
    self-test, and a `forge` job runs the runtime pin alongside the
    full contract suite.  Each constant additionally carries a `@dev`
    NatSpec governance tag naming both protection layers.  Changing any
    cap remains a Genesis-Plan §13.6 amendment (two-reviewer rule), and
    the gate's `CAPS` table must be updated in the same PR.

  * **Goal.**  Document the three compile-time constants
    (`MAX_FEE_BPS_CAP`, `MIN_WEI_PER_BUDGET_UNIT`,
    `MAX_BUDGET_PER_DEPOSIT`) and add an audit binary that fails
    if any of them is changed without a §13.6 amendment.
  * **Files:**
    * `solidity/src/contracts/KnomosisBridge.sol` (constants + long
      comments stating the rationale for each value).
    * `solidity/scripts/audit_compile_time_caps.sh` (CI gate).
  * **Deliverables.**  CI gate that greps for each constant and
    asserts the values.  Out-of-band convention: changing any
    value requires a Genesis-Plan amendment and the §13.6
    two-reviewer rule.

    *Rationale text* (drafted; lives in the contract's NatSpec
    docs):

    * `MAX_FEE_BPS_CAP = 5000` — 50 %.  Higher caps invite UX
      footguns: a user accidentally setting `chosenFeeBps =
      9000` would gift 90 % of their bridged value to the
      pool.  50 % is the boundary where "fee" stops being a
      reasonable English-language description.  Deployments
      typically set `maxFeeBps` much lower (e.g., 1000 = 10 %)
      for realistic UX.
    * `MIN_WEI_PER_BUDGET_UNIT = 1` — rules out divide-by-zero;
      additionally rules out fractional unit semantics that
      Solidity uint64 cannot express.
    * `MAX_BUDGET_PER_DEPOSIT = 10¹²` — one trillion budget
      units.  At one action per millisecond, that's ~31 years of
      continuous action consumption from a single deposit.
      Sufficient for any realistic super-user; far below the
      state-bloat threshold of `2⁶³` units (the uint64 boundary
      with one bit of headroom for safety arithmetic).

  * **Acceptance criteria.**  One reviewer; CI gate added; gate
    asserts all three values are unchanged from the source code.
  * **Dependencies.**  GP.5.1.
  * **Estimated effort.**  ~2 hours.

#### WU GP.5.3: `KnomosisStepVM` extension for new variants

  * **Status: COMPLETE.**  Scope note: this WU header was written
    before GP.3.4 existed and names variants 19 / 20.  Those two
    variants' step-VM execution arms (`_stepDepositWithFee`,
    `_stepTopUpActionBudget`) actually landed inside GP.3.3 (their
    `stepVMHash` arms + Solidity step functions + cross-stack
    fixtures shipped there).  The work that was genuinely *deferred
    to GP.5.3* — per the GP.3.4 closeout note above — is the
    **variant-21 (`topUpActionBudgetFor`) execution arm**, which this
    WU closes.
  * **Goal.**  Extend the Solidity step VM to execute the delegated
    `topUpActionBudgetFor` variant (action-index 21)
    byte-equivalently to the Lean kernel — closing the last GP-family
    `stepVMHash` catch-all (empty-hash) sentinel.
  * **Files:**
    * `LegalKernel/FaultProof/SolidityStepVMCommit.lean` — new
      `tagTopUpActionBudgetFor` + `stepCommitTopUpActionBudgetFor`
      commit recipe (structurally identical to
      `stepCommitTopUpActionBudget`, distinct tag).
    * `LegalKernel/FaultProof/StepVMCoherence.lean` — kind-21
      `stepVMHash` execution arm + `stepVMHash_topUpActionBudgetFor_kind`
      reduction theorem; `actionKindByteCases` widened to include 21;
      `stepVMHash_unknown_kind_empty` re-pinned at kind 22.
    * `solidity/src/contracts/KnomosisStepVM.sol` — `ActionKind`
      enum + `TAG_TOPUP_ACTION_BUDGET_FOR` + `_toActionKind` bound
      (`> 21`) + dispatcher arm + `_stepTopUpActionBudgetFor`.
    * `LegalKernel/Test/Bridge/CrossCheck/StepVM.lean` — corpus
      generator extended (`+topUpActionBudgetFor`: 6 happy + 4
      adversarial; total 238 → 248).
    * `solidity/test/CrossCheck/StepVM.t.sol` — consumer counts +
      ranges updated (248 entries; 152 happy; 96 adversarial;
      actionKindByte ≤ 21).
    * `solidity/test/KnomosisStepVM.t.sol` — variant-21 unit tests
      (execution, canonical-recipe equivalence, tag separation,
      self-pool net-zero, short-fields, insufficient-gas; `kind 21
      reverts` → `kind 22 reverts`).
    * `runtime/knomosis-faultproof-observer/src/submitter.rs` — the
      RH-G observer's `ActionKind` naming-mirror enum gains
      `TopUpActionBudgetFor = 21` (production calldata encodes the
      raw `u8`, so this is a consistency / test-readability fix, not a
      behavioural change).
  * **Design.**  `topUpActionBudgetFor`'s kernel-state effect is
    byte-identical in shape to `topUpActionBudget` (debit the
    delegate-signer at `gasResource`, credit `poolActor`); the L1
    step-VM hash binds only those two balance writes.  The
    `recipient` (field offset 0) and `budgetIncrement` (offset 24)
    are admission-layer effects on the *recipient's* epoch-budget
    slot — not kernel-state cell writes — so both are decoded for
    field-layout symmetry but excluded from the step-VM hash, exactly
    as kinds 19 / 20 exclude their `budgetGrant` / `budgetIncrement`.
    The DISTINCT commit tag (`keccak256("topUpActionBudgetFor")`)
    separates this variant's commit from the self-funded
    `topUpActionBudget` even when every gas-transfer field coincides.
  * **Theorems** (Lean side): `stepVMHash_topUpActionBudgetFor_kind`
    (kind-21 dispatch reduction, `rfl`); the GP.3.4
    `coherence_topUpActionBudgetFor` / `cellwrites_topUpActionBudgetFor`
    (full-state-commit coherence) remain valid unchanged.
  * **Tests.**  Solidity: in `KnomosisStepVM.t.sol` the
    keccak-independent canonical-recipe pin, a tag-separation test, a
    self-pool net-zero test, and an exact-balance-drain boundary test
    (48 total); in `CrossCheck/StepVM.t.sol` the two data-flow
    layout-golden consumers
    `test_packedLayoutGoldens_match_abiEncodePacked` /
    `test_variant21_tailGolden_matches_abiEncodePacked` (11 total +
    the keccak-gated byte-equivalence driver).  Lean: 10 new
    `faultproof-stepvm-coherence` cases (value-level dispatch incl.
    tag-separation, admission-field exclusion, self-pool defended
    branch, exact-balance Nat boundary, two end-to-end production-path
    cases incl. the absent-pool-pre-balance edge, field-layout pin,
    API-stability) + 2 new `crosscheck-step-vm` cases (corpus-count pin
    + the data-flow layout-goldens' well-formedness guard).
    **Verification posture — byte-equivalence proven two ways.**
    (1) *Dynamic, end-to-end:* under a keccak-linked verification build
    (the `knomosis-hash-keccak256` staticlib linked in place of the FNV
    fallback via the `KNOMOSIS_HASH_BACKEND=keccak256` lakefile swap;
    orchestrated by `scripts/verify_keccak_crossstack.sh` and run in CI
    via `.github/workflows/ci-keccak-crossstack.yml`), the fixture
    regenerates with `isKeccak256Linked = true` and forge's
    `test_perEntry_byte_equivalence_all_happy` — no longer skipped —
    confirms all 152 happy fixtures (the 6 variant-21 entries included)
    byte-match `executeStep`.  The committed fixture stays on the FNV
    default, so the default `lake test` / `forge test` skip the dynamic
    comparison exactly as for kinds 0..20.  (2) *Hash-independent,
    always-on:* the **data-flow layout goldens** — Lean emits its
    actual `uint64BE`/`uint256BE` output (incl. full-32-byte-width
    `uint256` values) + the variant-21 tail into `step_vm.json`;
    Solidity reads them back and recomputes `abi.encodePacked`,
    asserting byte equality with a single source of truth (no
    independently-maintained literals).  Combined with the
    `keccak256("topUpActionBudgetFor")` tag and the shared `preCommit`,
    this proves the full step-VM commit byte-equivalent in every
    binding mode.  **Scope boundary:** the step-VM commit does NOT bind
    the `epochBudgets` ledger (admission-layer budget effects are out
    of fault-proof re-execution scope, as for kinds 19 / 20 and the
    nonce of every variant) — recorded as `OQ-GP-11` in
    `open_questions.md`.
  * **Acceptance criteria.**  Two reviewers; forge + Lean
    cross-check both green.
  * **Dependencies.**  GP.3.3, GP.3.4, GP.5.1.
  * **Estimated effort.**  ~14 hours.

#### WU GP.5.4: `KnomosisBridge.depositBoldWithFee` BOLD entry point (v1.2)

  * **Status: COMPLETE.**  `depositBoldWithFee(uint256 amount, uint16
    chosenFeeBps)`, the BOLD constitutional pins (`BOLD_TOKEN_ADDRESS =
    0x6440f144b7e50D6a8439336510312d2F54beB01D`, `EXPECTED_BOLD_SYMBOL =
    "BOLD"`, `RESOURCE_ID_BOLD = 1`), the `weiPerBudgetUnitBold` +
    `boldEnabled` immutables, and the four BOLD errors
    (`BoldTokenAddressMismatch` / `BoldTokenSymbolMismatch` /
    `BoldTokenSymbolUnavailable` / `BoldTransferAmountMismatch`, plus
    `BoldNotEnabled`) all ship in
    `solidity/src/contracts/KnomosisBridge.sol`.  The BOLD leg reuses the
    resource-generic `_registerDepositWithFee` helper verbatim (so the
    receipt is byte-identical in shape to the ETH receipt save for
    `resourceId = 1` + `token = BOLD_TOKEN_ADDRESS`), pulls value via
    `SafeERC20.safeTransferFrom` + a balance-delta check, and computes the
    same fee split / budget clamp at the `weiPerBudgetUnitBold` rate.
    Three implementation notes vs. the design sketch below:
    1. **BOLD is opt-in.**  The constructor takes `boldTokenAddress`;
       `address(0)` disables BOLD (so the bridge still deploys on chains
       without BOLD and every pre-GP.5.4 ETH-only deployment shape keeps
       working), and any non-zero value MUST equal the `BOLD_TOKEN_ADDRESS`
       pin + pass the `symbol()` cross-check.  The sketch's unconditional
       pin would have broken the test `Deployer` (a contract — it cannot
       `vm.etch` a BOLD mock at the pin) and every non-mainnet deployment.
       `depositBoldWithFee` reverts `BoldNotEnabled` when disabled.
    2. **`SafeERC20.safeTransferFrom` + balance-delta** (matching the
       existing `depositERC20`) replaces the sketch's raw `transferFrom`
       + undeclared `TransferFailed`; it normalises non-bool-returning /
       reverting tokens and the delta check rejects fee-on-transfer /
       rebase tokens (`BoldTransferAmountMismatch`).  An explicit
       code-presence check maps the no-code-at-pin case onto
       `BoldTokenSymbolUnavailable` (Solidity's `try` does not route the
       extcodesize-zero revert through `catch`).
    3. **The `boldCircuitOpen` modifier in the sketch's function
       signature is GP.5.5's** (GP.5.5.a); GP.5.4 carries `nonReentrant`
       + `circuitOpen` only.
    4. **`RESOURCE_ID_BOLD` reserve + auto-bind** (audit hardening): when
       BOLD is enabled the constructor AUTO-BINDS
       `(RESOURCE_ID_BOLD = 1 -> BOLD_TOKEN_ADDRESS)` in the resource map
       and RESERVES both `RESOURCE_ID_BOLD` and `BOLD_TOKEN_ADDRESS` from
       the deployer's map (`BoldResourceReserved`).  This closes a
       stuck-funds / divergence footgun: `depositBoldWithFee` credits
       resourceId 1 via the constant path, while `withdrawWithProof` pays
       out `_resourceTokens[resourceId]` — so without the auto-bind a
       deployment that forgot to register `(1, BOLD)` would strand BOLD
       (withdrawals revert `UnsupportedResource`), and one that mapped
       resourceId 1 to another token would pay the wrong token.  Auto-bind
       makes BOLD withdrawals work with no deployer action and no way to
       misconfigure; the reserve guard forecloses both the wrong-token and
       the BOLD-at-another-id cases.  A `resourceToken(uint64)` getter
       exposes the binding.  (Inert when BOLD is disabled — resourceId 1 is
       then an ordinary ERC-20 slot.)
    5. **BOLD constitutional pins in the source audit gate**: the GP.5.2
       `scripts/audit_compile_time_caps.sh` gate is extended with
       kind-specific checks for `BOLD_TOKEN_ADDRESS` (address,
       case-insensitive) and `EXPECTED_BOLD_SYMBOL` (string), and the
       self-test grows 18 -> 23 cases — so the two BOLD pins get the same
       dual-layer (source gate + runtime `test_boldConstants_pinned`)
       protection the numeric caps have.
    6. **keccak256 receiptHash equivalence** is closed transitively (the
       always-on `receiptTail` layout byte-match + the global
       `keccak256.json` cross-stack corpus + the live-contract real-keccak
       recipe).  The belt-and-braces keccak-linked fixture regeneration is
       now also wired in CI: `scripts/verify_keccak_crossstack.sh` (run via
       `.github/workflows/ci-keccak-crossstack.yml`) regenerates the BOLD
       fee-split corpus under real keccak256 and runs its keccak-gated
       consumer assertion.
    Coverage: `test/BridgeFeeSplitBold.t.sol` (59 behavioural cases —
    the GP.5.1 happy/revert mirror over the BOLD path, the non-conformant
    BOLD mocks of GP.5.4.d (fee-on-transfer, false-returning transfer,
    wrong / reverting / absent symbol), the opt-out (`BoldNotEnabled` +
    ETH-still-works) cases, the `RESOURCE_ID_BOLD` reserve / auto-bind
    cases, a full end-to-end deposit -> escrow -> attested-state-root ->
    finalise -> `withdrawWithProof` -> replay-rejection lifecycle test, a
    cross-leg calibration-parity check, and three fuzz properties incl. the
    conservation + cross-rate differential) plus the
    80-entry cross-stack corpus
    `deposit_fee_split_bold.json` (Lean generator
    `LegalKernel/Test/Bridge/CrossCheck/DepositFeeSplitBold.lean`, 14
    cases; Solidity consumer `test/CrossCheck/DepositFeeSplitBold.t.sol`,
    8 cases + 1 keccak-gated skip — including a live-contract per-entry
    deposit that deploys a BOLD-enabled bridge and asserts the emitted
    split equals the Lean values).  Two Rust BOLD (`resourceId = 1`) tests
    (`knomosis-l1-ingest`: decode + translate) pin that the L1 ingestor
    covers BOLD with no production change.  The BOLD mocks live in
    `test/utils/MockBold.sol`; the split + receiptHash reuse the GP.5.1
    `test/utils/FeeSplitMath.sol` reference (the receiptHash is
    resource-generic).  The per-currency BOLD circuit breaker + per-BOLD
    TVL cap remain GP.5.5.
  * **Goal.**  Add the BOLD-currency parallel entry point to
    `KnomosisBridge`, byte-equivalently to the ETH path but
    operating on the BOLD ERC-20 token via `transferFrom` /
    `transfer`.  The user picks `chosenFeeBps` within the same
    `[minFeeBps, maxFeeBps]` range as the ETH path; the pool
    credit accumulates at `ResourceId 1` instead of
    `ResourceId 0`; the budget grant uses
    `weiPerBudgetUnitBold` as the exchange rate.
  * **File:** `solidity/src/contracts/KnomosisBridge.sol`
    (extension of WU GP.5.1's amendments).
  * **Deliverables.**

    ```solidity
    function depositBoldWithFee(uint256 amount, uint16 chosenFeeBps)
        external nonReentrant circuitOpen boldCircuitOpen
    {
        if (amount == 0) revert ZeroDeposit();
        if (chosenFeeBps < minFeeBps) revert FeeBpsBelowMin(chosenFeeBps);
        if (chosenFeeBps > maxFeeBps) revert FeeBpsAboveMax(chosenFeeBps);

        // Defensive transferFrom + balance-delta verification.
        // BOLD is standard ERC-20 (no fee-on-transfer), but
        // defence-in-depth: measure balanceOf before and after.
        IERC20 boldToken = IERC20(BOLD_TOKEN_ADDRESS);
        uint256 balBefore = boldToken.balanceOf(address(this));
        bool ok = boldToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();
        uint256 balAfter = boldToken.balanceOf(address(this));

        uint256 received;
        unchecked { received = balAfter - balBefore; }
        // Pre-condition: balAfter ≥ balBefore (else transferFrom
        // would have reverted or returned false above, which we
        // already handled).  So subtraction is safe.
        if (received != amount) revert BoldTransferAmountMismatch(amount, received);

        uint256 v = amount;

        // Floor division: poolAmount ≤ v × maxFeeBps / 10000 ≤
        // v × 5000 / 10000 = v / 2.  So userAmount = v −
        // poolAmount ≥ v / 2 ≥ 0.  Safe under unchecked.
        uint256 poolAmount = (v * uint256(chosenFeeBps)) / 10_000;
        uint256 userAmount;
        unchecked { userAmount = v - poolAmount; }

        // Compute budget grant using the BOLD-leg exchange rate.
        // Identical safety argument to the ETH leg, with
        // weiPerBudgetUnitBold substituted for
        // weiPerBudgetUnitEth.
        uint256 rawBudgetGrant =
            poolAmount / uint256(weiPerBudgetUnitBold);
        uint64 budgetGrant;
        if (rawBudgetGrant > uint256(MAX_BUDGET_PER_DEPOSIT)) {
            budgetGrant = MAX_BUDGET_PER_DEPOSIT;
        } else {
            budgetGrant = uint64(rawBudgetGrant);
        }

        _registerDepositWithFee(
            RESOURCE_ID_BOLD,
            BOLD_TOKEN_ADDRESS,
            userAmount,
            poolAmount,
            budgetGrant
        );
    }
    ```

  * **Mathematical-soundness double-check.**

    1. **`transferFrom` semantic verification.**  BOLD is standard
       ERC-20 (no fee-on-transfer, no rebase, no transfer
       hooks).  The `balBefore` / `balAfter` delta check is
       defence-in-depth: it would fail loudly if BOLD ever
       changes semantics (e.g., adds fee-on-transfer in a
       future Liquity V2 upgrade), preventing silent
       under-accounting.

       Author's arithmetic verification:
       * If BOLD is standard ERC-20: `balAfter = balBefore + amount`,
         so `received = amount`, check passes.
       * If BOLD has fee-on-transfer or burns on transfer
         (hypothetical):
         `balAfter = balBefore + amount − fee_or_burn`, so
         `received = amount − fee_or_burn < amount`, check
         reverts with `BoldTransferAmountMismatch`.  ✓
       * Safe under `unchecked` because `balAfter ≥ balBefore`
         is guaranteed by the successful `transferFrom` (which
         atomically debits the caller and credits the contract).

    2. **Fee-split underflow safety (BOLD leg).**  Identical
       analysis to the ETH leg:
       `poolAmount ≤ amount × maxFeeBps / 10000 ≤ amount / 2`,
       so `userAmount = amount − poolAmount ≥ amount / 2`.
       Safe under `unchecked`.  ✓

    3. **Round-trip exactness.**  `userAmount + poolAmount =
       amount` exactly, with the floor-division residue
       (≤ 9999 BOLD-wei = a tiny fraction of a cent of BOLD)
       accruing to `userAmount`.  ✓

    4. **`budgetGrant` overflow safety (BOLD leg).**
       `rawBudgetGrant = poolAmount / weiPerBudgetUnitBold ≤
       poolAmount ≤ amount ≤ uint256.max` (since
       `weiPerBudgetUnitBold ≥ MIN_WEI_PER_BUDGET_UNIT = 1`).
       The `uint64` cast is gated by the explicit `>
       MAX_BUDGET_PER_DEPOSIT` check.  Identical to ETH-leg
       analysis.  ✓

    5. **Reentrancy safety.**  The function applies both
       `nonReentrant` (existing global guard) and
       `boldCircuitOpen` (new BOLD-specific guard, see
       GP.5.5).  The `transferFrom` call happens BEFORE the
       state mutations, so even if BOLD's `transferFrom`
       were maliciously made to re-enter (which standard ERC-20
       doesn't allow), the reentrancy guard would block the
       second entry.

    6. **No double-counting.**  Each BOLD deposit produces
       exactly one `DepositWithFeeInitiated` event with
       `resourceId = 1`, exactly one `consumed`-record entry
       on L2.  Independent of ETH-path deposits (which use
       `resourceId = 0`).

    7. **Circuit-breaker isolation.**  `boldCircuitOpen`
       modifier is a NEW per-currency circuit breaker added in
       GP.5.5.  When the BOLD-specific circuit is closed
       (e.g., operator-triggered after BOLD depeg detection),
       this function reverts but `depositETHWithFee` continues
       to work.  This isolates a BOLD-side incident from
       affecting the ETH path.

  * **Events.**  Reuses the `DepositWithFeeInitiated` event
    declared in GP.5.1; the `resourceId` field distinguishes
    BOLD (= 1) from ETH (= 0) deposits.  No new event needed.

  * **Tests.**  `solidity/test/BridgeFeeSplitBold.t.sol` (new),
    35+ cases:
    * BOLD-path mirror of every ETH-path test in GP.5.1's
      `BridgeFeeSplit.t.sol` (zero-amount, fee-bounds, tiny
      amounts, max-fee, max-budget-clamp, round-trip,
      reentrancy, TVL-cap).
    * **NEW (BOLD-specific):** non-conformant BOLD mock with
      fee-on-transfer reverts with `BoldTransferAmountMismatch`.
    * **NEW:** revoked allowance reverts the entire deposit.
    * **NEW:** `balanceOf` decreasing during `transferFrom`
      (hypothetical malicious ERC-20) reverts.
    * **NEW:** Circuit-breaker pause of BOLD leg leaves ETH leg
      functional.
    * **NEW:** Calibration parity check — for fixed USD-value
      fee, ETH-path and BOLD-path produce same budget grant
      modulo floor-division residue.
    * **NEW:** Cross-stack differential — same `(amount,
      chosenFeeBps, weiPerBudgetUnitBold)` produces identical
      Solidity vs Lean-fixture `(userAmount, poolAmount,
      budgetGrant)`.

  * **Acceptance criteria.**  **Two reviewers** (touches the L1
    bridge contract with new external-token interaction);
    `forge test --match-path test/BridgeFeeSplitBold.t.sol`
    green; fuzz test with 1000+ inputs across
    `(amount, chosenFeeBps, weiPerBudgetUnitBold)` triples
    passes byte-equivalence against Lean reference.
  * **Dependencies.**  GP.5.1 (shared constructor amendments);
    GP.5.2 (audit gate covers all five immutables);
    GP.4.1 (DepositRecord widening; the resource field is
    already there but now resource = 1 paths must work).
  * **Estimated effort.**  ~14 hours including forge tests.

#### WU GP.5.5: BOLD-specific safety hardening (v1.2)

  * **Status: COMPLETE.**  The three BOLD-specific defence-in-depth
    mechanisms ship in `solidity/src/contracts/KnomosisBridge.sol`:
    (1) the per-currency circuit breaker `boldCircuitClosed` +
    `boldCircuitOpen` modifier (gating `depositBoldWithFee`) toggled by
    `closeBoldCircuit` / `openBoldCircuit`; (2) the permissionless
    Liquity-V2 branch-shutdown auto-trigger
    `closeBoldCircuitIfAnyLiquityBranchShutdown` (opt-in via
    `enableLiquityAutoCircuitTrigger`; reads `shutdownTime()` from
    each of three constitutionally-pinned Liquity V2 collateral-branch
    `TroveManager` contracts — `LIQUITY_V2_TROVE_MANAGER_ETH /
    _WSTETH / _RETH`; closes the circuit if ANY branch reports a
    non-zero `shutdownTime`, the canonical on-chain depeg signal); and
    (3) the per-BOLD TVL cap (`boldTvlCap` + `boldTotalLockedValue`,
    enforced in `_registerDepositWithFee`, adjustable via
    `setBoldTvlCap`).  The interface
    `src/interfaces/ILiquityV2TroveManager.sol` and the test
    `test/BoldCircuitBreaker.t.sol` (85 cases incl. a stateful
    Foundry-invariant suite + a malicious-BOLD reentrancy attack
    test) + the programmable
    `test/utils/MockLiquityV2.sol` (5 mock variants:
    `MockLiquityV2TroveManager` / `WrongSizeLiquityV2` /
    `OversizedLiquityV2` / `ReentrantLiquityV2` / `MutatingLiquityV2`)
    ship alongside.  Implementation notes vs. the design sketch below
    (engineering judgement, in the spirit of GP.5.4's documented
    opt-in deviation):
    1. **Access-control roles are immutable, BOLD-scoped, split, AND
       distinctness-enforced.**  The sketch's `onlyCircuitBreaker` /
       `onlyAdmin` map to two SEPARATE immutable roles —
       `boldCircuitBreaker` (pause/resume only) and `boldAdmin`
       (`setBoldTvlCap` only) — wired as `address public immutable`
       constructor args, mirroring how `attestor` / `disputeVerifier`
       / `migration` are wired (the contract has no generic admin /
       owner / upgrade surface, and the `test_no_admin_surface`
       invariant still holds — the new selectors are not the canonical
       Ownable/UUPS ones).  Splitting the roles is least-privilege:
       the emergency-pause hot key cannot tune the cap and the cap key
       cannot pause.  A BOLD-enabled deployment MUST pass both non-zero
       (`ZeroBoldCircuitBreaker` / `ZeroBoldAdmin`), they MUST be
       distinct addresses (`BoldRolesNotDistinct` — closes the
       single-shared-key collapse), AND neither may be the bridge
       itself (`BoldRoleIsBridge` — closes the self-call footgun).
       A BOLD-disabled deployment leaves them inert
       (`address(0)`, unreachable).
    2. **The depeg signal is "any Liquity branch is in shutdown".**
       The sketch's "Liquity V2 redemption-rate >= 500 bps" threshold
       is REPLACED by the strictly stronger
       `TroveManager.shutdownTime() != 0` signal — the definitive
       on-chain indicator that a Liquity V2 collateral branch has been
       wound down (oracle failure, governance vote, etc.).  Stronger
       because: (a) `shutdownTime` is a Liquity-internal protocol
       event, not market noise; (b) it is binary (zero / non-zero),
       not a continuous threshold prone to calibration error; (c) it
       is monotonic (once set, never resets).  The three TroveManager
       addresses are pinned as compile-time `address public constant`
       values under the GP.5.2 audit gate.  The v1.2 polish adds
       `LIQUITY_ORACLE_READ_GAS` (the 100k staticcall gas cap) to the
       gate as a fourth uintN cap (so the gate now covers 4 caps + 4
       address pins + 1 symbol pin; self-test grows 23 → 37 cases —
       includes a multi-line-declaration tolerance check that
       confirms the gate handles forge-fmt-wrapped address pins
       correctly),
       promotes it to `public constant` (for off-chain monitoring),
       and adds a constructor pairwise-distinctness check on the
       three TM constants (`BoldTroveManagersNotDistinct` — defence
       in depth behind the gate, catching the exact bug class where
       a source-level copy-paste duplicate among the pins would make
       the auto-trigger silently miss a branch).  Runtime pins:
       `test_troveManagerConstants_pinned` +
       `test_liquityOracleReadGas_pinned`.  The
       `BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS` constant is GONE — the
       new signal is binary, not threshold-based.  v1.2 also
       parameterises `LiquityOracleHasNoCode(address)` so operators
       see which branch is missing without bisecting.
    3. **`boldTvlCap` is a constructor arg AND a setter.**  The sketch
       has only `setBoldTvlCap` with storage defaulting to 0; the
       implementation ALSO accepts an initial `boldTvlCap` constructor
       arg (validated `≤ tvlCap` when BOLD enabled) so a deployment
       configures the cap atomically rather than via a risky two-step
       deploy.  The fail-closed property is preserved verbatim: a
       deployer who passes 0 rejects every BOLD deposit until
       `boldAdmin` raises it.
    4. **`boldTotalLockedValue` decrements on BOLD withdrawal.**  The
       counter tracks NET BOLD (deposits − withdrawals), not just
       cumulative inflow — `withdrawWithProof` decrements it (gated on
       `boldEnabled && resourceId == RESOURCE_ID_BOLD`, with the same
       defensive underflow guard as the global `totalLockedValue`).
       Load-bearing for the stated invariant "`boldTotalLockedValue ==
       totalLockedValue` when ETH reserves are 0" — without the
       decrement the per-BOLD cap would ratchet shut even after
       withdrawals freed room.
    5. **Low-level `staticcall` replaces the sketch's `try`/`catch`
       on the oracle read** — strictly more robust.  Each per-branch
       `shutdownTime()` read uses
       `troveManager.staticcall{gas: LIQUITY_ORACLE_READ_GAS}(...)`
       with explicit `ok && data.length == 32` guards.  Every fault
       routes uniformly to `LiquityV2ReadFailed`: (a) revert
       (`ok == false`); (b) no code at target (returns `(true, "")`,
       length-check catches); (c) wrong / oversized return (length-
       check catches — a case Solidity's typed `try`/`catch` does NOT
       route through `catch`); (d) a malicious/mutating callee
       attempting SSTORE under the staticcall context — the EVM
       reverts the inner frame, length-check catches.  Additionally,
       the staticcall is gas-bounded (`LIQUITY_ORACLE_READ_GAS = 100k`,
       generous for a public-storage `shutdownTime` getter) — a
       hardened upper bound on the malicious-TroveManager griefing
       surface: without the cap, the EVM's 63/64-rule would forward
       ~all-but-1/64 of the caller's gas to the inner frame, so a
       buggy / malicious Liquity-V2 upgrade could burn ~30M+ gas per
       call.  With the cap, the worst case is ~300k across all three
       branches.  Pinned mechanically by the grief-bounded gas tests.
       The constructor additionally requires code at all three
       TroveManager pins at deploy time (`LiquityOracleHasNoCode`),
       so deployments on non-Liquity chains MUST leave the
       auto-trigger disabled (`AutoTriggerRequiresBold` covers the
       BOLD-disabled case).
    6. **`MockLiquityV2.sol` houses five mock variants in
       `test/utils/`** (not the sketch's `test/mocks/`) to match the
       existing convention (`MockBold`, `MockERC20`):
       `MockLiquityV2TroveManager` (programmable healthy /
       shutdown / reverting), `WrongSizeLiquityV2` (16-byte return),
       `OversizedLiquityV2` (64-byte return), `ReentrantLiquityV2`
       (view probe during read under staticcall), and
       `MutatingLiquityV2` (attempts SSTORE during read — positively
       demonstrates the staticcall context blocks state mutation).
  * **Goal.**  Add three BOLD-specific defence-in-depth
    mechanisms not present for the ETH path: a per-currency
    circuit breaker, a TVL cap specific to BOLD, and an
    operator-triggered depeg-detection pause.
  * **File:** `solidity/src/contracts/KnomosisBridge.sol`
    (further extension); operator-runbook documentation.
  * **Deliverables (v1.4 plan sketch — SUPERSEDED).**

    > ⚠️ **Historical sketch only.**  The Solidity code in this
    > `Deliverables` block describes the v1.4 plan's
    > redemption-rate-threshold design.  The v1.1
    > **implementation** uses the strictly stronger per-branch
    > `TroveManager.shutdownTime()` signal — see the **Status:
    > COMPLETE** block above for the actual shipped design (3
    > constitutional TM constants, gas-bounded staticcall,
    > role-distinctness + no-self-as-role constructor guards,
    > parameterised `LiquityOracleHasNoCode(address)`, etc.).
    > The sketch is preserved here for plan-amendment history.

    ```solidity
    /// @notice Per-currency circuit breaker for the BOLD leg.
    /// Pauses BOLD deposits and withdrawals independently of
    /// the global circuit breaker.  Toggleable by the
    /// operator's circuit-breaker key.
    bool public boldCircuitClosed;

    /// @notice Per-currency TVL cap for BOLD.  Independent of
    /// the global TVL cap.  Defaults to zero (operator must
    /// explicitly set positive) so a misconfigured deployment
    /// fails closed.
    uint256 public boldTvlCap;

    /// @notice Per-currency current TVL for BOLD (separate
    /// counter from the global `totalLockedValue`).
    uint256 public boldTotalLockedValue;

    modifier boldCircuitOpen() {
        if (boldCircuitClosed) revert BoldDepositPaused();
        _;
    }

    /// @notice Operator-triggered: close the BOLD circuit
    /// when a depeg or other incident is detected.  v1.3 path A.
    function closeBoldCircuit() external onlyCircuitBreaker {
        boldCircuitClosed = true;
        emit BoldCircuitClosed(block.timestamp);
    }

    /// @notice Operator-triggered: reopen the BOLD circuit
    /// after the incident resolves.
    function openBoldCircuit() external onlyCircuitBreaker {
        boldCircuitClosed = false;
        emit BoldCircuitOpened(block.timestamp);
    }

    /// @notice Permissionless auto-trigger: close BOLD circuit if
    /// Liquity V2's redemption rate has exceeded the threshold.
    /// Reads from Liquity V2's BorrowerOperations contract
    /// (or equivalent redemption-rate accumulator) to determine
    /// whether BOLD is currently under peg pressure.  Anyone can
    /// call this; idempotent if already closed.  v1.3 path B —
    /// opt-in per deployment via constructor flag
    /// `enableLiquityAutoCircuitTrigger`.
    function closeBoldCircuitIfRedeemingHeavily() external {
        if (!enableLiquityAutoCircuitTrigger)
            revert AutoCircuitTriggerDisabled();
        if (boldCircuitClosed) return; // idempotent

        // Read Liquity V2's redemption-rate accumulator.  See
        // GP.5.5.1 for the specific Liquity V2 contract address
        // and function signature; documented in the operator
        // runbook with cross-reference to Liquity V2's audit.
        //
        // v1.4 hardening: wrap the cross-contract call in try/
        // catch.  If Liquity V2 reverts (e.g., its read function
        // becomes incompatible after a hypothetical
        // re-deployment), we revert with a specific error rather
        // than propagating the underlying Liquity error.  This
        // makes the failure mode auditable and gives the
        // operator a clear signal to switch to manual-only mode
        // (i.e., call closeBoldCircuit() directly).
        uint256 redemptionRateBps;
        try ILiquityV2Redemptions(LIQUITY_V2_BORROWER_OPS)
            .getRedemptionRate()
            returns (uint256 rate)
        {
            redemptionRateBps = rate;
        } catch {
            revert LiquityV2ReadFailed();
        }

        if (redemptionRateBps <
            BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS)
            revert RedemptionRateBelowThreshold(redemptionRateBps);

        boldCircuitClosed = true;
        emit BoldCircuitClosedByAutoTrigger(
            block.timestamp, redemptionRateBps
        );
    }

    /// @notice Operator-set: bump the per-BOLD TVL cap.
    /// Bounded above by the global TVL cap to prevent
    /// exceeding the deployment's overall reserve commitment.
    function setBoldTvlCap(uint256 newCap) external onlyAdmin {
        if (newCap > tvlCap) revert BoldTvlCapExceedsGlobal();
        boldTvlCap = newCap;
        emit BoldTvlCapUpdated(newCap);
    }

    /// @notice Compile-time threshold for the Liquity-V2-redemption
    /// auto-trigger.  500 bps = 5 % redemption rate sustained at
    /// the time of the call.  Calibrated against Liquity V2's
    /// redemption-rate-accumulator semantics; see operator
    /// runbook for the calibration argument.
    uint256 public constant BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS = 500;

    /// @notice Compile-time pin on the Liquity V2 contract that
    /// exposes the redemption-rate accumulator.  Calibrated
    /// against the deployment-time canonical Liquity V2 address;
    /// changing requires a KnomosisMigration handoff just like the
    /// BOLD token address pin.
    address public constant LIQUITY_V2_BORROWER_OPS =
        0x0000000000000000000000000000000000000000; // <- pin
        // at v1.3 deploy time to the canonical Liquity V2
        // BorrowerOperations contract address.

    /// @notice Immutable per-deployment flag for the auto-trigger.
    /// Some deployments may prefer operator-only override (set
    /// to false); others may want auto-defence (set to true).
    bool public immutable enableLiquityAutoCircuitTrigger;
    ```

    **Author's mathematical soundness check (v1.3 auto-trigger):**
    * The `closeBoldCircuitIfRedeemingHeavily` function is
      idempotent: if already closed, returns without state change.
      Safe to call multiple times.
    * Reentrancy: the function reads from an external contract
      (Liquity V2's BorrowerOperations).  A malicious Liquity
      contract (impossible in practice — Liquity V2 is immutable
      audited code) could in principle reenter, but the only
      state change here is setting `boldCircuitClosed = true`,
      which is monotonic and safe to set redundantly.
    * The compile-time `LIQUITY_V2_BORROWER_OPS` pin must be
      filled with the canonical address at v1.3 deploy time.
      Deployment script should fail loudly if Liquity V2 has not
      been deployed at that address.
    * The `BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS = 500` (5 %)
      threshold is calibrated against Liquity V2's redemption-
      rate semantics.  See operator runbook section X.Y for the
      calibration argument.  Deployments can opt to set
      `enableLiquityAutoCircuitTrigger = false` for full
      operator-manual control.

    The `_registerDepositWithFee` function gains a per-resource
    TVL-cap check:

    ```solidity
    function _registerDepositWithFee(
        uint64 resourceId,
        address token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant
    ) internal {
        uint256 amount = userAmount + poolAmount;
        // Global TVL cap (existing).
        uint256 newTvl = totalLockedValue + amount;
        if (newTvl > tvlCap) revert TvlCapReached();
        totalLockedValue = newTvl;

        // Per-resource TVL cap (NEW for BOLD; n/a for ETH).
        if (resourceId == RESOURCE_ID_BOLD) {
            uint256 newBoldTvl = boldTotalLockedValue + amount;
            if (newBoldTvl > boldTvlCap) revert BoldTvlCapReached();
            boldTotalLockedValue = newBoldTvl;
        }

        // (existing receiptHash + event emission + nonce bump)
    }
    ```

  * **Mathematical-soundness double-check.**

    1. **TVL cap composition.**  The global `tvlCap` bounds
       the SUM of ETH + BOLD reserves.  The per-BOLD
       `boldTvlCap` bounds JUST BOLD's contribution to that
       sum.  Since `boldTvlCap ≤ tvlCap` (constructor-enforced
       by `setBoldTvlCap`), the BOLD cap is *strictly tighter*
       than the global cap, so passing the BOLD check
       guarantees passing the global check (assuming
       `totalLockedValue` already accounts for non-BOLD
       reserves).  In edge case where ETH reserves are 0:
       `boldTotalLockedValue = totalLockedValue` and the two
       caps coincide in effect.  ✓

    2. **Circuit-breaker scope.**  `boldCircuitClosed`
       affects ONLY `depositBoldWithFee` (and any future
       BOLD-specific functions).  The global `circuitOpen`
       (existing) affects all deposits.  So:
       * If global is closed: all deposits halt.
       * If global open, BOLD closed: ETH deposits continue,
         BOLD halts.
       * If both open: both work.
       Defense in depth — neither circuit can override the
       other in a way that bypasses safety.  ✓

    3. **Withdraw-side semantics.**  This WU governs
       deposits.  The withdraw side (sequencer claiming from
       the BOLD pool) is gated by the existing
       `gasPoolPolicy` (kernel-enforced); the L1 contract's
       `withdraw` function still allows BOLD withdrawals
       (otherwise the bridge could not honour the L2 pool's
       outflow).  The BOLD circuit breaker affects ONLY new
       deposits; existing reserves remain redeemable.  This
       is the standard "deposits halted, withdrawals
       continue" pattern from established bridge designs
       (Optimism, Arbitrum) — the right safety posture
       during a depeg event.

  * **Tests.**  `solidity/test/BoldCircuitBreaker.t.sol`
    (new), 18+ cases:
    * BOLD circuit closed → BOLD deposits revert; ETH
      deposits continue.
    * BOLD circuit reopened → BOLD deposits resume.
    * Per-BOLD TVL cap enforced independently of global cap.
    * `setBoldTvlCap` with value > `tvlCap` reverts.
    * Withdrawal works while BOLD circuit is closed.
    * Multi-event-per-block: circuit closes mid-block, second
      BOLD deposit in same block reverts.
    * Access control: non-circuit-breaker cannot toggle.
    * Access control: non-admin cannot set TVL cap.

  * **Operator runbook section** (`docs/gas_pool_runbook.md`):
    * Conditions under which to close BOLD circuit:
      - Off-chain oracle shows BOLD price < $0.95 or > $1.05
        sustained for > 24 hours.
      - Liquity V2 governance announces a parameter change
        that materially alters BOLD economics.
      - Anomalous BOLD inflows / outflows (defined as > 10×
        recent baseline) trigger automatic on-call alert.
    * Procedure for reopening:
      - Wait for off-chain oracle to confirm BOLD back in
        peg band for > 12 hours.
      - Manual sanity check on BOLD pool balance vs
        accounting equation.
      - Open via `openBoldCircuit()`.

  * **Acceptance criteria.**  Two reviewers; `forge test`
    green; operator runbook section reviewed by deployment
    operators.
  * **Dependencies.**  GP.5.4.
  * **Estimated effort.**  ~8 hours.

---

### Phase GP.6 — Rust runtime amendment

#### WU GP.6.1: `knomosis-l1-ingest` event decode

  * **Goal.**  Decode `DepositWithFeeInitiated` events from
    both `depositETHWithFee` and `depositBoldWithFee` (the
    `resourceId` field distinguishes the two; `0` = ETH,
    `1` = BOLD) and translate to `Action.depositWithFee`
    SignedActions byte-equivalently to Lean.
  * **Files:**
    * `runtime/knomosis-l1-ingest/src/events.rs` (add the new event
      signature + decoder, including the `uint64 budgetGrant`
      field at the canonical position and the `uint64
      resourceId` field that drives the per-resource branch).
    * `runtime/knomosis-l1-ingest/src/encoding.rs` (encode the new
      Action variants — `depositWithFee` with 7 fields including
      `budgetGrant`; `topUpActionBudget` with 4 fields — both
      byte-equivalent to the Lean CBE encoder).  The encoder is
      resource-parametric (matches the Lean side); resource = 0
      and resource = 1 produce structurally-identical Action
      bytes with only the `r` field differing.
    * `runtime/knomosis-l1-ingest/src/lib.rs` (wire the new event
      into `ingest`; preserve the existing `BridgeActorKey`
      signing discipline; route BOLD-resource deposits through
      the same SignedAction-emit path as ETH-resource deposits,
      with no per-resource dispatch needed beyond the resource
      field).
  * **Deliverables.**
    * Hex-pinned event topic for `DepositWithFeeInitiated`
      (Keccak256 of the canonical event signature
      `DepositWithFeeInitiated(address,uint64,address,uint256,
      uint256,uint64,uint64,bytes32)`).  Topic hash baked into
      the source as a `pub const` for compile-time pinning.
    * CBE encoder for `Action.depositWithFee` and
      `Action.topUpActionBudget` (mirrors the existing per-Action
      encoder in `encoding.rs`; constructor-tag indices 19, 20
      pinned against the Lean side's regression tests).
    * Differential rustc/Lean encoding test: for a fixed
      `(resource, recipient, poolActor, userAmount, poolAmount,
      budgetGrant, depositId)` tuple, the Rust-emitted CBE bytes
      MUST equal the Lean reference fixture's bytes exactly.
    * Cross-stack fixture corpus extension:
      `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf` (new
      `.cxsf` file with 50+ entries) covering:
      - `chosenFeeBps ∈ {0, 1, 100, 1000, 2500, 5000}`
        (sample across the realistic operator range).
      - `msg.value ∈ {1, 10⁹, 10¹⁵, 10¹⁸, 10²¹}` (sample across
        wei magnitudes from "rounding edge case" to "whale").
      - `weiPerBudgetUnit ∈ {1, 10⁶, 10¹², 10¹⁵}` (sample
        across exchange-rate magnitudes).
      - Each entry includes the L1-side
        `(userAmount, poolAmount, budgetGrant)` *and* the
        expected L2-side ingested SignedAction CBE bytes,
        pinned via the Lean reference generator.
  * **Mathematical-soundness double-check.**
    The `budgetGrant` field is `uint64` on the L1 wire; the
    Lean `Action.depositWithFee` carries `Nat`.  Decoding is
    `Nat.ofUInt64`, which is total and injective on the
    `[0, 2⁶⁴ - 1]` range.  No information loss across the
    crossing.  The Rust → Lean cross-stack fixture corpus
    pins the byte-equivalence for the full action encoding,
    including the budgetGrant 8-byte LE-Nat head.
  * **Tests.**  ~40 cases (+15 vs v1.0 for the cross-stack
    enumeration above).
  * **Acceptance criteria.**  One reviewer; `cargo test
    --workspace --locked` green; clippy / fmt green; differential
    Rust ↔ Lean fixture comparison green for all 50+ entries.
  * **Dependencies.**  GP.5.1.
  * **Estimated effort.**  ~14 hours (v1.0 estimated 10; +4 for
    the wider fixture matrix and the differential harness).
  * **Status: COMPLETE.**  Lands the Rust-side mirror of the
    Workstream-GP encoder family.  Highlights:
    * **`Action` enum extended** (`runtime/knomosis-l1-ingest/
      src/action.rs`).  Three new variants matching the Lean-side
      frozen tag indices: `DepositWithFee` (tag 19, 7 fields),
      `TopUpActionBudget` (tag 20, 4 fields), `TopUpActionBudgetFor`
      (tag 21, 5 fields).  Each variant's `tag()` projection is
      pinned by a regression test; the three GP-family tags are
      pairwise-distinct by construction.
    * **CBE encoder arms** (`runtime/knomosis-l1-ingest/
      src/encoding.rs`).  Each new variant gets an encoder match
      arm that mirrors the Lean side's `Encoding/Action.lean::
      Action.encode` byte-for-byte: constructor-tag uint head
      followed by each field's CBE uint head, in declaration order.
    * **Hex-pinned event topic constants** (`runtime/knomosis-
      l1-ingest/src/events.rs`).  The WU deliverable
      `DEPOSIT_WITH_FEE_INITIATED_TOPIC` (and the four sibling event
      topics) are baked into the source as `pub const` 32-byte
      arrays; `EventTopic::hash()` is now a `const fn` returning the
      pinned constant rather than recomputing keccak256 per call
      (matching the RH-G observer's hard-pinned-topic discipline).
      The `topic_constants_match_keccak_of_signature` test verifies
      each constant equals `keccak256(signature())`, so a
      signature-string edit or keccak-binding regression is caught
      mechanically.
    * **Lean-sourced differential — the load-bearing cross-stack
      pin.**  `LegalKernel/Test/Bridge/CrossCheck/
      DepositWithFeeAction.lean` emits
      `solidity/test/CrossCheck/fixtures/deposit_with_fee_action.json`
      (18 vectors across all three GP-family constructors), whose
      `expectedCbe` field is computed by running LEAN's
      `Encoding.Action.encode`.  The Rust consumer
      `runtime/knomosis-l1-ingest/tests/cross_stack_lean_action.rs`
      (4 cases) reconstructs each `Action` and byte-matches its own
      `encode_action` against the Lean bytes — a genuine Lean → Rust
      byte-equivalence, not a Rust self-comparison.  The Lean
      generator additionally hand-pins the canonical depositWithFee
      vector to ground truth so the equivalence is non-circular.
    * **Hand-pinned known-vector tests** (`encoding.rs`) — four
      vectors pin the per-variant byte layouts at hand-computed
      values (e.g. the 72-byte depositWithFee stream spelled out as
      8 × 9-byte CBE uint heads), one pinning the ETH/BOLD
      resource-parametric byte-equivalence (only byte 10 differs).
    * **`FeeSplitInput` type + arithmetic** (`runtime/knomosis-
      l1-ingest/src/fixture.rs`).  A 58-byte fixed-width input shape
      (with a compile-time `assert!` tying the declared width to the
      field-width sum) carrying the L1 fee-split inputs.
      `FeeSplitInput::split` produces the `(user_amount, pool_amount,
      budget_grant)` triple byte-equivalently to the L1 contract's
      recipe and the Lean side's `feeSplit` reference; the
      conservation / pool-cap / budget-cap invariants from Lean's
      `feeSplit_conserves` / `feeSplit_pool_le` /
      `feeSplit_budget_le_max` are mirrored by per-entry assertions
      AND a `proptest` over random inputs.  The
      `wei_per_budget_unit = 0` guard returns `0`, byte-equivalent
      to Lean's `Nat.div_zero` (an earlier draft returned the cap —
      a cross-stack divergence — now fixed and regression-pinned).
    * **`FixtureKind::L1IngestFeeSplit` (tag 6)** added to
      `knomosis-cross-stack`.  Round-trips through `from_tag` /
      `to_tag`; tag distinctness pinned by a regression test.
    * **Cross-stack fixture corpus** `runtime/tests/cross-stack/
      l1_ingest_fee_split.cxsf` (249 entries: 240 from the 5×6×4×2
      grid covering `msg_value ∈ {1, 10⁹, 10¹², 10¹⁵, 10¹⁸}`,
      `chosen_fee_bps ∈ {0, 1, 100, 1000, 2500, 5000}`,
      `wei_per_budget_unit ∈ {1, 10⁶, 10¹², 10¹⁵}`,
      `resource_id ∈ {0, 1}`, plus 9 boundary cases including
      two `msg_value = u64::MAX` entries — one whole-on-user and one
      50%-fee exercising BOTH legs near the bound — rounding edges,
      exact-half split, budget clamp, residue-favours-user, and
      ETH/BOLD economic-scale entries).  Note: the WU's original
      `msg.value` ceiling of `10²¹` was capped at `10¹⁸` (grid) +
      `u64::MAX` (boundary) because `2^64 ≈ 1.84 × 10¹⁹` is the Lean
      `Action.fieldsBounded` encoder bound — a `10²¹`-wei deposit is
      unencodable as an L2 Action and is rejected by the L1 TVL cap.
    * **Generator example + `--check` drift gate**
      (`examples/gen_fee_split_fixtures.rs`).  Reproduces the corpus
      deterministically; `--check <path>` regenerates in-memory and
      exits non-zero on any byte-drift from the committed file.
      Wired into `.github/workflows/ci-rust.yml` as a dedicated
      step, so a hand-edit of the `.cxsf` or a generator change that
      was not re-run is caught in CI.  The generator panics (rather
      than silently skipping) if any entry exceeds the encoder bound.
    * **Consumer test** `cross_stack_fee_split.rs` (8 cases:
      round-trip, ≥50-record coverage threshold with ETH+BOLD
      presence, conservation/pool-cap/budget-cap mathematical
      soundness, ETH/BOLD resource-parametric byte-equivalence,
      ETH/BOLD split-arithmetic parity, input round-trip, encoder
      determinism, per-record DepositWithFee tag pin).
    * **`proptest` coverage** (`tests/property.rs`, 6 new
      properties): per-variant encoder determinism + layout-width
      invariants for all three constructors, depositWithFee ETH/BOLD
      resource-parametric byte-equality over random fields, the
      `topUpActionBudget` ↔ `topUpActionBudgetFor` tag-separation,
      and the fee-split conservation/pool-cap/budget-cap invariants
      over a wide random input band.
    * **Translation untouched.**  Per the MVP-scope semantics
      (deposit materialisation is the sequencer's responsibility,
      not the ingestor's, mirroring Lean's `Bridge.Ingest.ingest`),
      `DepositWithFeeInitiated` continues to translate to
      `Translated::NoAction`.  Emitting an `Action` here would
      DIVERGE from the Lean reference; the encoder additions stand
      alone, ready for the future sequencer-side action emission.
    * **Decoder strict-length contract.**  `decode_fee_split_input`
      requires EXACTLY `FEE_SPLIT_INPUT_BYTES = 58` bytes — a
      shorter input returns `FixtureError::UnexpectedEnd`, a longer
      input returns the new `FixtureError::TrailingBytes`
      (rather than silently truncating).  Catches a schema-drift
      producer that emits an oversized payload.  Tested in both
      directions, plus an exact-length-decodes-cleanly boundary.
    * **Schema-drift defence on the Lean JSON consumer.**  The
      `cross_stack_lean_action.rs` consumer's `Header` / `Entry` /
      `Fixture` structs all carry `#[serde(deny_unknown_fields)]`,
      so a Lean generator that adds, renames, or removes a key
      surfaces as a typed deserialisation failure rather than
      silently ignored.  The header's `identifier` is pinned by
      `lean_action_corpus_identifier_matches` against the constant
      `EXPECTED_FIXTURE_IDENTIFIER = "knomosis-l1-ingest/
      deposit-with-fee-action/v1"` — a generator-side version bump
      then requires an explicit Rust-side consumer update.  Each
      entry's per-kind reconstruction additionally `forbid`s every
      wrong-variant field (e.g. a `depositWithFee` entry with a
      spurious `gasResource` fails the byte-equivalence test with a
      clear "wrong-variant cross-contamination" message), so a
      flat-shape generator bug that mixes constructor fields cannot
      go unnoticed.
    * **Arithmetic-faithfulness audit.**  `FeeSplitInput::split`
      mirrors Lean's `feeSplit`: `saturating_sub` is the EXACT
      mirror of Lean's truncated `Nat` subtraction, and the
      pool-fee multiply uses an explicit `checked_mul` (not a
      comment-justified `saturating_mul`) — the `None` arm is
      unreachable for any encodable deposit (`msg_value < 2^65 ⇒
      product < 2^81 ≪ u128::MAX`) and, if hit by an out-of-domain
      input, surfaces a `pool >= 2^64` that `to_action` rejects, so
      a pathological / corrupt-fixture `msg_value` is REJECTED,
      never mis-encoded, and never panics.  Pinned by
      `fee_split_overflow_path_rejects_without_panic` (u128::MAX ×
      u16::MAX) and `fee_split_encodable_boundary_is_exact_and_conserves`
      (the `2^64 - 1` ceiling at 50% fee: exact, conserving,
      encodable).
    * **PR-review hardening (PR #99).**  Two automated-review P2s
      addressed: (1) `to_action` now rejects a non-conservative fee
      (`chosen_fee_bps > MAX_ADMISSIBLE_FEE_BPS = 10000`) — above
      that ceiling the pool leg exceeds `msg_value` and the
      truncating user leg collapses to 0, so the helper would emit a
      `DepositWithFee` crediting more than the deposit; the guard
      lives in the Action constructor (not `split`, which stays
      Lean-faithful for all bps).  (2) The Lean→Rust differential
      consumer fails (not skips) when the committed fixture is
      absent UNDER CI (`CI` env present), and the fixture's path is
      added to `ci-rust.yml`'s trigger filters, so a PR that
      regenerates / moves / deletes only the fixture still runs the
      byte-equivalence check.
    * **Test deltas.**  `knomosis-l1-ingest` grows to ~293 tests
      (lib + 4 cross-stack suites + integration + 17 property);
      the workspace `cargo test --workspace --locked` reports ~1498
      tests passing.  `lake test` green (Lean generator's verify
      mode confirms the committed JSON is byte-stable); `lake build`
      warning-free; `cargo clippy --workspace --all-targets -- -D
      warnings` and `cargo fmt --all -- --check` green.

#### WU GP.6.2: `knomosis-host` admission gate

  * **Goal.**  Add the per-actor budget admission gate to the
    knomosis-host CommandKernel / MockKernel.
  * **File:** `runtime/knomosis-host/src/kernel.rs` and
    `runtime/knomosis-host/src/budget.rs` (new module).
  * **Deliverables.**
    * Rust mirror of `ActorBudget` / `EpochBudgetState` (byte-
      equivalent CBE encoding to the Lean side).
    * `Budget` field on `MockKernel` for testing.
    * `CommandKernel` extension: pass `--budget-policy bounded
      --free-tier N --epoch-duration-seconds D` through to the
      `knomosis` binary.
    * New verdict variant on the wire: optional reason string
      `"InsufficientBudget"` (folded under existing
      `NotAdmissible` verdict per the wire-format-stability
      decision; see §10 OQ-GP-3).
  * **Tests.**  ~30 cases.
  * **Acceptance criteria.**  One reviewer; `cargo test` green.
  * **Dependencies.**  GP.6.1, GP.3.2.
  * **Estimated effort.**  ~14 hours.
  * **Status: COMPLETE.**  Lands the Rust-side budget admission gate
    for `knomosis-host` plus the Lean-side flag plumbing that makes
    the `CommandKernel` pass-through functional end-to-end.
    Highlights:
    * **New `runtime/knomosis-host/src/budget.rs` module** — the
      byte-equivalent Rust mirror of the Lean budget ledger.
      `BudgetPolicy` (mirror of `Authority.BudgetPolicy`, with
      `mk_bounded`'s `action_cost >= 1` clamp), `ActorBudget`
      (mirror of `Authority.ActorBudget`, with `normalise` /
      `consume` / `top_up` copied transition-for-transition from
      `Authority/ActorBudget.lean`), and `EpochBudgetState` (mirror
      of the `TreeMap ActorId ActorBudget`, backed by a
      `BTreeMap<u64, _>` so iteration is ascending-by-actor like the
      Lean `TreeMap`).  Each carries an `encode()` that is
      byte-for-byte equal to its Lean counterpart
      (`ActorBudget.encode`, `BudgetPolicy.encode`, and the
      `encodeSortedPairs` map form embedded in
      `ExtendedState.encode`).
    * **Byte-exact cross-stack pin (non-circular).**  Hand-computed
      known vectors are pinned on BOTH sides: single-byte (Rust
      `actor_budget_encode_known_vector` /
      `budget_policy_encode_known_vector` /
      `epoch_budget_state_encode_known_vector`; Lean
      `actorBudgetEncodeKnownVector` /
      `budgetPolicyEncodeKnownVector` /
      `epochBudgetsMapEncodeKnownVector`), a multi-byte LE vector
      (Rust `actor_budget_encode_multibyte_le` + Lean
      `actorBudgetEncodeMultibyteKnownVector`, an explicit 8-byte LE
      literal for a `0x0102…` / `0x1122…` cell), and an
      unsigned-`UInt64`-ordering pin at the `2^63` boundary (Rust
      `epoch_budget_state_orders_keys_unsigned` + Lean
      `epochBudgetsLargeKeyOrdering`) confirming the `TreeMap` /
      `BTreeMap<u64>` map order agrees across the full `u64` range
      (`LegalKernel/Test/Encoding/State.lean`, `encoding-state` suite
      28 → 33 cases).  Both sides assert the SAME hand-rolled byte
      layout (built from an independent helper / explicit literal,
      not the production encoder), so the byte-equivalence is
      mechanically guaranteed in both directions.
    * **`BudgetGate` + `decode_budget_view`.**  A
      `SignedActionBudgetView` decoder parses the budget-relevant
      projection (signer + `ActionBudgetKind`) of a CBE-encoded
      `SignedAction` by walking the frozen per-variant field layout
      (panic-free; the nested-encoding `dispute` / `verdict` /
      `declareLocalPolicy` variants 8 / 10 / 15 report a typed
      `UnsupportedActionTag`).  `BudgetGate::evaluate` /
      `admit` mirror the budget-ledger portion of
      `apply_admissible_with_budget`: the bridge-actor
      consume-exemption, the per-action consume, the per-action
      budget-grant arms (`depositWithFee` → recipient,
      `topUpActionBudget` → signer, `topUpActionBudgetFor` →
      recipient), and every balance- and policy-INDEPENDENT
      signer-correlation safety conjunct
      (`signer != bridgeActor` / `!= poolActor`, `recipient !=
      signer`, `gasAmount > 0`, `depositWithFee` bridge-signed).
      The two state-dependent conjuncts (`getBalance >= gasAmount`,
      `delegatedTopUpConsentBool`) are documented as DEFERRED to the
      authoritative Lean kernel reached via `CommandKernel` — the
      mock gate is a faithful but strictly-weaker admission
      predicate, the correct posture for a test/dev kernel.
    * **`MockKernel` budget gate.**  `set_budget_gate` /
      `set_budget_policy` / `clear_budget_gate` / `budget_for`.
      The gate is the LAST admission check: an otherwise-`Ok`
      submission is driven through the decoded gate, and an
      exhausted budget folds into `Verdict::NotAdmissible` with the
      wire-stable reason `"InsufficientBudget"` (OQ-GP-3).  An
      unmodelled action fails closed; malformed CBE yields
      `ParseError`.  Pre-GP.6.2 mock behaviour is preserved exactly
      when no gate is installed.
    * **`CommandKernel` flag pass-through.**  `with_budget_policy`
      stores the policy and forwards `--budget-policy bounded
      --free-tier N --action-cost C --current-epoch E` ahead of the
      `process` subcommand.  (The plan's v1.4 `--epoch-duration-
      seconds D` sketch is mapped to the GP.3.1-implemented
      `BudgetPolicy.bounded freeTier actionCost currentEpoch` shape,
      whose epoch is an explicit index per OQ-GP-4, not a duration.)
    * **Lean `Main.lean` consumes the flags.**  `parseGlobalFlags`
      now returns a `GlobalFlags` bundle that parses the four budget
      flags and assembles the genesis `BudgetPolicy`
      (`GlobalFlags.budgetPolicy?` / `genesis`); the policy is
      threaded into every `demoGenesis`-consuming subcommand
      (`process` / `replay` / `bootstrap` / `snapshot` /
      `replay-up-to` / `export-cell-proofs` /
      `export-terminate-bundle`) so the budget gate that GP.3.2
      wired into `processSignedActionWith` / `replayWith` enforces
      the configured policy instead of the deny-all genesis default
      (`.bounded 0 1 0`).  Without any budget flag the genesis is
      byte-identical to the pre-GP.6.2 default.  Operator discipline
      (mirrors `--deployment-id`): the same flags MUST be supplied
      across restarts, because the policy participates in the
      per-log-entry post-state hash — a divergent policy fails replay
      loudly with a post-state-hash mismatch rather than silently
      diverging.  `knomosis help` documents all four flags (including
      the `--current-epoch >= 1` free-tier-grant gotcha).
    * **Test deltas.**  `knomosis-host` grows from ~183 to ~245
      tests: `budget.rs` (44 unit tests — single- + multi-byte
      encoding known vectors, the unsigned-key-ordering pin,
      `ActorBudget` / `EpochBudgetState` semantics mirroring the
      Lean lemmas, the decoder incl. a fuzz-style never-panics
      sweep + a multi-byte signer, and the gate incl. every safety
      conjunct + per-actor isolation + grant arms + a multi-actor
      trace), `config.rs` (7 tests — flag parse / assemble / clamp /
      unknown-mode reject / non-numeric reject), `kernel.rs` (3
      `CommandKernel` argv-capture tests proving the flag contract
      hermetically via an argv-echoing stub), `main.rs` (2
      `build_kernel` tests proving the daemon wires the policy into
      both kernels), and `tests/integration.rs` (6 end-to-end
      wire-path tests driving the gate through the full server so
      `InsufficientBudget` folds into the on-wire `NotAdmissible`).
      `cargo test --workspace --locked` (~1560 tests),
      `cargo clippy --workspace --all-targets -- -D warnings`, and
      `cargo fmt --all -- --check` all green; `lake build`
      warning-free; `lake test` green.

#### WU GP.6.3: `knomosis-event-subscribe` new event variants

  * **Goal.**  Stream the three new event variants
    (`depositWithFeeCredited`, `actionBudgetTopUp`, `gasPoolClaim`)
    to subscribers.
  * **File:** `runtime/knomosis-event-subscribe/src/lib.rs` etc.
  * **Deliverables.**  Updated event-type registry; wire-format
    extension (additive; new event tags 16/17/18 emit at the
    existing 9-byte framing — no protocol-version bump needed
    per the existing event-subscribe additive-extension policy).
  * **Tests.**  ~15 cases.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.6.1.
  * **Estimated effort.**  ~6 hours.
  * **Status: COMPLETE.**  Lands the Rust-side awareness of the
    Workstream-GP event variants in the event-subscription streamer.
    Design note: `knomosis-event-subscribe` is an opaque-byte
    *transport* — it tails the log, delegates event extraction to
    the Lean wire-format authority (`knomosis extract-events`,
    deferred), and forwards the resulting CBE-encoded `Event`
    payloads to subscribers VERBATIM.  It deliberately does NOT
    decode event *fields* (that is the indexer's job —
    `knomosis-indexer::decoder` — and a second field decoder would
    risk drift from the Lean reference).  So "streaming the new
    variants" already worked transparently before this WU; what was
    missing was (a) a Rust-side, checkable record of the canonical
    event-tag space (the "event-type registry"), and (b) a
    mechanised — not merely documented — proof that the additive
    extension streams without a protocol bump.  Both ship here.
    Highlights:
    * **Event-type registry** (`runtime/knomosis-event-subscribe/
      src/event_type.rs`, new module).  An `EventType` catalogue
      mirroring Lean's `Event.tag` over the full frozen index space
      `0..=19` — including the gas-pool family `depositWithFeeCredited`
      (16), `actionBudgetTopUp` (17), `gasPoolClaim` (18), and the
      GP.3.4 `delegatedActionBudgetTopUp` (19).  (The WU title's
      "three new event variants" predates GP.3.4; the registry
      faithfully mirrors the CURRENT Lean inductive, so it carries
      all four, with `KNOWN_EVENT_TAG_COUNT = 20`.)  Provides
      `from_tag` / `tag` / `name` (the canonical lowerCamelCase Lean
      constructor names) / `is_gas_pool_family` (tags 16..=19) and a
      frozen-order `ALL_EVENT_TYPES` array with `ALL[i].tag() == i`.
    * **Drift-safe tag peek.**  `peek_event_tag` reads ONLY the
      leading 9-byte CBE uint head (`0x00` tag byte + 8-byte LE
      constructor index) — the same `HEAD_LEN`/`CBE_TAG_UINT`
      convention `knomosis-indexer::decoder` and
      `knomosis-l1-ingest::encoding` use — and decodes no fields, so
      it cannot drift from the (deferred) Lean `Encodable Event`
      field layout.  This is exactly the "existing 9-byte framing"
      the WU references: tags 16/17/18/19 fit the same head, so the
      wire format is unchanged and `PROTOCOL_VERSION` stays at 1.
    * **Forward-compatible classifier.**  `EventClass::classify` is
      total and NON-rejecting: `Known(EventType)` for a recognised
      tag, `Unknown { tag }` for a syntactically valid head whose
      tag is not yet known (a FUTURE Lean tag lands here and STILL
      streams), and `Unparseable(EventTagError)` for a malformed
      head — all three forward the payload verbatim.  The
      additive-extension policy is mechanised in code, not just
      asserted in prose.
    * **Observability hook** (`src/server.rs`).  The extractor loop
      classifies each streamed event by type for `trace`-level
      diagnostics, guarded behind a `tracing::enabled!(Level::TRACE)`
      check so production info/debug levels pay nothing.
      Classification NEVER affects which events are streamed.
    * **Tests — 25 new cases** (target was ~15): 18 in the
      `event_type` module (frozen-tag pins, `from_tag` round-trip,
      unknown-tag `None`, gas-pool-family classification, name
      pins matching the Lean constructors, distinctness, head-peek
      reads / truncation / bad-tag, a non-circular hand-spelled
      head-byte-layout pin proving the `0x00`-tag + 8-byte-LE
      convention, `classify` Known/Unknown/Unparseable + never-panics
      + `event_type`/`Display` projections); 3 end-to-end
      integration cases in `tests/integration.rs` (the four
      gas-pool-family payloads stream byte-for-byte verbatim; a
      future/unknown tag 50 streams verbatim; a mixed legacy +
      gas-pool multi-event-per-frame batch streams in order); and 4
      `proptest` cases in `tests/properties.rs` (`peek_event_tag` /
      `classify` never panic on arbitrary bytes; the head peek reads
      the tag regardless of arbitrary trailing field bytes; and
      `classify` agrees with `from_tag` for any `u64` tag).  The
      `knomosis-event-subscribe` suite grows from 177 to 202 tests
      (lib 151 → 169, integration 18 → 21, properties 8 → 12);
      `cargo test -p knomosis-event-subscribe --locked`,
      `cargo clippy -p knomosis-event-subscribe --all-targets -- -D
      warnings`, and `cargo fmt -- --check` are all green, and the
      reverse-dependency `knomosis-indexer` still builds (the WU
      only ADDS a public module; no existing API changed).
    * **Full RH-D closure (this WU, extended).**  Beyond the
      Rust-side registry, GP.6.3 closes the RH-D Lean deferral end to
      end — the `Event` CBE encoder + the `extract-events` subcommand
      no longer "deferred Lean-side work":
      - **Lean `Encodable Event`** (`LegalKernel/Encoding/Event.lean`).
        The canonical CBE wire codec for `Event` (encode + decode +
        `instEncodableEvent`), matching `knomosis-indexer::decoder`'s
        field layout BYTE-FOR-BYTE — including tag 11
        (`localPolicyDeclared`), whose `policy` is a CBE byte string
        wrapping `LocalPolicy.encodeAsBytes` (the indexer's "opaque
        policy bytes" `read_byte_string` contract; a structured
        `Encodable LocalPolicy` would not lead with the `0x02`
        byte-string tag and would fail to decode Rust-side).  Carries
        the load-bearing `Event.tag_matches_encode_tag` theorem (every
        encoding leads with `Encodable.encode (T := Nat) (Event.tag e)`
        — the exact contract `peek_event_tag` relies on; `#print
        axioms` = `[propext]`).  Suite `encoding-event` (10 cases):
        per-constructor round-trip, a non-circular `gasPoolClaim`
        ground-truth byte pin, the tag-11 policy-byte-string pin,
        tag-agreement, distinctness, unknown-tag rejection,
        total-decode.
      - **`knomosis extract-events --log LOG` subcommand**
        (`Main.lean::cmdExtractEvents` + the `extractEventsStepWith`
        core in `LegalKernel/Runtime/EventStream.lean`).  The stateful
        stdin/stdout streaming driver the production
        `SubprocessExtractor` shells out to; reconstructs each frame's
        post-state via the FULL bridge-aware admission path
        (`replayStepWith`, NOT `kernelOnlyApply` — which would drop
        bridge events like `withdrawalRequested`'s post-state-derived
        `withdrawalId`) and emits exactly the events
        `Loop.processPure` would.  Suite `runtime-extract-events`
        (9 cases): the runtime↔extract-step event + post-state
        agreement (incl. a bridge `deposit` proving the full path),
        a two-step chain, chain-break rejection, API stability +
        the `extractEventsStepWith_state_eq_replayStepWith` theorem,
        and the pure wire-framing pins (`beU64` / `beU32` / `beToNat`
        big-endian + round-trip + `encodeExtractResponse` byte
        layout — these helpers live in `EventStream` so the
        stdin/stdout response format is unit-testable, not buried in
        `Main.lean`).
      - **Lean→Rust cross-stack differentials (real Lean bytes).**
        The Lean generator
        `LegalKernel/Test/Bridge/CrossCheck/EventCbe.lean` emits
        `solidity/test/CrossCheck/fixtures/event_subscribe_cbe.json`
        (25 entries: 20 canonical + 5 gas-pool edge), whose
        `expectedCbe` is REAL Lean `Event.encode` hex.  Two Rust
        consumers verify it: (a)
        `knomosis-event-subscribe/tests/cross_stack_lean_event.rs`
        (5 cases) asserts `peek_event_tag` / `classify` read the
        correct tag/name for all 20 constructors, with a live
        `header.knownTagCount == KNOWN_EVENT_TAG_COUNT` registry-sync
        gate; (b)
        `knomosis-indexer/tests/cross_stack_lean_event.rs` (2 cases) —
        the FULL field-level proof — runs the indexer's `decode_event`
        on tags 0..15 and asserts `encode_event` reproduces the Lean
        bytes byte-for-byte (Lean→decode→re-encode round-trip; the
        gas-pool tags 16..19 must decode to the typed `UnknownTag`).
        Consumer (b) is what mechanically catches a tag-11-style
        layout drift between Lean and the indexer.  Suite
        `crosscheck-event-cbe` (5 cases) is the Lean-side verify-mode
        generator.
      - **Stats observability (replaces the trace-only hook).**
        `EventStreamStats` (per-type atomic stream counters) is
        tallied by the extractor loop for every streamed event (O(1)
        head peek) and summarised at shutdown; an integration test
        reads the shared `Arc<EventStreamStats>` after streaming GP-
        family + unknown events.  `from_tag` was refactored to a
        drift-safe `const fn` scan of `ALL_EVENT_TYPES`.
      - **Real-binary smoke** (`tests/real_knomosis_extract_events.rs`,
        2 gated cases): the built `knomosis extract-events` exits 0 on
        clean EOF and non-zero on a truncated request.
      The `knomosis-event-subscribe` suite grows 177 → 214,
      `knomosis-indexer` adds its 2-case cross-stack round-trip, and
      the Lean suite adds 24 cases across the 3 new suites
      (`encoding-event` 10 + `runtime-extract-events` 9 +
      `crosscheck-event-cbe` 5).  The extract-events arm uses the same
      verify-parameterised / `mockVerify` test posture as
      `replay-up-to` (the dev binary's `Verify` opaque returns
      `false`; production links the real verifier).
      - **PR #101 review fixes (production correctness).**  An
        automated review found that the daemon drove the subprocess
        without the deployment config, so the subcommand only worked
        for default deployments.  Fixed Rust-side (the Lean binary
        already accepts the relevant global flags):
        * **Deployment config forwarded.**  The
          `knomosis-event-subscribe` daemon gains `--deployment-id`,
          `--budget-policy` / `--free-tier` / `--action-cost` /
          `--current-epoch`, and `--epoch-length`;
          `Config::extractor_global_args` builds the pass-through argv
          and `SubprocessExtractor::with_global_args` PREPENDS it
          before `extract-events`.  This makes signature replay use
          the right domain (else a non-empty-deployment-id log halts)
          and the budget gate / `<LOG>.budgetcfg` sidecar check use
          the right policy (else a budget-enabled log exits 2).
        * **Event-count cap raised** 1024 → 2^20 (the old rationale
          assumed ~10 events/action, wrong for `distributeOthers` /
          `proportionalDilute`, which emit one event per affected
          actor), with the count-driven pre-allocation clamped to a
          bounded `EVENT_BATCH_PREALLOC` so a large declared count
          cannot trigger a large up-front allocation.
        * **Tests.**  `knomosis-event-subscribe` 214 → 219: config
          flag-parse + `extractor_global_args` ordering +
          invalid/missing-flag rejection, a Unix spawn-argv test (a
          fake binary records its argv, proving the global flags
          precede `extract-events`), and the raised-cap pin.

#### WU GP.6.4: `knomosis-storage` / `knomosis-indexer` budget view

  * **Status.** **Complete (v2.1).**  The deep-audit response
    has shipped end-to-end:
    * Stage A — Lean kernel `Event.budgetConsumed` at tag 20 +
      `extractEvents` emission per the GP.3.2 admission gate +
      Encoding/Event encode/decode arms + `tag_matches_encode_tag`
      proof + regenerated `event_subscribe_cbe.json` fixture.
    * Stage B — knomosis-storage `migration_002_budget_views`
      creates FIVE physical SQLite tables (`actor_budgets` +
      `actor_budgets_current_epoch_grants` +
      `actor_budgets_current_epoch_consumed` + `pool_balances_eth` +
      `pool_balances_bold`) + new `BudgetStorage` trait for typed
      read access + `BudgetStorageTransaction` for typed writes.
    * Stage B+ — `SqliteCombinedTransaction` (atomic kv + budget
      tables tx primitive) + `CombinedStorage` / `CombinedTransactionOps`
      traits for test-harness abstraction.
    * Stage C — knomosis-indexer's `apply_batch` REWRITTEN to
      use `SqliteCombinedTransaction`: balance ops + budget ops +
      cursor advance all commit atomically together in a single
      `BEGIN IMMEDIATE ... COMMIT`.  The v1 keyspace dispatch is
      removed; the new SQL tables are the production storage.
      Indexer<S: IndexerStorage> stays generic (test harnesses
      can wrap via FaultyStorage<S: CombinedStorage>).  New
      `Indexer::open_with_config` accepts `gas_pool_actor` +
      `epoch_length`.
    * Stage D — Rust tag-20 wiring through event-subscribe
      registry + indexer event enum + decoder/encoder arms +
      cross-stack fixture round-trip verification at tag 20.
    * Stage E — CLI flags `--gas-pool-actor <id>` +
      `--epoch-length <N>` + `--verify-budget-against-knomosis
      <URL>` (stub) on the daemon; new subcommands
      `query-budget <actor> [--free-tier <N>]`, `query-pool-eth
      <actor>`, `query-pool-bold <actor>` for operator queries.
    * Stage G — property tests
      (`tests/budget_property.rs`): 4 proptest cases generate
      random GP-family event sequences and assert byte-for-byte
      equality against a reference HashMap model
      (single-batch / multi-batch / drain-wired /
      epoch-advancement).
    * Stage H — concurrency tests
      (`tests/budget_concurrency.rs`): 5 tests cover
      multi-reader same-value, reader-monotone-atomic-updates,
      concurrent-writers-serialise, reader-blocks-during-writer,
      balance-and-budget-views-consistent-after-commit.
  * **Goal.**  Provide an optional per-actor budget view in the
    indexer so a deployment UI can show "you have N actions
    remaining this epoch."
  * **File:** `runtime/knomosis-indexer/src/budget_view.rs` (new,
    landed).  Plus extensions to:
    `runtime/knomosis-indexer/src/event.rs` (widen the `Event`
    enum from tags 0..=15 to 0..=20 — the four GP-family tags
    plus the v2.1 Stage-A `BudgetConsumed` (20) — add
    `BudgetUnits` alias and the `RESOURCE_ID_ETH` /
    `RESOURCE_ID_BOLD` constants);
    `runtime/knomosis-indexer/src/decoder.rs` (add per-variant
    encoder + decoder arms for the four new GP-family tags +
    the budget-unit checked-encoder variant); and
    `runtime/knomosis-indexer/src/indexer.rs` (wire the new
    `BudgetViewTx` dispatch pass into `apply_batch` so the
    balance + budget updates commit atomically together).
  * **Deliverables — shipped.**  Three new logical "tables"
    materialised as distinct keyspace prefixes in the underlying
    `knomosis-storage` KV store (vs. the plan's prose "SQLite
    tables" — the actual storage abstraction uses a single
    keyspace already, and the per-table separation is achieved
    by non-overlapping byte prefixes that are pairwise distinct
    from `b/` (balance) and `c/` (cursor)):
    * `actor_budgets` (prefix `u/`, 10-byte key, 16-byte BE u128
      value): per-actor cumulative budget grants.
    * `pool_balances_eth` (prefix `pe/`, 11-byte key): per-(pool
      actor) cumulative ETH (resource 0) pool credits.
    * `pool_balances_bold` (prefix `pb/`, 11-byte key):
      per-(pool actor) cumulative BOLD (resource 1) pool credits.

    All three values use the same 16-byte BE u128 cell shape as
    the balance view, so a deployment UI / operator dashboard
    can reuse the existing balance-cell decoder.  Since the
    storage layer has a single `kv` table, no schema migration
    is required — the new keyspaces are simply additional
    prefixed entries.

    Dispatch from the new event variants:
    * tag 16 (`DepositWithFeeCredited`): credit
      `actor_budgets[recipient] += budget_grant`; if
      `resource ∈ {0, 1}` then
      `pool_balances_{eth,bold}[pool_actor] += pool_amount`.
    * tag 17 (`ActionBudgetTopUp`): credit
      `actor_budgets[signer] += budget_increment`; if
      `gas_resource ∈ {0, 1}` then
      `pool_balances_{eth,bold}[pool_actor] += gas_amount`.
    * tag 18 (`GasPoolClaim`): no-op (drain semantics reserved
      for GP.7); kept as an explicit dispatch arm so the GP.7
      drain wiring lands without a structural diff.
    * tag 19 (`DelegatedActionBudgetTopUp`): credit
      `actor_budgets[recipient] += budget_increment` (NOT the
      signer — the load-bearing distinction from tag 17); if
      `gas_resource ∈ {0, 1}` then
      `pool_balances_{eth,bold}[pool_actor] += gas_amount`.

    All credits are saturating at `u128::MAX` so a malformed
    event stream cannot poison the view (overflow is treated
    as a defensive corner, not a halt condition; the balance
    view's stricter overflow-halts policy still applies on
    the balance side).

    The three views' updates commit atomically with the
    balance view + the cursor advance inside the SAME
    `Storage::transaction` opened by `Indexer::apply_batch`,
    so a per-event error rolls back EVERY view's mutations
    together.

    Cross-stack: `tests/cross_stack_lean_event.rs` now
    round-trips REAL Lean `Event.encode` bytes through the
    indexer's decoder + encoder for all 21 tags (0..=20, after
    the v2.1 Stage-A `BudgetConsumed`), not just 0..=15 as
    before.  The `INDEXER_MAX_KNOWN_TAG` bumped from 15 to 20;
    entries at tags 16..=20 no longer expected to decode to
    `UnknownTag`.

  * **Tests — shipped.**  ~62 new cases across `event` (5),
    `decoder` (8 — round-trip per variant + byte layout +
    distinct-tag + checked-encoder variants), `budget_view`
    (~24 — constants, keyspace isolation, key round-trip,
    parser rejection, get-missing-returns-zero, per-variant
    dispatch, ETH/BOLD independence, cumulative semantics,
    saturating credit, scan ordering, scan no-bleed,
    corrupt-cell variants per view, multi-event aggregate,
    tx rollback / read-your-writes, storage error round-trip,
    unknown-resource ignored, and 7 deep-audit edge cases:
    recipient-equals-pool-actor in DepositWithFeeCredited,
    zero-amount fields, u64::MAX fields, actor 0 / actor
    u64::MAX, view+tx-read consistency, and a
    dispatch_event-total-on-all-tags exhaustiveness pin
    constructing one canonical instance of every Event variant
    0..=20 to mechanically prove the match is total), `indexer`
    (9 — `apply_batch` dispatches the four GP variants,
    atomicity in BOTH directions across balance + budget views
    (the forward direction `_balance_failure_rolls_back_budget`
    AND the deep-audit reverse direction
    `_budget_failure_rolls_back_balance` proving a corrupt
    budget cell encountered during the GP pass rolls back the
    staged balance writes too), restart preserves the budget
    view, multi-event batch with both views, and a cursor-
    advance-completes-after-views invariant pin),
    `cross_stack_lean_event` (+1 GP-family field-projection
    consistency test).  Well above the plan's ~25-case target
    (+5 BOLD pool-balance coverage spec).
  * **Acceptance criteria.**  Met:
    * `cargo build --workspace --all-targets` — clean.
    * `cargo test --workspace --locked` — 1729 tests passing
      (up from 1639 baseline) after the v2.1 deep-audit refactor.
    * `cargo clippy --workspace --all-targets -- -D warnings`
      — clean.
    * `cargo fmt --all -- --check` — clean.
    * `cross_stack_lean_event` round-trips ALL 21 tags (0..=20)
      byte-for-byte against real Lean-emitted bytes.
  * **Dependencies.**  GP.6.3 (event-subscription / Lean
    `Encodable Event` / event-type registry) — landed and
    consumed.
  * **Estimated effort — actual.**  ~12 hours engineering
    + ~3 hours documentation, matching the plan's 12-hour
    estimate (v1).  v2.0 deep-audit response adds:
    * Stage A (Lean kernel `Event.budgetConsumed`): ~3 hours.
    * Stage B (knomosis-storage migration_002 + tables +
      BudgetStorage trait): ~2 hours.
    * Stage B+ (SqliteCombinedTransaction primitive): ~2 hours.
    * Stage D (Rust-side tag 20 wiring through event-subscribe
      + indexer + CI fixes): ~1 hour.

  * **v2.1 completion.**  All eight stages (A-E + G-H) ship in
    PR #102.  The deep-audit gap list (stages C/E/F/G/H) that
    was deferred at the v2.0 commit is now CLOSED:
    * Stage C: the indexer's `budget_view.rs` writes go to the
      new SQL tables via `SqliteCombinedTransaction` — the v1
      keyspace API is removed.  Atomicity verified by 14
      indexer.rs tests + 5 concurrency tests + 4 property tests.
    * Stage E: `--gas-pool-actor` + `--epoch-length` flags wire
      end-to-end through `Indexer::open_with_config`.  Operator
      CLI queries via `query-budget` / `query-pool-eth` /
      `query-pool-bold` subcommands.  HELP_TEXT updated.
    * Stage F: `--verify-budget-against-knomosis` stub surfaces
      a NotImplemented exit code (3) when set (until the
      knomosis-host budget endpoint lands), mirroring the
      existing `--verify-against-knomosis` discipline.
    * Stage G: 4 proptest cases drive random GP-family event
      sequences through both the real indexer and a reference
      HashMap model; per-actor equality verified for every
      relevant cell.
    * Stage H: 5 concurrency tests pin the mutex serialization
      discipline (multi-reader, reader-monotone-atomic,
      concurrent-writers, reader-blocks-during-writer,
      balance+budget-consistent).

#### WU GP.6.5: BOLD-specific cross-stack fixture corpus (v1.2)

  * **Status.** **Complete.**  Lean authors a single corpus,
    consumed and independently re-validated by both Rust and
    Solidity (the tri-stack contract):
    * Lean generator
      `LegalKernel/Test/Bridge/CrossCheck/BoldDeposit.lean`
      (suite `crosscheck-bold-deposit`, 21 cases — including the
      `recipientBudgetCell_currentBudget` /
      `recipientBudgetCell_matches_gate` theorems binding the
      corpus budget to the production admission gate) emits BOTH
      `solidity/test/CrossCheck/fixtures/bold_deposit.json`
      (`{ header, entries }` shape, matching the sibling fee-split
      fixtures) and `runtime/tests/cross-stack/l1_ingest_bold.cxsf`
      (binary; new `FixtureKind::L1IngestBold`, on-disk tag 7).
      190 entries: a 160-entry ETH+BOLD grid (2 legs × `amount ∈
      {1, 10⁹, 10¹⁵, 10¹⁸}` × `chosenFeeBps ∈ {0, 100, 1000,
      2500, 5000}` × `weiPerBudgetUnit ∈ {1, 10⁹, 3 × 10¹⁵, 10¹⁸}`
      — the full four-rate grid the spec enumerates) plus 6
      boundary entries (the `u64::MAX` whale ceiling at `0 %` and
      `50 %`, and the `10¹⁸` explicit clamp, each mirrored on BOTH
      legs) plus 24 USD-calibrated cross-amount entries (12
      ETH/BOLD pairs).  95 ETH / 95 BOLD; 20 clamp-active entries
      (`budgetGrant == 10¹²`), 80 grid twin pairs, 12 calibration
      pairs — the four-rate grid spans the budget-grant regime from
      saturated (rate 1) through proportional (3 × 10¹⁵, the
      production USD-calibrated BOLD rate) to floored-to-zero
      (10¹⁸).  Each `.cxsf`
      record carries a 58-byte `FeeSplitInput` tuple as input and,
      as expected output, the 72-byte CBE `Action.depositWithFee`
      bytes concatenated with the 18-byte CBE encoding of the
      recipient's **post-deposit `ActorBudget`** — the NEW
      dimension this WU adds over GP.5.4 / GP.6.1.  The budget cell
      is built through the real `EpochBudgetState.empty.topUp
      recipient currentEpoch freeTier budgetGrant` ledger API, so
      the corpus value IS the admission-gate result, not a
      re-derivation.
    * **USD-calibration parity (the spec's headline deliverable).**
      The 12 calibration pairs carry DIFFERENT amounts on the two
      legs — `amount_eth` ETH-wei at `rate_eth = 10¹²` and
      `3000 · amount_eth` BOLD-wei at `rate_bold = 3 · 10¹⁵` — yet,
      because they are calibrated to the same USD value at the same
      USD-per-budget-unit rate, MUST yield EQUAL budget grants.
      Since `amount_eth / rate_eth = amount_bold / rate_bold`
      exactly, the nested-floor identity makes the grants equal
      byte-for-byte (stronger than the spec's "within
      floor-division residue" tolerance).  This is distinct from
      the grid twins' resource-agnosticism (IDENTICAL amounts);
      each calibration pair shares a unique `depositId ≥ 2000` so
      consumers isolate the two legs.
    * Rust consumer
      `runtime/knomosis-l1-ingest/tests/cross_stack_bold.rs`
      (11 tests) loads the `.cxsf`, decodes each `FeeSplitInput`,
      recomputes the split via `FeeSplitInput::split`, re-encodes
      the action via `encode_action`, independently recomputes the
      recipient budget bytes (`encode_u64(0) ‖ encode_u64(budget)`),
      and byte-matches against the Lean-authored `expected` — plus
      conservation / pool-cap / budget-cap soundness, the ETH/BOLD
      resource-parametric byte-equality (action bytes differ only
      at the resource-field byte; budget bytes identical), grid
      resource-agnosticism (exactly 80 same-amount twin pairs),
      USD-calibration parity (exactly 12 cross-amount pairs with
      equal budget grants), and clamp coverage (exactly 20).
      `knomosis-cross-stack` gains the `L1IngestBold` variant
      (`from_tag` / `to_tag` arms + enumeration tests + a tag-7
      pin test).
    * Solidity consumer
      `solidity/test/CrossCheck/BoldDepositFixtures.t.sol`
      (10 tests) reads `bold_deposit.json`, recomputes the split via
      `FeeSplitMath.split`, pins `recipientBudgetAfter ==
      budgetGrant` (the cross-stack budget-grant semantics: from a
      genesis-empty epoch-0 budget at `freeTier 0`, the recipient's
      post-deposit `currentBudget` equals exactly `budgetGrant`),
      DECODES the 18-byte `recipientBudgetCbe` tail to
      `{0, budgetGrant}` byte-for-byte (matching the Rust consumer —
      giving the budget dimension genuine second-stack byte
      coverage), checks conservation / clamp corners (exactly 20) /
      grid resource-agnosticism (exactly 80 twins) / USD-calibration
      parity (exactly 12 pairs) / `actionCbe` well-formedness, and
      drives the LIVE contract: each BOLD entry deploys a
      BOLD-enabled `KnomosisBridge` and runs `depositBoldWithFee`,
      each ETH entry runs `depositETHWithFee{value:}`, asserting the
      emitted `(userAmount, poolAmount, budgetGrant)` equal the Lean
      values.
    * **Verification.**  `lake build` warning-free; `lake test`
      green (137 suites / ~2 606 tests; the fixtures are written in
      overwrite mode and re-verified byte-for-byte in verify mode —
      the Lean-side drift gate); `count_sorries` / `tcb_audit` /
      `stub_audit` / `naming_audit` / `deferral_audit` /
      `lex_lint` / `lex_codegen --check` all pass; `cargo test
      --workspace --locked` green (≈1 741); `cargo clippy
      --workspace --all-targets -- -D warnings` clean; `cargo fmt
      --all -- --check` clean; `forge test` green (637 passed, 12
      keccak-gated skips).  The BOLD split / CBE / budget bytes are
      hash-independent, so the cross-checks run unconditionally
      (no keccak-binding gate, unlike the receiptHash corpora).
  * **Goal.**  Extend the cross-stack fixture corpus to cover
    the BOLD-resource deposit path byte-equivalently between
    Solidity, Rust, and Lean.
  * **Files:**
    * `runtime/tests/cross-stack/l1_ingest_bold.cxsf` (new).
    * `LegalKernel/Test/Bridge/CrossCheck/BoldDeposit.lean`
      (new Lean fixture generator).
    * `solidity/test/CrossCheck/BoldDepositFixtures.t.sol`
      (new Solidity consumer).
  * **Deliverables.**
    * 50+ fixture entries covering:
      - `amount ∈ {1 BOLD-wei, 10⁹ BOLD-wei, 10¹⁵ BOLD-wei,
        10¹⁸ BOLD-wei (= 1 BOLD), 10²¹ BOLD-wei (= 1000 BOLD)}`
        (sample across BOLD-wei magnitudes from rounding-edge
        to whale).
      - `chosenFeeBps ∈ {minFeeBps, 100, 1000, 2500,
        maxFeeBps}`.
      - `weiPerBudgetUnitBold ∈ {1, 10⁹, 3 × 10¹⁵, 10¹⁸}`.
      - Each entry includes the L1-side `(amount, chosenFeeBps,
        weiPerBudgetUnitBold)` triple and the expected
        `(userAmount, poolAmount, budgetGrant)` triple, plus
        the expected CBE-encoded `Action.depositWithFee` bytes,
        plus the expected `EpochBudgetState` mutation
        (recipient's budget post-deposit).
    * Both legs (ETH and BOLD) are tested with the same
      cross-stack harness; identical entries with `resourceId`
      flipped should produce identical action bytes except for
      the resource-field byte.
  * **Mathematical-soundness double-check.**
    * Floor-division residue: `userAmount + poolAmount = amount`
      exactly across all 50 entries.  Verified by Lean fixture
      generator before emitting the entry.
    * Budget-grant clamp: when `poolAmount /
      weiPerBudgetUnitBold > MAX_BUDGET_PER_DEPOSIT = 10¹²`,
      `budgetGrant` is the cap, not the raw value.  Verified
      by including 5+ "clamp-active" entries in the corpus.
    * Calibration parity: for each `(amount_eth, amount_bold)`
      pair calibrated to the same USD value, the resulting
      budget grants should match to within floor-division
      residue.  Verified by including 10+ paired entries.
  * **Tests.**  50+ cases via the cross-stack harness +
    structural invariants (header shape, byte-size, fixture
    determinism).
  * **Acceptance criteria.**  One reviewer; Solidity, Rust,
    and Lean all produce identical `(userAmount, poolAmount,
    budgetGrant)` triples for every fixture entry; CBE encoder
    bytes match byte-for-byte; calibration-parity invariant
    holds.
  * **Dependencies.**  GP.5.4, GP.6.1.
  * **Estimated effort.**  ~12 hours.

---

### Phase GP.7 — Pool actor governance

#### WU GP.7.0: Extend `bridgePolicy` for new bridgeActor-signable actions (v1.5)

  * **Goal.**  Extend the pre-GP `bridgePolicy` (defined in
    `Bridge/BridgeActor.lean` by Workstream E-B) to permit
    `bridgeActor` to sign the new actions introduced in GP:
    `depositWithFee` (v1.0 GP), `ammSwap` (v1.3 GP).  Without
    this extension, `bridgeActor`-signed `depositWithFee` and
    `ammSwap` actions would fail admission via the existing
    `bridgePolicy_*` family of theorems, breaking the bridge
    end-to-end.
  * **Why this WU exists.**  v1.0 – v1.4 of the plan
    implicitly assumed `bridgePolicy` would be extended but
    never specified the extension as a discrete work unit.
    GP.11.6 (the `ammReservePolicy` declaration) noted the
    requirement explicitly ("we need to add `ammSwap` to the
    `bridgePolicy`'s allowed-tags list") but did not own the
    work.  v1.5 makes this an explicit WU.
  * **File:** `LegalKernel/Bridge/BridgeActor.lean`
    (extension of the existing `bridgePolicy` declaration).
  * **Deliverables.**

    The current `bridgePolicy` (per Workstream E-B) is a
    `LocalPolicy` declared on `bridgeActor` that whitelists
    the specific action tags `bridgeActor` is permitted to
    sign.  Pre-GP allowed tags include (approximately):
    `registerIdentity` (12), `replaceKey` (4), `deposit` (13),
    `withdraw` (14).  v1.5 extends to include:

    ```lean
    /-- v1.5 extension to bridgePolicy: permit bridgeActor to
        sign the new GP-era actions (depositWithFee, ammSwap).
        The pre-GP bridgePolicy is preserved verbatim; v1.5
        adds the new tags via an append-only amendment. -/
    def bridgePolicy : LocalPolicy :=
      { clauses :=
          -- Pre-GP clauses (preserved verbatim from
          -- Workstream E-B; see Bridge/BridgeActor.lean
          -- before v1.5 for the original declaration).
          [ ...,
            -- v1.5 additions:
            .allowTag depositWithFeeTag,  -- index 19
            .allowTag ammSwapTag           -- index 22
          ] }
    ```

    Note: this assumes the existing `LocalPolicyClause`
    machinery supports `allowTag` (a positive whitelist
    clause).  If the existing pattern is "denyTags
    [non-allowed-list]", then v1.5 amends that list:

    ```lean
    -- Alternative formulation (if existing pattern is deny-list):
    def bridgePolicy : LocalPolicy :=
      { clauses :=
          [ .denyTags (List.range 23
              |>.filter (fun tag =>
                tag ≠ registerIdentityTag ∧
                tag ≠ replaceKeyTag ∧
                tag ≠ depositTag ∧
                tag ≠ withdrawTag ∧
                tag ≠ depositWithFeeTag ∧  -- v1.5 (was missing)
                tag ≠ ammSwapTag)) ]      -- v1.5 (was missing)
      }
    ```

    The choice between formulations depends on the existing
    pattern in `Bridge/BridgeActor.lean`; the implementer
    should verify and use whichever matches.

  * **Mathematical soundness check.**
    * **Bridgeable actions in v1.5:** `bridgeActor` can sign
      `registerIdentity`, `replaceKey`, `deposit`,
      `withdraw`, `depositWithFee`, `ammSwap`.  These are the
      6 actions that originate from L1 events and require
      bridgeActor's authority signature on L2.
    * **Non-bridgeable actions:** `bridgeActor` cannot sign
      `transfer`, `mint`, `burn`, etc., because none of
      these are L1-event-driven.  Confirms by exhaustion that
      v1.5 doesn't accidentally widen bridgeActor's authority.
    * **Preservation of pre-GP theorems:** the
      `bridgePolicy_*` family from Workstream E-B is
      preserved because the v1.5 amendment is append-only.
      Each theorem's proof carries forward; for the new
      tags (19, 22), corresponding theorems are added.
  * **Theorems.**
    * `bridgePolicy_permits_depositWithFee` (new): a
      `bridgeActor`-signed `depositWithFee` action passes
      `localPolicyOk` with `bridgePolicy`.
    * `bridgePolicy_permits_ammSwap` (new): same for
      `ammSwap`.
    * `bridgePolicy_v1_5_extension_preserves_existing`
      (new): every action that passed `bridgePolicy` at v1.4
      still passes at v1.5 (no regression).
    * `bridgePolicy_v1_5_denies_non_bridgeable` (new):
      `bridgeActor` cannot sign `transfer`, `mint`, `burn`,
      etc. under `bridgePolicy` at v1.5.
  * **Tests.**  25 cases:
    * Positive: bridgeActor-signed depositWithFee admitted ✓
    * Positive: bridgeActor-signed ammSwap admitted ✓
    * Positive: pre-GP bridge actions (deposit, withdraw,
      registerIdentity, replaceKey) still admitted ✓
    * Negative: bridgeActor-signed transfer rejected ✓
    * Negative: bridgeActor-signed mint rejected ✓
    * Negative: bridgeActor-signed proportionalDilute rejected ✓
    * Negative: bridgeActor-signed topUpActionBudget rejected ✓
    * Negative: bridgeActor-signed topUpActionBudgetFor
      rejected (bridgeActor isn't a delegate for anyone in
      practice) ✓
  * **Acceptance criteria.**  Two reviewers (touches
    `Bridge/BridgeActor.lean`, which is a security-critical
    file with existing theorems that must not regress);
    `lake test` green; the
    `bridgePolicy_v1_5_extension_preserves_existing`
    theorem proves no regression.
  * **Dependencies.**  GP.0.3 (action-index reservation), and
    GP.7.1 must follow this WU (or be co-landed) because
    `gasPoolPolicy` references the same action indices.
  * **Estimated effort.**  ~6 hours.
  * **Implementation status — landed (Lean side).**

    **Spec-name → shipped-name mapping** (the plan's draft names carry
    a `v1_5` version infix that the naming discipline forbids in
    identifiers; here is where each landed):

    | Spec draft name                              | Shipped name                                | Notes |
    |----------------------------------------------|---------------------------------------------|-------|
    | `bridgePolicy_permits_depositWithFee`        | `bridgePolicy_authorizes_depositWithFee`    | landed earlier under GP.2.3 |
    | `bridgePolicy_permits_ammSwap`               | *(deferred to GP.11)*                       | `ammSwap` constructor does not exist yet |
    | `bridgePolicy_v1_5_extension_preserves_existing` | `bridgePolicy_authorizes_all_bridge_actions` | bundles the four positive theorems |
    | `bridgePolicy_v1_5_denies_non_bridgeable`    | `bridgePolicy_rejects_non_bridgeable`       | exhaustive negative, derived from the iff |
    | *(no spec analogue)*                         | `bridgeAuthorizedAction_eq_true_iff`        | single-source-of-truth characterisation added in v1.5 |

    * **`depositWithFee` arm: already present.**  When this WU was
      drafted it assumed `bridgePolicy` still had to be extended for
      `depositWithFee`; in fact that extension landed earlier under
      GP.2.3 (`bridgeAuthorizedAction` returns `true` for
      `depositWithFee`, with the existing theorem
      `bridgePolicy_authorizes_depositWithFee` and the
      `bridgeAuthorizedAction_of_isBridgeOnly` consistency theorem in
      `Bridge/Admissible.lean`).  The existing `bridgePolicy` is a
      **positive whitelist** (`bridgeAuthorizedAction : Action →
      Bool`), so the first formulation in the deliverables (not the
      deny-list alternative) is the one that matches the code.
    * **`bridgeAuthorizedAction` hardened into a wildcard-free
      exhaustive match.**  The original definition ended in a
      `_ => false` catch-all (a one-line addition was enough to make a
      new action bridge-signable).  That catch-all silently absorbed
      *any* newly-added `Action` constructor as "not authorised" with
      no review forced — the gap the WU's "confirms by exhaustion that
      v1.5 doesn't accidentally widen bridgeActor's authority" prose
      gestures at.  v1.5 spells out all 22 constructors explicitly (4
      `true`, 18 `false`), so adding a constructor to `Action` makes
      this `def` non-exhaustive and breaks the build until its
      bridge-authority is classified.  This is the same exhaustive-
      match discipline AR.17 applied to `kernelOnlyApply`'s dispatch.
    * **Three new exhaustive theorems added** to
      `LegalKernel/Bridge/BridgeActor.lean`, capturing the WU's
      `..._extension_preserves_existing` and `..._denies_non_bridgeable`
      intent without per-constructor reliance:
      - `bridgeAuthorizedAction_eq_true_iff` — the single source of
        truth: `bridgeActor` signs EXACTLY `replaceKey`,
        `registerIdentity`, `deposit`, `depositWithFee`.  Proven by
        exhaustive `cases` on `Action`.
      - `bridgePolicy_authorizes_all_bridge_actions` — the
        "preserves existing" / no-regression positive half (bundles
        the four `bridgePolicy_authorizes_*` theorems).
      - `bridgePolicy_rejects_non_bridgeable` — the
        "denies non-bridgeable" exhaustive negative half, derived
        from the iff (so it inherits the same forcing function).

      **Two complementary forcing functions** result: a brand-new
      `Action` constructor is caught by the exhaustive
      `bridgeAuthorizedAction` match (it goes non-exhaustive); a
      verdict flip / new `=> true` arm without a matching iff disjunct
      is caught by `bridgeAuthorizedAction_eq_true_iff`'s `cases` proof
      (an unsolved `True ↔ False`).  Verified empirically with a toy
      mirror of the exact structure: dropping or adding a disjunct, or
      adding a constructor, each breaks the build as claimed.

      The shipped names drop the spec's `v1_5` infix: the project's
      naming discipline ("names describe content, never provenance")
      forbids version markers in identifiers.  All three depend only
      on `propext` / `Quot.sound` (zero TCB delta;
      `bridgePolicy_authorizes_all_bridge_actions` is axiom-free).
    * **`ammSwap` arm: lands with Workstream GP.11.**  `ammSwap`
      (action-index 22) does not exist in the `Action` inductive yet
      — it is introduced by the GP.11 embedded-AMM workstream
      (law + encoding + step-VM + Solidity + cross-stack corpus).  It
      therefore cannot be added to `bridgeAuthorizedAction` in a
      `bridgePolicy`-only WU.  When GP.11 introduces `ammSwap` and a
      deployment wants the bridge to sign it, the implementer adds an
      `ammSwap` arm to `bridgeAuthorizedAction` AND a disjunct to
      `bridgeAuthorizedAction_eq_true_iff`; the build will not compile
      until both are done.  So `bridgePolicy_permits_ammSwap` is the
      one named theorem this WU does not yet ship — by construction it
      cannot, and the forcing function guarantees it is added in
      lockstep with the constructor.
    * **Tests.**  The `bridge-actor` suite grows by 20 GP.7.0 cases
      (value-level `bridgeAuthorizedAction` checks + iff
      forward/backward witnesses at `replaceKey` / `deposit` /
      `depositWithFee` + term-level API stability for the three new
      `Prop` theorems + exhaustive rejection applied to `transfer` /
      `mint` / `proportionalDilute` / `topUpActionBudget` /
      `topUpActionBudgetFor` / `faultProofChallenge` + **five
      end-to-end admission cases** that drive the full
      `BridgeAdmissibleWith` / `apply_bridge_admissible_with` pipeline
      under `bridgePolicy` itself — the WU's literal "admitted ✓"
      criterion, which the pre-existing budget / runtime suites only
      exercised under `AuthorityPolicy.unrestricted`.  Bridge-signed
      `depositWithFee` / `deposit` / `registerIdentity` are admitted;
      bridge-signed `transfer` / `topUpActionBudget` are rejected.
      The admission verdicts were additionally confirmed by direct
      `#eval` of the decidable `BridgeAdmissibleWith` predicate
      (true / true / true / false / false, plus false for a
      non-bridge signer on `deposit`).

#### WU GP.7.1: `gasPoolActor` reservation

  * **Status: COMPLETE (Lean + Rust, end-to-end).**  Reserves
    `ActorId 1` (`gasPoolActor`) and `ActorId 2` (`sequencerActor`) in
    `LegalKernel/Bridge/BridgeActor.lean`, alongside the pre-existing
    `ActorId 0` (`bridgeActor`).  The genesis
    `AddressBook.empty.nextActorId` advances from `1` to `3` in
    `LegalKernel/Bridge/AddressBook.lean`, pinned by the new
    `addressBook_empty_nextActorId : empty.nextActorId = 3`.  All four
    plan theorems ship — `gasPoolActor_ne_bridgeActor`,
    `sequencerActor_ne_bridgeActor`, `sequencerActor_ne_gasPoolActor`
    (axiom-free `decide`), plus `addressBook_empty_nextActorId`
    (`rfl`) — together with a fifth *reservation-guarantee* theorem
    `empty_assign_id_avoids_reserved` proving the id `assign` issues
    for a fresh address is distinct from every reserved slot (so no
    `empty` + `assign` chain can ever issue a reserved id to a
    user-registered identity; the first user actor a fresh deployment
    registers is `ActorId 3`).  The `bridge-actor` suite grows 58 → 71
    (13 GP.7.1 cases: the two constant values, pairwise distinctness,
    the three disjointness theorems' term-level API, the genesis
    `nextActorId`, the genesis theorem's term-level API, an `empty` +
    `assign` integration pinning the first issued id at 3 and distinct
    from all reserved slots, a below-genesis bound on every reserved
    id, the `empty_assign_id_avoids_reserved` value + term-level
    checks, and a value-level proof that no reserved actor appears in
    the post-`assign` reverse map).  The `bridge-address-book` and
    `bridge-ingest` value fixtures are rebased onto the new genesis id
    (`assign` allocation now starts at 3, so the first registered
    identity is `ActorId 3`, the second `4`, etc.); no source change to
    `Bridge/Ingest.lean` was needed (it allocates from `nextActorId`
    abstractly).  No kernel TCB delta; no new axioms (the three
    disjointness theorems are axiom-free; `addressBook_empty_nextActorId`
    and `empty_assign_id_avoids_reserved` depend only on the canonical
    `{propext, Classical.choice, Quot.sound}` via `Std.TreeMap`).

    *Runtime-adaptor lockstep — DONE (pulled forward from GP.10).*  The
    Rust production runtime adaptor
    `runtime/knomosis-l1-ingest::AddressBook` advances in lockstep:
    `INITIAL_NEXT_ACTOR_ID` becomes `3`, and new `GAS_POOL_ACTOR_ID`
    (1) / `SEQUENCER_ACTOR_ID` (2) constants mirror the Lean
    `gasPoolActor` / `sequencerActor`.  So the production adaptor that
    performs the actual `assign` now honours the reservation: a fresh
    L1 identity registration is issued `ActorId 3`, never a reserved
    slot.  Defence-in-depth on crash recovery: the state-file replay
    (`state.rs`) rejects any persisted actor id below the genesis
    `next_actor_id` (the reserved range 0/1/2) — covering BOTH the
    legacy `AddressAssigned` and the atomic `Submitted.assigned` record
    paths — so a state file that claims a user was issued a reserved id
    (the only way such a file arises is a pre-GP.7.1 deployment) is
    rejected loudly rather than silently reconstructed into a book that
    violates the reservation.  Per the PR-#105 review, the rejection
    carries an *actionable migration diagnostic*: it names the reserved
    range and points the operator at the GP.10.4 remapping migration,
    instead of the generic "gap or duplicate" message that would
    mislead someone upgrading an existing node.  Pinned by
    `replay_rejects_reserved_actor_id` (legacy record) +
    `replay_rejects_reserved_actor_id_in_submitted_record` (atomic
    record).  (A *tolerant* replay that silently kept the old ids was
    rejected as a design: it would let pre-GP.7.1 users squat on the
    reserved `gasPoolActor` / `sequencerActor` slots; the correct fix —
    remapping affected actors to ids ≥ 3 — is GP.10.4's deliverable.)
    The Rust `AddressBook`
    unit tests, the `state.rs` / `translation.rs` / `watcher.rs` replay
    + integration tests, and the regenerated `l1_ingest.cxsf`
    cross-stack corpus (whose `cross_stack.rs` consumer byte-checks the
    expected action ids) are all rebased onto the genesis-3 allocation;
    a new `gas_pool_and_sequencer_ids_are_reserved` test mirrors the
    Lean reservation guarantee.  Full workspace `cargo test` green;
    `clippy -D warnings` + `fmt --check` clean.  This is the
    *fresh-genesis* half of the reservation; the orthogonal migration
    of *existing* deployments that already allocated users in 1..3
    (remapping their persisted state) remains Phase GP.10.4's
    deliverable.

  * **Goal.**  Reserve `ActorId 1` for `gasPoolActor` and
    `ActorId 2` for `sequencerActor`.  Advance
    `AddressBook.empty.nextActorId` from 1 to 3.
  * **Files:**
    * `LegalKernel/Bridge/BridgeActor.lean` (constants).
    * `LegalKernel/Bridge/AddressBook.lean` (genesis `nextActorId`).
  * **Deliverables.**

    ```lean
    /-- The reserved actor id of the gas-pool actor (Workstream
        GP).  Holds bridge-skim revenue and top-up payments;
        outflow is bounded by its `LocalPolicy`. -/
    def gasPoolActor : ActorId := 1

    /-- The reserved actor id of the sequencer actor (Workstream
        GP).  The only authorised recipient of `gasPoolActor`
        outflow per the canonical `gasPoolPolicy`. -/
    def sequencerActor : ActorId := 2
    ```

    `AddressBook.empty.nextActorId` becomes `3`, replacing the
    current `1`.
  * **Theorems.**
    * `gasPoolActor_ne_bridgeActor : gasPoolActor ≠ bridgeActor`
    * `sequencerActor_ne_bridgeActor : sequencerActor ≠ bridgeActor`
    * `sequencerActor_ne_gasPoolActor : sequencerActor ≠ gasPoolActor`
    * `addressBook_empty_nextActorId : AddressBook.empty.nextActorId = 3`
  * **Tests.**  10 cases.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  None.
  * **Estimated effort.**  ~2 hours.

#### WU GP.7.2: Canonical `gasPoolPolicy` declaration

  * **Status: COMPLETE (Lean side, optimal closure).**  `gasPoolPolicy`
    ships in the new `LegalKernel/Bridge/GasPoolPolicy.lean` exactly as
    sketched below (five conjunctive clauses; deny-list
    `(List.range 23).filter (· ≠ 0)`), wired into the umbrella module
    `LegalKernel.lean`.  All six plan theorems ship, named per the
    deliverable list — `gasPoolPolicy_denies_all_non_transfer`,
    `gasPoolPolicy_requires_sequencer_recipient_eth` / `_bold`,
    `gasPoolPolicy_caps_per_action_eth` / `_bold`,
    `gasPoolPolicy_eth_bold_independent` — plus the GP.7.3-feeding
    cap-extraction lemmas `gasPoolPolicy_permits_transfer_eth_amount_le`
    / `_bold`, the happy-path admissions
    `gasPoolPolicy_permits_sequencer_transfer_eth` / `_bold`, and the
    deny-list foundation `Action.tag_lt_denyListBound` +
    `mem_gasPoolDeniedTags_of_tag_ne_zero` (the build-time forcing
    function that breaks if a 24th Action constructor is added without
    bumping the range).

    A post-implementation audit pass then took the WU to its **optimal**
    form by surfacing and closing two security-relevant gaps the
    per-clause theorems alone hid:

      1. **Single source of truth + the resource-`≥ 2` boundary.**
         `gasPoolPolicy_permits_transfer_iff` states EXACTLY which
         `gasPoolActor` transfers the policy permits, and
         `gasPoolPolicy_permits_transfer_off_gas_legs` makes the
         honest converse explicit: the policy carries no clause for
         resources `≥ 2`, so it does NOT constrain them (off-leg pool
         safety rests on a separate pool-balance invariant — the GP.7.3
         track — not on `gasPoolPolicy`).

      2. **The LP.7 meta-action escape hatch — proven, then CLOSED.**
         `gasPoolPolicy_admission_permits_iff` characterises the
         kernel's actual admission conjunct (`localPolicyPermits` =
         meta-action OR `.permits`), and
         `gasPoolPolicy_admission_permits_meta_actions` PROVES that a
         `LocalPolicy` structurally cannot bar `gasPoolActor` from
         `declareLocalPolicy` / `revokeLocalPolicy` (the LP.7 exemption)
         — so a pool key could otherwise revoke its own `gasPoolPolicy`
         and drain freely.  The hole is closed **in this WU** (per an
         explicit decision to pull the fix forward from GP.7.4) by the
         complementary `gasPoolAuthorityPolicy`: an `AuthorityPolicy`,
         intersected into the deployment policy
         (`deploymentPolicy.intersect gasPoolAuthorityPolicy`).  Because
         the `AuthorityPolicy.authorized` conjunct of `AdmissibleWith`
         has NO meta-action exemption, `gasPoolAuthorityPolicy_rejects_meta`
         / `_intersect_rejects_meta` bar the escape hatch under ANY base
         policy; `_rejects_off_gas_legs` / `_rejects_non_sequencer` /
         `_rejects_non_transfer` / `_rejects_non_pool_sender`
         additionally enforce — at the authority layer — the
         resource-`≥ 2`, recipient, and SENDER restrictions the
         `LocalPolicy` could not; `_authorizes_sequencer_eth` / `_bold`
         (with `sender` pinned to `gasPoolActor`) preserve the
         legitimate drain; and `_other_actors_unrestricted` proves the
         intersection narrows ONLY `gasPoolActor`.

      3. **Fund-safety: the sender-debit drain vector (PR #106
         review).**  An automated review flagged that the original
         `gasPoolActorAuthorized` ignored the transfer's `sender`
         field.  Because the kernel `transfer` law debits the action's
         `sender` and `AdmissibleWith` verifies only `st.signer`'s
         signature, a held `gasPoolActor` key could sign
         `.transfer r victim sequencerActor amount` and drain an
         ARBITRARY victim's balance to the sequencer.  The `LocalPolicy`
         cannot bind the sender (no clause vocabulary for it), so the
         `AuthorityPolicy` now requires `sender = gasPoolActor` on both
         gas legs — the pool may move only its OWN funds.  Pinned by
         `gasPoolAuthorityPolicy_rejects_non_pool_sender` and tested
         both directly and end-to-end through the intersect wiring.

    The GP.7.4 genesis prerequisites also ship:
    `gasPoolPolicy_fieldsBounded` + `gasPoolPolicy_roundtrip` (canonical
    CBE boundedness + decode∘encode round-trip under `UInt64`-range
    caps), so the genesis `declareLocalPolicy` payload provably encodes.
    The deny test now covers EVERY non-transfer tag 1..21 (tags 8 / 9
    `dispute` / `disputeWithdraw` no longer skipped), and the
    AuthorityPolicy is exercised end-to-end via intersection-composition
    tests against the genuinely-restrictive `bridgePolicy` base (proving
    intersection only narrows) plus the union-then-intersect GP.7.4
    shape, and the PR #106 victim-fund-drain rejection.  The
    `bridge-gas-pool-policy` suite ships 61 cases.  Theorems depend
    only
    on the canonical `{propext, Classical.choice, Quot.sound}` subset
    (the bare-policy + authority theorems use only `{propext,
    Quot.sound}`; the two admission-level theorems additionally use
    `Classical.choice` via `ExtendedState`); no kernel TCB delta.  The
    per-epoch inductive drain bound is the separate GP.7.3 WU.

    **GP.7.4 contract (load-bearing):** the genesis hook MUST wire BOTH
    the `gasPoolPolicy` `LocalPolicy` declaration AND the
    `gasPoolAuthorityPolicy` `AuthorityPolicy` intersection.  The
    `LocalPolicy` alone leaves the meta-action hole open.  The code
    below is the as-shipped `LocalPolicy` sketch; the `AuthorityPolicy`
    surface is the `gasPool*AuthorityPolicy*` family in the same file.
  * **Goal.**  Construct the canonical `LocalPolicy` instance that
    governs `gasPoolActor` outflow.
  * **File:** `LegalKernel/Bridge/GasPoolPolicy.lean` (new).
  * **Deliverables.**

    ```lean
    /-- The canonical `LocalPolicy` for the gas-pool actor.

        v1.2 generalises v1.1's single-resource policy to cover
        BOTH `ResourceId 0` (ETH) and `ResourceId 1` (BOLD)
        independently.  Each resource gets its own
        recipient-restriction and amount-cap clause; the
        deny-tags clause covers every non-transfer Action
        uniformly across both resources.

        Combines five clauses conjunctively:
        1. `denyTags [1, 2, ..., 20]` — deny every Action
           constructor EXCEPT `transfer` (tag 0).  Reading
           `Authority/LocalPolicy.lean:122-141`, the `denyTags`
           clause refuses an action if its tag is in the list,
           so to allow only `transfer`, we deny every OTHER tag.
           This clause is resource-agnostic; it gates ALL
           outflow from `gasPoolActor` to the `transfer` action
           regardless of which resource the transfer is over.
        2. `requireRecipientIn 0 [sequencerActor]` — when
           emitting a `transfer` over resource 0 (ETH leg), the
           recipient must be `sequencerActor`.
        3. `capAmount 0 (maxDrainPerActionEth)` — caps the
           single-action transfer-out amount on the ETH leg.
        4. `requireRecipientIn 1 [sequencerActor]` (NEW v1.2) —
           same recipient restriction for resource 1 (BOLD leg).
        5. `capAmount 1 (maxDrainPerActionBold)` (NEW v1.2) —
           per-resource amount cap for the BOLD leg.  The cap
           may differ from the ETH leg (a BOLD claim of 10 000
           BOLD ≈ $10 000 USD; an ETH claim of 1 ETH ≈ $3 000
           USD; operators typically calibrate so the USD-
           denominated cap is similar across legs).

        Per-epoch drain bound is NOT a single-clause property;
        it requires an inductive accounting argument over each
        resource independently (see GP.7.3).

        Note: an L1 attestation requirement is NOT expressible
        in v1's `LocalPolicyClause` set.  v2 adds a new clause
        `requireL1Attestation` for the cryptographic-receipt
        sequencer-claim mechanism (out of scope for this
        workstream). -/
    def gasPoolPolicy
        (maxDrainPerActionEth : Amount)
        (maxDrainPerActionBold : Amount) : LocalPolicy :=
      { clauses :=
          [ -- v1.5 fix: range 23 (was 21 in v1.0-v1.4) so the
            -- v1.3-era action indices 21 (topUpActionBudgetFor)
            -- and 22 (ammSwap) are included in the deny list.
            -- v1.4's audit pass missed this gap; v1.5 closes it.
            -- For future-proofing: when adding any new action
            -- index N, BOTH this constant AND `ammReservePolicy`
            -- (GP.11.6) must be bumped to `List.range (N+1)`.
            .denyTags (List.range 23 |>.filter (· ≠ 0)),
            .requireRecipientIn 0 [sequencerActor],
            .capAmount 0 maxDrainPerActionEth,
            .requireRecipientIn 1 [sequencerActor],
            .capAmount 1 maxDrainPerActionBold
          ] }
    ```

    *Author's mathematical check:*  `List.range 23` produces
    `[0, 1, 2, ..., 22]`.  Filtering out `0` produces
    `[1, 2, ..., 22]` — every Action tag *except* `transfer`,
    including the v1.3 additions at indices 21 and 22.
    Conjunctively combined with the per-resource recipient + cap
    clauses, a `gasPoolActor`-signed action passes the policy
    iff:
    1. Its tag is `0` (transfer); AND
    2. EITHER it is over resource 0 with recipient ∈
       `[sequencerActor]` and amount ≤ `maxDrainPerActionEth`,
       OR it is over resource 1 with recipient ∈
       `[sequencerActor]` and amount ≤ `maxDrainPerActionBold`.

    Locality of the per-resource clauses: a `transfer` over
    resource 0 is unaffected by the resource-1 clauses (the
    `requireRecipientIn` and `capAmount` clauses are
    *resource-keyed*, vacuous when the action's resource doesn't
    match — see `Authority/LocalPolicy.lean:`
    `localPolicyOk_clauseLocalToResource`).  So the ETH-leg
    constraints don't accidentally block legitimate BOLD-leg
    transfers and vice versa.

    The "deny-list, not allow-list" gotcha from v1.1 still
    applies: `denyTags` refuses an action if its tag is in the
    list.  The implementor must construct it carefully.
  * **Theorems.**
    * `gasPoolPolicy_denies_all_non_transfer : ∀ a, sigAction.signer = gasPoolActor → sigAction.action.tag ≠ 0 → ¬ localPolicyOk (gasPoolPolicy m_eth m_bold) ...`
    * `gasPoolPolicy_requires_sequencer_recipient_eth`
    * `gasPoolPolicy_requires_sequencer_recipient_bold` (NEW v1.2)
    * `gasPoolPolicy_caps_per_action_eth`
    * `gasPoolPolicy_caps_per_action_bold` (NEW v1.2)
    * `gasPoolPolicy_eth_bold_independent : ∀ a, transfer at resource 0 with valid params passes the BOLD clauses vacuously, and vice versa` (NEW v1.2)
  * **Tests.**  30 cases (+10 vs v1.0 for the BOLD-leg
    cross-product over every Action tag, every recipient choice,
    and the cap boundary).
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.7.1, GP.2.3.
  * **Estimated effort.**  ~10 hours (v1.0 estimated 6; +4 for
    the BOLD-leg theorems and tests).

#### WU GP.7.3: Pool drain bound (inductive)

  * **Status: COMPLETE (Lean side, optimal closure — also delivers the
    GP.7.5 core).**  The inductive pool-drain bound ships in the new
    `LegalKernel/Bridge/PoolDrainBound.lean` (wired into the umbrella
    `LegalKernel.lean`).  All deliverable theorems land — the headline
    `pool_drain_bounded_by_action_count` and the surviving-balance floor
    `pool_balance_lower_bound_via_trace` — and an optimal-closure pass
    took the WU to its complete form:

      1. **Per-resource (GP.7.5 core).**  The bound is proven
         **per-resource** (`pool_drain_bounded_by_action_count_per_resource`,
         cap = `legCap mEth mBold rLeg`), with the ETH (`rLeg = 0`) and
         BOLD (`rLeg = 1`) legs as `simp`-specialisations
         (`…_by_action_count` / `…_bold`).  `mBold` is no longer a
         vestigial parameter.  The two gas legs are proven independent
         accounting domains (`per_resource_pool_independence`,
         `pool_balance_eth_leg_independent_of_bold_actions` / `…_bold_…`),
         delivering WU GP.7.5's headline + independence theorems in the
         same file.
      2. **Exhaustive external discharge.**  The non-pool-signer
         obligation (the plan's case (a)) is discharged over EVERY
         `Action` constructor by `pool_nondecreasing_of_does_not_debit`:
         the decidable `Action.doesNotDebitPoolAt rLeg signer` predicate
         captures exactly when a step cannot lower the pool's leg balance
         (credit-only / no-op actions always; `topUp*` when the signer is
         not the pool; `transfer` / `burn` / `withdraw` when their source
         field is not the pool — the fold-of-credit laws
         `distributeOthers` / `proportionalDilute` handled via a per-actor
         fold-monotonicity lemma, since their `IsMonotonic` instances are
         only `TotalSupply`-level).  `transfer_other_sender_pool_nondecreasing`
         survives as the named ETH corollary.
      3. **Executable `applyTrace`.**  The literal plan deliverable
         `applyTrace es trace = some es'` ships as an executable
         `Option`-valued fold, backed by a general, genuinely-computable
         `Decidable (AdmissibleWith …)` instance that lives with its
         subject in `Authority/SignedAction.lean` (the registered-signer
         existential is decided by casing the concrete registry lookup,
         never quantifying over the key space — verified to reduce via
         `#eval`), with the bound proven directly over it
         (`applyTrace_drain_bounded_per_resource`) and a bridge to the
         inductive relation (`applyTrace_yields_poolBoundedTrace` via
         `PoolBoundedTrace.headStep`).  The test suite drives the fold at
         runtime AND feeds the bridged relation through the headline bound.
      4. **Production-runtime lift.**  The per-step bounds are lifted onto
         the LITERAL budget-gated bridge runtime entry
         (`pool_signed_step_drain_le_budget`,
         `pool_nondecreasing_of_does_not_debit_budget`, via
         `apply_bridge_admissible_with_budget_base_eq_apply`), matching
         the GP.4.2 accounting theorems' production-faithfulness standard.
      5. **Layering.**  The general `apply_admissible_with_base`
         base-reduction was relocated to its proper home beside
         `apply_admissible_base` in `Authority/SignedAction.lean`.

    The `Accounting.lean` (GP.4.2) cross-references to
    `pool_balance_lower_bound_via_trace` were corrected: it is the
    surviving-balance FLOOR (the outflow-cap half), NOT the full
    solvency-reconciliation closure — that remains the separate
    `BridgeReachable` follow-up (WU C.6.4 / C.6.5).

    **Design note — the bound rests on the GP.7.2 `AuthorityPolicy`,
    not the bare `LocalPolicy`.**  The plan sketch keys the hypothesis
    off `gasPoolPolicy` (the `LocalPolicy`) and the single cap `m`, but
    the GP.7.2 audit already established why that is insufficient on its
    own: the `LocalPolicy` is *sender-blind* (so it cannot distinguish a
    pool-draining `transfer 0 gasPoolActor …` from a victim-draining
    `transfer 0 victim …`) and is subject to the *LP.7 meta-action
    exemption* (so it cannot keep itself in force across a trace).  The
    sound, faithful realisation therefore states the per-step controlling
    facts in terms of `gasPoolAuthorityPolicy` (GP.7.2), which binds
    `sender = gasPoolActor`, blocks the meta-actions, and forbids the
    off-leg surface — i.e. exactly the discipline the GP.7.4 genesis
    wiring (`deploymentPolicy.intersect (gasPoolAuthorityPolicy mEth
    mBold)`) ratifies.  The two per-step facts are:

      1. a `gasPoolActor`-signed step is authorised by
         `gasPoolActorAuthorized` (forcing a capped pool→sequencer
         transfer), and
      2. a non-`gasPoolActor`-signed step does not decrease the pool's
         resource-0 balance.

    Fact (2) is the plan's case (a) ("not signed by `gasPoolActor` ⇒ no
    decrease").  It is NOT vacuous — under `AuthorityPolicy.unrestricted`
    an arbitrary actor could sign `transfer 0 gasPoolActor recv amt` and
    drain the pool, since the kernel `transfer` law debits the action's
    `sender`, not the signer — so it is carried as an explicit,
    dischargeable per-step obligation (the deployment's `sender = signer`
    discipline) and PROVEN for the dominant honest action shape (a
    self-sender transfer by another actor, both the no-touch and the
    credit-to-pool branches) by `transfer_other_sender_pool_nondecreasing`.

    **Shipped surface.**
      - `apply_admissible_with_base` — the `.base`-reduction
        (`rfl`) the per-step proofs build on.
      - `gasPoolActorAuthorized_gasPool_imp_transfer` — decomposes the
        abstract authority predicate into the capped pool transfer.
      - `pool_signed_step_drain_le_eth` — the mathematical heart: an
        admitted `gasPoolActor`-signed step drains the ETH leg by at most
        `mEth` (ETH-leg debit `amount ≤ mEth` from the cap + `amount ≤
        balance` from the transfer precondition; BOLD-leg locality leaves
        resource 0 untouched).
      - `transfer_other_sender_pool_nondecreasing` — the external-case
        discharge.
      - `pool_step_drain_le_eth` — the combined per-step bound (pool case
        via the cap; external case via non-decrease).
      - `PoolBoundedTrace` — the length-indexed inductive trace relation
        (type-safe analogue of `applyTrace es trace = some es'`; the
        index `n` is the trace length).
      - `pool_drain_bounded_by_action_count`,
        `pool_balance_lower_bound_via_trace`,
        `pool_cannot_drain_when_cap_zero` (the `mEth = 0` boundary).
      - `gasPoolActorAuthorized_of_admissible_intersect` — the connector
        that discharges fact (1) from the genesis-wiring policy shape, so
        the headline is directly instantiable under
        `P₀.intersect (gasPoolAuthorityPolicy mEth mBold)`.

    The bound is stated for `ResourceId 0` (the ETH leg) per the plan;
    the per-resource generalisation (the BOLD leg + the two-leg
    independence) is the separate WU GP.7.5, and the per-leg locality
    half it needs (`pool_signed_step_drain_le_eth`'s BOLD branch) is
    already proven here.

    **Implementation note.**  `omega` cannot atomise `Amount`-typed
    (`= Nat`) terms — the same limitation `Laws.Transfer`'s
    `transfer_arithmetic` works around — so the per-step / trace algebra
    is discharged through small `Nat`-parameter helper lemmas
    (`drain_eth_step_arith`, `trace_drain_arith`,
    `lower_bound_drain_arith`) applied to the `Amount`-valued balances.
    The public theorems keep the plan's `≥` orientation (definitionally
    the `≤` form the proofs use).

    New `bridge-pool-drain-bound` suite ships **20 cases**: per-step ETH
    drain (value + the live per-step lemma), at-cap drain, BOLD-leg
    locality, external non-interference (+ the credit-to-pool branch),
    1-/2-/3-step pure-pool and mixed pool/external traces (numeric bound
    + floor), the discipline rejections (over-cap, victim-sender,
    non-sequencer, off-leg, meta-action, zero-amount), the `mEth = 0`
    boundary (positive ETH drain inadmissible; BOLD claim still works +
    `pool_cannot_drain_when_cap_zero`), genesis-wiring fidelity (declared
    `gasPoolPolicy` + intersected `gasPoolAuthorityPolicy`), the
    connector + decomposition, and term-level API stability for every
    headline theorem and both `PoolBoundedTrace` constructors.  All
    theorems depend only on `{propext, Classical.choice, Quot.sound}`; no
    kernel TCB delta, no new axioms.  `lake build` warning-free; `lake
    test` green; `count_sorries` / `tcb_audit` / `stub_audit` /
    `naming_audit` / `deferral_audit` / `lex_lint` / codemap gate all
    green.

  * **Goal.**  Prove the per-epoch pool-drain bound is a kernel
    invariant given the canonical `gasPoolPolicy`.
  * **File:** `LegalKernel/Bridge/PoolDrainBound.lean` (new).
  * **Deliverables.**

    ```lean
    /-- Pool drain bound: across any contiguous trace of
        `n` admitted SignedActions, the gas-pool actor's balance
        at resource 0 cannot have decreased by more than
        `n × maxDrainPerAction`.

        Proof: induction on the trace length.  Base case: empty
        trace, decrease is 0 ≤ 0 × m.  Inductive step: each
        admitted SignedAction either (a) is not signed by
        gasPoolActor (no decrease), or (b) is signed by
        gasPoolActor and passes `gasPoolPolicy`, so the amount
        transferred out is bounded by `maxDrainPerAction`.  Sum
        across the trace.
    -/
    theorem pool_drain_bounded_by_action_count
        (es es' : ExtendedState) (trace : List SignedAction)
        (m : Amount)
        (h_policy : es.kernel.policies[gasPoolActor]? = some (gasPoolPolicy m))
        (h_trace : applyTrace es trace = some es') :
        getBalance es'.kernel 0 gasPoolActor + trace.length * m ≥
        getBalance es.kernel 0 gasPoolActor
    ```
  * **Theorems.**
    * `pool_drain_bounded_by_action_count` (the headline).
    * `pool_balance_lower_bound_via_trace : ∀ es es' trace m,
      ... → getBalance es'.kernel 0 gasPoolActor ≥
      max 0 (getBalance es.kernel 0 gasPoolActor - trace.length * m)`.
  * **Tests.**  20 cases including the boundary case
    (`maxDrainPerAction = 0` means the pool cannot drain at all).
  * **Acceptance criteria.**  One reviewer; `lake exe count_sorries`
    green.
  * **Dependencies.**  GP.7.2.
  * **Estimated effort.**  ~10 hours.

#### WU GP.7.4: `gasPoolPolicy` ratification on genesis

  * **Status: COMPLETE — optimal closure (Lean + production CLI + Rust
    host).**  Beyond the initial Lean hook + self-contained CLI demo,
    the optimal-closure pass added the production-CLI reach, the
    config-driven opt-in, the `GasPoolSidecar`, the Rust
    `knomosis-host` forwarding, and the residual theorem completeness
    (see the "Optimal-closure additions" subsection at the end of this
    status block).  The GP.7.4 genesis hook ships in
    `LegalKernel/Bridge/GasPoolPolicy.lean`
    (alongside the GP.7.2 policy surface it wires — NOT the plan's
    tentative `Runtime/Replay.lean`; the bridge-specific helper belongs
    with the gas-pool machinery, where `gasPoolPolicy` /
    `gasPoolAuthorityPolicy` / `ExtendedState` / `LocalPolicies.declare`
    / `AuthorityPolicy.intersect` already are, keeping the generic
    replay module bridge-agnostic).  Shipped:

      1. **The genesis hook (both halves, atomic).**
         `gasPoolGenesisState es mEth mBold` declares
         `gasPoolPolicy mEth mBold` for `gasPoolActor` in the genesis
         `localPolicies`; `gasPoolGenesisPolicy P mEth mBold` intersects
         `gasPoolAuthorityPolicy mEth mBold` into the base policy `P`;
         and the `GasPoolGenesis` structure + `gasPoolGenesis base P
         mEth mBold` constructor bundle the two so a deployment CANNOT
         wire one half without the other (`gasPoolGenesis_wires_both_halves`).
         This makes the load-bearing GP.7.4 contract — wire BOTH the
         `LocalPolicy` declaration AND the `AuthorityPolicy` intersection
         — true by construction; the half-less wiring (which would leave
         the LP.7 meta-action hole open) is unreachable through the
         constructor.
      2. **Twelve contract theorems.**  State half:
         `gasPoolGenesisState_declares_policy`,
         `_preserves_other_localPolicies`,
         `_preserves_kernel_substates` (the wiring is surgical — only
         `localPolicies` changes).  Policy half:
         `gasPoolGenesisPolicy_rejects_meta` (the headline — `gasPoolActor`
         meta-actions barred under ANY base policy, closing the hole
         `gasPoolPolicy_admission_permits_meta_actions` exposed),
         `_other_actors_unrestricted` (the intersection narrows ONLY the
         pool), `_rejects_non_pool_sender` (the PR #106 fund-safety fix,
         ratified at genesis), `_rejects_off_gas_legs` /
         `_rejects_non_sequencer` / `_rejects_non_transfer`, and
         `_authorizes_sequencer_eth` / `_bold` (the legitimate capped
         claim is still admitted, given the base authorises it).
      3. **The worked example deployment**
         (`Deployments/Examples/GasPoolExample.lean`).  Constructs the
         genesis via `gasPoolGenesis exampleBaseState
         AuthorityPolicy.unrestricted 1000 3000` (the unrestricted base
         isolates the gas-pool narrowing as the demonstrated feature)
         and runs the FULL lifecycle through the production admission
         gate: a bridge-signed ETH `depositWithFee` (user +9000 ETH,
         pool +1000 ETH, user +50 budget), a bridge-signed BOLD
         `depositWithFee` (user +27000 BOLD, pool +3000 BOLD, user +150
         budget), an ETH-leg sequencer claim (capped `transfer` of 800
         from `gasPoolActor` to `sequencerActor`), and a BOLD-leg claim
         (2500).  `runGasPoolExamplePure` is the deterministic pure
         runner the integration test asserts against; `runGasPoolExample`
         is the IO entry the `knomosis gas-pool-demo` subcommand
         dispatches to.  The example ships its own deterministic demo
         verifier (`exampleVerify`/`exampleSign`) because the dev
         binary's linked `Verify` opaque returns `false` at the Lean
         level — a real deployment links ECDSA secp256k1 via `@[extern]`
         (RH-A.1).
      4. **Runs end-to-end via the `knomosis` binary** (the WU's
         acceptance criterion).  `knomosis gas-pool-demo` runs the four
         steps through `processSignedActionWith`, persists a log, and
         replays it via `replayWith` — confirming the genesis wiring
         survives the runtime's process → log → replay round-trip
         byte-for-byte — then prints the balances + budget and exits 0.
         The integration test pins the same IO entry returns 0.
      5. **Integration test** (`LegalKernel/Test/Deployments/GasPoolExample.lean`,
         `deployments-gas-pool-example` suite, 13 cases): the worked
         sequence is admitted; the final user / pool / sequencer
         balances on both legs; the user's L2 budget = free tier + both
         deposit grants; genesis fidelity (the state declares
         `gasPoolPolicy`); the discipline rejections against a
         well-funded pool (so the cap, not the balance, is the limiter)
         — over-cap ETH / BOLD claims, a pool meta-action, a
         victim-sender claim, a non-sequencer recipient; the
         intersection-narrows-only-the-pool positive case (a regular
         user transfer is still admitted); the IO binary round-trip; and
         term-level API stability for the genesis-hook surface.

    All theorems depend only on the canonical `{propext,
    Classical.choice, Quot.sound}` subset (the bare policy-half theorems
    use only `propext`); no kernel TCB delta, no new axioms.  `lake
    build` warning-free; `lake test` green; `count_sorries` /
    `tcb_audit` / `stub_audit` / `naming_audit` / `deferral_audit` /
    `mock_import_audit` / `lex_lint` / `lex_codegen --check` / codemap
    gate all green.  WU GP.7.5's worked BOLD-leg example deployment
    deliverable is subsumed here (the example exercises both legs).

  * **Optimal-closure additions.**  A follow-up pass took GP.7.4 to its
    fully-complete form across all three stacks:

      6. **Config-driven opt-in ("if the deployment's config says so").**
         `GasPoolConfig` + the `gasPoolGenesisStateOfConfig` /
         `gasPoolGenesisPolicyOfConfig` / `gasPoolGenesisOfConfig`
         builders gate the wiring on an `Option GasPoolConfig`: `none`
         leaves the genesis untouched (the pre-GP.7.4 behaviour
         byte-for-byte), `some cfg` wires both halves.  Theorems
         `gasPoolGenesisStateOfConfig_none` /
         `gasPoolGenesisPolicyOfConfig_none` (opt-out is a no-op) +
         `_some_declares_policy` / `_some_rejects_meta` (opt-in wires
         both halves).
      7. **Generic `knomosis` CLI gas-pool flags.**  `Main.lean` gains
         `--gas-pool-eth-cap` / `--gas-pool-bold-cap` (presence of
         either enables the gas pool; a missing cap defaults to 0),
         which build the gas-pool genesis (state + policy) via the hook
         and thread it through every log-touching subcommand
         (`process` / `replay` / `bootstrap` / `snapshot` /
         `replay-up-to` / `export-cell-proofs` /
         `export-terminate-bundle` / `extract-events`).  An
         operator now runs a real gas-pool deployment through the
         generic binary (verified end-to-end: the gas-pool genesis
         state hash is distinct from the plain genesis, and the sidecar
         cross-check accepts a matching config + rejects a wrong or
         disabled one with a clear `gas-pool-config error`).  *(Audit
         fix:* `export-terminate-bundle` initially threaded the gas-pool
         genesis WITHOUT a sidecar cross-check; a deep audit found its
         `claimedPostCommit` + `cellProofs` are computed against
         `commitExtendedState`, which includes `commitLocalPolicies`, so
         the bundle IS gas-pool-config-dependent.  The cross-check was
         added so a mismatched config fails early rather than producing
         an L1-rejected bundle.  The BUDGET sidecar is correctly NOT
         checked there — `commitExtendedState` excludes
         `budgetPolicy` / `epochBudgets`.)*
      8. **`GasPoolSidecar` config persistence**
         (`Runtime/GasPoolSidecar.lean`, mirroring the GP.6.2
         `BudgetSidecar`).  The config is persisted to `<log>.gaspoolcfg`
         and cross-checked on every log-touching command — because the
         gas-pool genesis `localPolicies` declaration participates in
         the per-log-entry post-state hash, a forgotten / changed /
         disabled cap fails loudly instead of as an opaque post-state-
         hash mismatch.  The disabled (`none`) case writes no sidecar,
         preserving the pre-GP.7.4 on-disk footprint.
      9. **Rust `knomosis-host` forwarding.**  The `CommandKernel`
         gains `with_gas_pool_policy` + a `gas_pool` field; the config
         parser gains `--gas-pool-eth-cap` / `--gas-pool-bold-cap` +
         `gas_pool_caps()`; `main` forwards them, so the network host's
         `CommandKernel` passes the caps to the spawned `knomosis
         process` argv (mirroring the GP.6.2 budget-flag forwarding).
         +7 host tests.
      10. **Residual theorem completeness.**
          `gasPoolGenesisPolicy_rejects_over_cap_eth` / `_bold` (the
          authority-layer per-action cap rejection, the genesis-level
          mirror of GP.7.2's `gasPoolPolicy_caps_per_action_*`) and
          `gasPoolGenesisPolicy_bars_self_declaration` (the
          structural-genesis necessity: once `gasPoolAuthorityPolicy` is
          in force, the pool cannot install / replace its own
          `LocalPolicy` via a signed `declareLocalPolicy`, so the
          declaration MUST be placed structurally at genesis — the two
          halves of one design, neither sound alone).

    Test deltas: `deployments-gas-pool-example` 13 → 17 (a
    proof-carrying budget-grant tie via
    `depositWithFee_grants_budget_bridge`; an honest per-half
    contribution test — the `LocalPolicy` caps the amount but is
    sender-blind + meta-exempt, the `AuthorityPolicy` is the binding
    enforcer; a restrictive-base `bridgePolicy` composition; and a
    snapshot round-trip of the gas-pool genesis state, connecting the
    GP.7.2 `gasPoolPolicy_roundtrip` / `_fieldsBounded` snapshot-
    encodability foundation); new `runtime-gas-pool-sidecar` suite (9
    cases).  Full Rust workspace (build / test / clippy / fmt) green;
    all Lean audits + codemap gate green; no kernel TCB delta, no new
    axioms.

  * **Goal.**  Make the canonical `gasPoolPolicy` declared at
    genesis time for any deployment that opts into GP.
  * **Files:**
    * `LegalKernel/Runtime/Replay.lean` (genesis-state setup).
    * `Deployments/Examples/GasPoolExample.lean` (new example
      deployment).
  * **Deliverables.**  Genesis hook that pre-declares
    `gasPoolPolicy maxDrainPerActionEth maxDrainPerActionBold`
    for `gasPoolActor` if the deployment's config says so.
    Example deployment showing the end-to-end flow including
    BOTH currency paths (ETH + BOLD deposits both flow through;
    sequencer claims at both legs are bounded by per-resource
    caps).
  * **Tests.**  Integration test exercising the full flow.
  * **Acceptance criteria.**  One reviewer; example deployment
    runs end-to-end via `knomosis` binary, including a BOLD
    deposit + L2 budget grant + sequencer BOLD-pool claim.
  * **Dependencies.**  GP.7.3.
  * **Estimated effort.**  ~8 hours (v1.0 estimated 6; +2 for
    BOLD-leg integration test coverage).

#### WU GP.7.5: BOLD-leg pool-slot ratification + drain bound (v1.2)

  * **Status: COMPLETE (theorem core delivered with GP.7.3's optimal
    closure; the worked BOLD-leg example deployment delivered by GP.7.4).**
    GP.7.3's per-resource generalisation ships this WU's headline +
    independence theorems in `LegalKernel/Bridge/PoolDrainBound.lean`:
    `pool_drain_bounded_by_action_count_per_resource` (the per-resource
    bound, of which the BOLD leg is the `rLeg = 1` specialisation
    `pool_drain_bounded_by_action_count_bold`),
    `pool_balance_eth_leg_independent_of_bold_actions` /
    `pool_balance_bold_leg_independent_of_eth_actions`, and
    `per_resource_pool_independence`.  The `bridge-pool-drain-bound`
    suite covers the BOLD-leg drain + leg independence.  The remaining
    GP.7.5-specific deployment-ratification deliverable — a worked
    BOLD-leg example deployment — is delivered by GP.7.4's
    `Deployments/Examples/GasPoolExample.lean`, which exercises BOTH gas
    legs end-to-end (a bridge-signed BOLD `depositWithFee` → pool BOLD
    credit + L2 budget grant → a capped BOLD-leg sequencer claim,
    alongside the ETH leg).
  * **Goal.**  Prove that the BOLD-leg pool-slot satisfies the
    same drain-bound discipline as the ETH-leg pool-slot, and
    that the two legs are mathematically independent.
  * **File:** `LegalKernel/Bridge/PoolDrainBound.lean`
    (extension of GP.7.3).
  * **Deliverables.**

    ```lean
    /-- Per-resource pool drain bound: across any contiguous
        trace of `n` admitted SignedActions, the gas-pool
        actor's balance at resource `r ∈ {0, 1}` cannot have
        decreased by more than `n × maxDrainPerAction r`.

        Generalises `pool_drain_bounded_by_action_count` from
        GP.7.3 to the per-resource case.  Proof: induction on
        the trace length, using the per-resource capAmount
        clause and the locality property that an action at
        resource `r ≠ r'` does not change the gasPoolActor's
        balance at `r'`. -/
    theorem pool_drain_bounded_by_action_count_per_resource
        (es es' : ExtendedState) (trace : List SignedAction)
        (mEth mBold : Amount) (r : ResourceId)
        (h_r_valid : r = 0 ∨ r = 1)
        (h_policy : es.kernel.policies[gasPoolActor]? =
                    some (gasPoolPolicy mEth mBold))
        (h_trace : applyTrace es trace = some es') :
        getBalance es'.kernel r gasPoolActor +
        trace.length * (if r = 0 then mEth else mBold) ≥
        getBalance es.kernel r gasPoolActor
    ```

  * **Theorems.**
    * `pool_drain_bounded_by_action_count_per_resource` (the
      headline).
    * `pool_balance_eth_leg_independent_of_bold_actions`: ETH-
      leg balance unchanged by actions at resource 1.
    * `pool_balance_bold_leg_independent_of_eth_actions`:
      symmetric.
    * `per_resource_pool_independence`: the combined statement
      that the two legs are mathematically separate accounting
      domains.

  * **Mathematical-soundness double-check.**

    1. **Locality follows from `LocalTo [r]`.**  Each `transfer`
       action carries a `resource : ResourceId`; the
       `Laws/Transfer.lean` instance `transfer_localTo` proves
       that a transfer at resource `r` doesn't touch any
       balance at `r' ≠ r`.  Per-resource pool independence is
       a direct corollary.

    2. **Bound applies independently.**  An action at resource
       0 consumes at most `maxDrainPerActionEth` from the ETH
       leg and zero from the BOLD leg (by locality).  An action
       at resource 1 consumes at most `maxDrainPerActionBold`
       from the BOLD leg and zero from the ETH leg.  Combined
       per-trace bound: `n_eth × maxDrainPerActionEth` on the
       ETH leg, `n_bold × maxDrainPerActionBold` on the BOLD
       leg, with `n_eth + n_bold = trace.length`.

    3. **Worst-case is achieved when all actions go to one leg.**
       If trace has `n` actions all at resource 0, BOLD leg
       drain bound is `0`; ETH leg drain bound is
       `n × maxDrainPerActionEth`.  ✓

  * **Tests.**  20 cases including:
    * Empty-trace base case.
    * All-ETH trace: BOLD balance unchanged.
    * All-BOLD trace: ETH balance unchanged.
    * Interleaved trace: per-leg bounds hold independently.
    * Edge case `maxDrainPerActionEth = 0`: ETH leg cannot
      drain at all.
    * Edge case `maxDrainPerActionBold = 0`: BOLD leg cannot
      drain at all.

  * **Acceptance criteria.**  One reviewer; `lake exe
    count_sorries` green; all per-resource drain-bound tests
    green.
  * **Dependencies.**  GP.7.3.
  * **Estimated effort.**  ~10 hours.

---

### Phase GP.8 — Sequencer integration

> **Superseded for implementation by
> [`GP.8_SEQUENCER_INTEGRATION_PLAN.md`](GP.8_SEQUENCER_INTEGRATION_PLAN.md).**
> That document is the unified, canonical sequencer plan: it reproduces
> WUs GP.8.1–GP.8.4 below (corrected against the shipped code and
> subdivided into GP.8.1a–c), adds the deferred v2 receipt-verified claim
> (GP.8.5), and folds in Workstream FQ as the inbound-liveness arm
> (Track A).  Only this §GP.8 section is superseded — the rest of
> Workstream GP remains owned by this document.  Where the two disagree on
> any sequencer-facing matter, the unified plan wins.

#### WU GP.8.1: Sequencer-claim mechanism (v1, honour-system)

  * **Goal.**  Document and implement the sequencer's claim flow
    in knomosis-host.
  * **Files:**
    * `runtime/knomosis-host/src/sequencer_claim.rs` (new).
    * `docs/abi.md` (extend §10 or add §11C).
  * **Deliverables.**  The sequencer periodically issues a
    `Action.transfer` from `gasPoolActor` to `sequencerActor` for
    the amount it estimates it has spent on L1 gas since the last
    claim.  The action is signed by the sequencer's pool-control
    key (a separately registered key with authority over
    `gasPoolActor` via a deployment-specific policy override).

    *Important:*  the v1 mechanism does NOT verify the claim is
    honest.  It is bounded by `gasPoolPolicy.capAmount`.  The
    dispute pipeline can challenge over-claims (operator-level
    enforcement).
  * **Tests.**  ~15 cases.
  * **Acceptance criteria.**  One reviewer; documentation
    explicit that v1 is honour-system bounded by `capAmount`.
  * **Dependencies.**  GP.7.4, GP.6.2.
  * **Estimated effort.**  ~8 hours.

#### WU GP.8.2: Free-tier sequencer policy

  * **Goal.**  Expose `--free-tier` and `--epoch-duration-seconds`
    in `knomosis-host` startup, with documented operational guidance.
  * **File:** `runtime/knomosis-host/src/main.rs` and
    `runtime/knomosis-host/README.md`.
  * **Deliverables.**  Two CLI flags.  Runbook section explaining
    how to set them based on (a) deposit volume, (b) sequencer's
    L1 budget, (c) acceptable user-facing latency.
  * **Tests.**  ~5 cases.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.6.2.
  * **Estimated effort.**  ~3 hours.

#### WU GP.8.3: Operator runbook (v1.0 baseline)

  * **Goal.**  A standalone operator runbook for deploying and
    running a GP-enabled Knomosis deployment.  v1.4 supersedes
    with the GP.8.4 expansion below for the v1.3 mechanism
    coverage.
  * **File:** `docs/gas_pool_runbook.md` (new).
  * **Deliverables.**  Sections:
    * Deployment checklist (`minFeeBps`, `maxFeeBps`,
      `weiPerBudgetUnit`, `freeTier`, `epochDuration`,
      `gasPoolActor LocalPolicy` parameters).
    * Calibration guidance for `weiPerBudgetUnit`: typical range
      `[10⁹, 10¹⁵]`; choose so that one budget unit costs
      ~$0.001–$0.01 in equivalent ETH at deployment time
      (allowing UI to display "your N budget units = ~$X of
      service" intuitively).
    * Health checks (pool balance trajectory, claim frequency,
      DoS-rejection counts).
    * Failure-mode response (pool drained, free-tier too low,
      attacker flooding).
    * Migration plan (legacy → GP-enabled deployment).
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.8.1, GP.8.2.
  * **Estimated effort.**  ~6 hours.

#### WU GP.8.4: Operator runbook v1.3 expansion (v1.4)

  * **Goal.**  Expand the operator runbook to cover the v1.3
    mechanism additions (multi-resource pool with BOLD,
    embedded AMM, Liquity V2 redemption-trigger circuit
    breaker, delegated topups) and the v1.4 hardening (AMM
    disaster recovery, gas benchmarks).
  * **File:** `docs/gas_pool_runbook.md` (extended).
  * **Deliverables.**

    New sections (additive to GP.8.3 baseline):

    1. **Multi-resource deployment checklist** (v1.2 baseline,
       v1.3 expanded):
       * Pre-deploy: verify canonical Liquity V2 BOLD address
         on the target chain; verify Liquity V2 BorrowerOps
         address (for auto-trigger).
       * Constructor argument table with USD-parity formula:
         `weiPerBudgetUnitBold = weiPerBudgetUnitEth × usdPerEth
         / usdPerBold`.
       * `ammSeedRatioBps`: start at 3000 (30 %), observe
         AMM depth vs sequencer claim rate, adjust via
         `KnomosisMigration` if needed.
       * `enableLiquityAutoCircuitTrigger`: typically `true`
         for production deployments; `false` for staging /
         testnet where manual override is preferred.

    2. **AMM operational guidance** (v1.3, v1.4):
       * **Arbitrage health monitoring**: spot-check
         `ammReserveEth / ammReserveBold` ratio against
         external Uniswap v3 ETH/BOLD spot price at least
         hourly.  Significant drift (> 1 %) indicates either
         (a) low arbitrage activity (UX problem), (b) bridge-
         specific liquidity constraint (raise
         `ammSeedRatioBps` via migration), or (c) operational
         issue.
       * **Swap volume monitoring**: track `AmmSwapExecuted`
         events; daily/weekly/monthly aggregates.  Sustained
         high volume justifies the AMM's existence; sustained
         low volume suggests calibration is off.
       * **Fee revenue tracking**: derive from the
         `k = R_eth × R_bold` growth between snapshots.
         Compare against (volume × fee_bps) for sanity check.

    3. **Liquity V2 branch-shutdown trigger operational guidance**
       (v1.6 amendment; supersedes the v1.3 redemption-rate sketch):
       * **Path A (manual)**: monitor each of the three pinned
         Liquity V2 collateral-branch `TroveManager` contracts
         (`LIQUITY_V2_TROVE_MANAGER_ETH` / `_WSTETH` / `_RETH`); if
         any branch's `shutdownTime()` returns a non-zero value, the
         on-call operator decides whether to call `closeBoldCircuit()`.
         This is the default; auto-trigger (Path B) is opt-in.
       * **Path B (auto)**: anyone can call
         `closeBoldCircuitIfAnyLiquityBranchShutdown()`.  Operator
         monitoring observes this and decides whether to
         `openBoldCircuit()` once the incident is understood.
         Operator should still maintain Path A as fallback in case
         the bridge's `LiquityV2ReadFailed` masks an auto-trigger
         outage.
       * **Re-open procedure**: confirm the underlying Liquity-V2
         incident is resolved (`shutdownTime` is monotonic — once
         set on a branch it never clears, so the call is a
         risk-acceptance decision rather than an "is it back to 0?"
         check); spot-check BOLD spot price from multiple sources;
         reconcile bridge BOLD escrow against
         `boldTotalLockedValue()`; call `openBoldCircuit()`.

    4. **AMM disaster recovery** (v1.4):
       * Conditions to invoke `emergencyDisableAmm()`:
         documented in WU GP.11.10.  Recap: pathological
         reserve depth, suspected math bug, Liquity V2
         unreachable, or critical audit finding.
       * Recovery decision tree:
         - **Within 7 days**: complete post-mortem, decide
           redeploy-vs-degraded-mode.
         - **Redeploy path**: prepare new `KnomosisBridge`
           deployment via `KnomosisMigration`; reserves carry
           over physically; new contract's AMM seeded from
           the legacy reserves.
         - **Degraded path**: continue operating without AMM;
           sequencer uses external L1 DEXes for ETH↔BOLD;
           document expected MEV cost increase per claim.

    5. **Gas-cost projections** (v1.4):
       * Reference baseline numbers from GP.11.9:
         depositETH ~80-120k, depositBold ~140-180k,
         ammSwap ETH→BOLD ~110-140k, ammSwap BOLD→ETH
         ~140-170k, closeBoldCircuit ~30-40k,
         closeBoldCircuitIfAnyLiquityBranchShutdown ~50-70k
         (close path, ETH-branch fast case; up to ~100k for the
         no-shutdown 3-branch read path).
       * UI guidance: display estimated bridge-gas cost at
         current gas price, factoring in user's chosen fee
         currency.

    6. **Delegated topup deployment guidance** (v1.3):
       * Recipients must explicitly declare delegation via
         `Action.declareLocalPolicy` with an
         `allowTopUpFrom` clause containing the trusted
         delegate's `ActorId`.
       * Service-provider integration pattern: app
         registers a service-account `ActorId`; user
         declares `allowTopUpFrom [serviceAccount]`; service
         tops up user budget on the user's behalf.
       * Revocation procedure: user signs
         `Action.revokeLocalPolicy` to immediately remove
         delegation.

    7. **Monitoring + alerting checklist**:
       * AMM reserve depth (alert if either reserve <
         `MIN_VIABLE_DEPTH_USD` = $10 000).
       * Per-resource pool balance (alert if either reserve
         deviates > 50 % from rolling 7-day average).
       * Sequencer claim frequency (alert if zero claims for
         > 48 hours — suggests pool starved or sequencer down).
       * Budget-rejection rate (alert if > 5 % of SignedActions
         are rejected for `InsufficientBudget` — suggests
         freeTier too low for current usage).
       * Liquity V2 read failures (alert on any
         `LiquityV2ReadFailed` — signals integration drift).
       * Circuit-breaker state (alert when
         `BoldCircuitClosed` event fires).

  * **Acceptance criteria.**  Two reviewers (one engineering,
    one operations); runbook reviewed by an actual deployment
    operator if available.
  * **Dependencies.**  GP.8.3, GP.11.{3,4,9,10}.
  * **Estimated effort.**  ~14 hours.

---

### Phase GP.9 — Optional improvements

These are explicitly *deferred* from v1 but planned in enough
detail that they can be picked up as v2 work without re-litigating
the design.

#### WU GP.9.1: Refund-on-exit (refund the remaining action budget)

  * **Goal.**  Let an actor withdraw **exactly the action budget they
    have left** — converting their own remaining, *purchased* budget
    back into a gas-resource payout from the unified pool, rather than
    the v1.1 sketch's `poolAmount × time-decay` refund.

  * **Why refund *budget*, not `poolAmount + time` (the design
    reversal).**  The v1.1 sketch (kept below under the superseded
    OQ-GP-10 resolution) refunded a time-amortised slice of the
    `poolAmount` fee, explicitly *avoiding* "refund the unused budget"
    on the grounds that tracking per-deposit budget consumption would
    require a `(depositId, remainingBudget)` linked-list per actor —
    significant state-bloat.  **That rationale no longer holds.**  The
    GP.1 per-actor budget ledger (`EpochBudgetState`, a
    `TreeMap ActorId ActorBudget`) ALREADY tracks each actor's
    remaining budget as a single counter
    (`EpochBudgetState.currentBudget`).  Refunding "the remaining
    budget" therefore reads a quantity the kernel already maintains —
    **no per-deposit tracking, no linked-list, zero new state-bloat**.
    The refund is computed from `currentBudget`, which is strictly
    simpler and more honest than the time-decay heuristic (a user who
    *spent* their budget on L2 service has a smaller `currentBudget`,
    so gets a smaller refund automatically — exactly the prepaid-
    service economics the v1.1 note wanted, now exact instead of
    approximated).

  * **The refundable amount.**  For claimant `a` with
    `C = currentBudget a` under a `bounded freeTier actionCost
    currentEpoch` budget policy:

    ```
    refundableBudget a = C - (actionCost + freeTier)      -- Nat truncated
    refundAmount       = budgetUnits × weiPerBudgetUnit    -- budgetUnits ≤ refundableBudget
    ```

    Two reserves are subtracted from `C` and are **never refundable**:

    1. `actionCost` — the refund action, like every action, costs the
       claimant `actionCost` budget; that cost is not itself refunded.
    2. `freeTier` — the per-epoch free allowance is a *subsidy*, not
       purchased budget, so it can never be converted into gas.  This
       is the load-bearing **anti-drain** subtraction: without it,
       every actor could drain `freeTier × weiPerBudgetUnit` of real
       gas out of the pool *per epoch* (the free tier is topped back
       up next epoch — so refunding it is minting money).

    The exchange rate `weiPerBudgetUnit` is the **trusted** deployment
    constant (per resource: `weiPerBudgetUnitEth` / `weiPerBudgetUnitBold`),
    the same rate the deposit grant uses (GP.5.1 / GP.5.4).  It is
    **not** a free user field — the admission gate pins
    `action.weiPerBudgetUnit = trustedRate[gasResource]`, so a refund
    can never inflate its own payout.

  * **Mathematical soundness (all four proven in Lean — see "Landed"
    below).**

    1. *Free-tier immunity.*  An actor at (or below) the free tier has
       `refundableBudget = 0`
       (`refundableBudget_eq_zero_of_le_reserves`): the subsidy never
       leaks.
    2. *Round-trip non-profitability.*  Refunding the budget a deposit
       granted (`poolAmount / weiPerBudgetUnit`, the floor-division
       grant) pays back at most the fee:
       `refundAmount (poolAmount / rate) rate ≤ poolAmount`
       (`refundAmount_le_deposit_fee`, by `Nat.div_mul_le_self`).  The
       floor-division residue stays in the pool; adding the per-action
       cost of the refund itself makes the cycle strictly lossy — so a
       deposit→refund loop can never extract more gas than was paid in.
    3. *No double refund.*  A successful refund consumes
       `actionCost + budgetUnits`, strictly lowering `currentBudget`
       (`currentBudget_after_refund_lt`), so the same budget cannot be
       refunded twice.
    4. *Free tier preserved.*  Bounding `budgetUnits ≤ refundableBudget`
       keeps the post-refund budget `≥ freeTier`
       (`currentBudget_after_refund_ge_free_tier`).

  * **The kernel leg (shipped — `Laws.claimBudgetRefund`).**  A
    `poolActor → claimant` transfer of `refundAmount` at `gasResource`
    — the exact mirror of `Laws.topUpActionBudget`'s
    `claimant → poolActor` direction.  Precondition:
    `getBalance s gasResource poolActor ≥ refundAmount` (the pool is
    solvent; otherwise `step_impl` makes it a no-op).  Conservation is
    a `gasPoolActor → user` transfer, fully provable — the law inherits
    the complete §4.11 ladder (`IsConservative`, `IsMonotonic`,
    `LocalTo [gasResource]`, `FreezePreserving`, per-actor deltas).

  * **Victim-balance safety (why a refund CANNOT be a generic
    `transfer`).**  A refund debits `gasPoolActor`'s balance but is
    signed by the *claimant* (a user).  `gasPoolAuthorityPolicy`
    (GP.7.2) authorises every action whose `signer ≠ gasPoolActor`
    (the `else True` branch), so a generic `transfer` with
    `sender = gasPoolActor` signed by ANY user would let that user
    drain the pool to themselves.  The refund is therefore a
    **dedicated `Action.claimBudgetRefund` constructor** with bespoke
    admission logic — never a reused `transfer` — whose payout the
    gate bounds to the signer's own refundable budget and whose
    `poolActor` field the gate pins to `gasPoolActor`.

  * **Landed (the full L2 signable action — complete, proven, tested).**
    The end-to-end L2 "click-to-withdraw" is wired through every layer
    of the Lean runtime; a user can sign a `claimBudgetRefund`, the
    admission gate proves it bounded / rate-pinned / pool-pinned /
    solvent, the kernel pays the claimant from the pool, the budget is
    retired, the log replays deterministically, and events are emitted.

    1. *`Action.claimBudgetRefund` constructor* at frozen index **22**
       (`Authority/Action.lean`).  Fields `(gasResource : ResourceId)
       (budgetUnits : Nat) (weiPerBudgetUnit : Nat) (poolActor :
       ActorId)`; the signer (claimant) is the enclosing
       `SignedAction.signer`.  `Action.compileTransition` no-ops;
       `Action.toTransition` threads the signer into
       `Laws.claimBudgetRefund signer poolActor gasResource
       (budgetUnits × weiPerBudgetUnit)` (the amount uses the action's
       gate-verified fields, so the kernel step is reproducible from the
       logged action alone — replay / fault-proof determinism).
    2. *Admission gate* (`apply_admissible_with_budget` +
       `apply_bridge_admissible_with_budget`, §13.6 two-reviewer): the
       new `claimBudgetRefund_gate` enforces the NINE conjuncts —
       `S ≠ bridgeActor`, `S ≠ poolActor`, `poolActor = gasPoolActor`
       (victim-drain pin), `gasResource ∈ {0,1}` (canonical-gas-leg pin,
       so an off-leg resource — where an accidental pool balance could
       accrue — can never be drained via a custom `refundRate`),
       `weiPerBudgetUnit = refundRate gasResource`
       (rate pin), `1 ≤ weiPerBudgetUnit` (the refund-ENABLED check, so
       the default `refundRate = 0` genuinely REJECTS refunds rather
       than admitting them as a budget-burning zero-payout no-op),
       `1 ≤ budgetUnits ≤ refundableBudget` (free-tier-excluding bound),
       and pool solvency.  The refund's budget effect
       is a **consume** of `actionCost + budgetUnits`
       (`refundConsumeExtra`), not an `applyGrant` top-up.  The trusted
       per-resource rate is threaded as ADMISSION CONFIG (`refundRate :
       ResourceId → Nat`, a trailing-default parameter — `fun _ => 0`
       disables refunds), NOT persisted state: the kernel step uses the
       action's logged `weiPerBudgetUnit`, so the rate never enters the
       state commit.  This was simpler + sounder than the earlier
       sketch's `BudgetPolicy`/genesis-config field (which would have
       churned every committed-state golden hash).
    3. *Headline soundness theorems* (`Authority/SignedAction.lean`,
       axioms ⊆ the canonical three):
       `claimBudgetRefund_gate_characterization` (the gate's exact
       reach), `admission_refund_consumes_budget` (budget retired =
       `actionCost + budgetUnits`), `admission_refund_preserves_free_tier`
       (the anti-drain guarantee, end-to-end), and the SIX rejection
       corollaries `refund_rejected_when_{pool_not_canonical,
       non_canonical_resource,rate_mismatch,over_refundable,
       pool_insolvent,rate_disabled}`
       (`rate_disabled` pins that the disabled default genuinely rejects,
       via the `1 ≤ weiPerBudgetUnit` gate conjunct;
       `non_canonical_resource` pins the `gasResource ∈ {0,1}` leg pin).  The two POSITIVE
       guarantees are mirrored on the production (bridge-aware) path —
       at an ARBITRARY deployment `refundRate`, NOT only the disabled
       default — by `admission_refund_consumes_budget_bridge` /
       `admission_refund_preserves_free_tier_bridge`
       (`Bridge/Admissible.lean`), which lift through the now
       rate-generic agreement corollaries
       (`apply_bridge_admissible_with_budget_{epochBudgets_eq,none_iff,
       kernel_epochBudgets,base_bridge_eq}` all thread `refundRate`).
       This closes a soundness gap the original mirrors left: they
       EXCLUDED refunds via `hne_refund` and only proved bridge↔kernel
       agreement at rate 0, so the production path's refund correctness
       was unproven at the only configuration in which refunds function
       (a nonzero rate) — exactly the "guaranteed-by-theorems" property
       the whole system rests on.
    4. *`kernelOnlyApply` mirror* (`Disputes/Evidence.lean`) threads the
       same `toTransition`, so `apply_admissible_with_eq_kernelOnlyApply`
       stays by `rfl` (fault-proof prefix-replay unchanged).
    5. *Append-only authority + classifier arms*: `bridgeAuthorizedAction
       => false` (user-initiated, never bridge-signed);
       `applyActionToBridgeState` no-op; `Action.doesNotDebitPoolAt`
       gains the correct `claimBudgetRefund` arm (a refund DOES debit
       the pool — `gr ≠ rLeg ∨ pa ≠ gasPoolActor` — closing the GP.7.3
       pool-drain classifier soundly; the unsound catch-all `True` is
       NOT used).  No `gasPoolDeniedTags` bump is needed: the deny-list
       `List.range 23` already covers tag 22, and `tag_lt_denyListBound
       : tag < 23` still holds (the bump to `List.range 24` is now
       deferred to the GP.11 `ammSwap` at index 23).
    6. *Events* (`Events/Extract.lean`): the claimant's gas credit and
       the pool debit surface as `balanceChanged` events, and the
       refund's budget debit is folded into the GP.6.4 `budgetConsumed`
       event's amount (`actionCost + budgetUnits`) — so the indexer's
       per-epoch consumed tally stays an EXACT mirror of the kernel.
       NO new `Event` constructor was needed (the existing events fully
       capture the refund), avoiding the entire Event cross-stack ripple.
    7. *CBE* (`Encoding/Action.lean`): encode / decode / `action_roundtrip`
       / `Action.tag_matches_encode_tag` / `fieldsBounded` + tag pin at
       22 + per-field injectivity.
    8. *Step-VM cell layout* (`FaultProof/{StepVMCoherence,StepVariants}.lean`):
       `actionKindByte` (→ 22), `actionFieldsForL1` (the frozen 4×uint64BE
       layout), `readOnlyCells`, `writeCells` (`[balance gr signer,
       balance gr pa, nonce signer]` — the MIRROR of `topUpActionBudget`).
       The cell-proof bundle is well-formed; `stepVMHash` returns the
       empty-hash sentinel for kind 22 (the L1-execution arm is the
       GP.5.3-style follow-on — exactly as kind 21 awaited GP.5.3 after
       GP.3.4).
    9. *Runtime threading* (`Runtime/Loop.lean`, `Runtime/Replay.lean`):
       a `RuntimeState.refundRate` field (default `fun _ => 0`) threaded
       into `processSignedActionWith` / `processPure` / `replayStepWith`
       / `replayLoopWith` / `replayWith` / `replayFromSeedWith` /
       `bootstrap` / `replay` (the restart-reconstruction path) /
       `extractEventsStepWith` (event extraction).  A deployment that
       offers refunds supplies its calibrated rate and refunds work
       end-to-end through the production gate.
    10. *Operator CLI + sidecar* (`Main.lean`,
       `Runtime/RefundRateSidecar.lean`): the `--wei-per-budget-unit-eth`
       / `--wei-per-budget-unit-bold` global flags thread the trusted
       rate into the runtime (`RuntimeState.refundRate`) for every
       log-touching subcommand (`process` / `replay` / `bootstrap` /
       `snapshot` / `replay-up-to` / `export-cell-proofs` /
       `extract-events`), and persist a non-default rate to a
       `<LOG>.refundratecfg` sidecar cross-checked on every such command
       (a forgotten / changed rate fails with a clear `refund-rate
       error`, not a silently-rejected-and-dropped refund on replay).
       Refunds DISABLED by default (rate 0, no sidecar — pre-GP.9.1
       on-disk footprint preserved).  `export-terminate-bundle` is
       deliberately untouched: it reconstructs via `kernelOnlyReplay`
       (no admission gate, uses the LOGGED `weiPerBudgetUnit`), so the
       terminate bundle is refund-rate-independent (as it is
       budget-config-independent).
    11. *Tests*: `bridge-budget-refund` grows to 30 cases (the gate
       accept + the six rejection classes — incl. the canonical-gas-leg
       pin — + `refundConsumeExtra` + two END-TO-END bridge-path
       admission cases driving `apply_bridge_admissible_with_budget` at a
       nonzero rate + the four round-trip-seal cases (the
       `topUpRoundTripCheck` value sweep + three END-TO-END top-up
       admissions: cheap mint rejected at an active rate, the same mint
       admitted at the disabled default, a fairly-priced mint admitted) +
       the Action-layer / admission-theorem / bridge-mirror API
       stability); `runtime-loop-happy-path` grows by 2 (a refund admitted
       / rejected through the literal `processSignedActionWith` runtime
       entry); the new `runtime-refund-rate-sidecar` suite (10 cases —
       codec round-trip, `toRefundRate`, `isDefault`, the
       `checkConsistent` / `writeSidecarIfAbsent` discipline, and the
       auditor `load` reconstruction); `encoding-action` grows by 4
       (round-trip, tag-22 pin, distinctness, field injectivity).  CLI
       smoke-tested end-to-end (the binary writes the sidecar, rejects a
       forgotten / mismatched rate, accepts the matching rate).

  * **Deployment-calibration sharp-edges (documented, not bugs).**
    * *Cross-resource rate consistency (N1).*  A claimant's budget is a
      single scalar but the payout is per-resource
      (`budgetUnits × refundRate gasResource`), so a deployment with
      asymmetric ETH / BOLD rates lets a claimant retire their one
      shared budget at the richest leg.  The gate forbids a double
      refund (single budget consumed once) and inflation (the rate is
      pinned, not user-chosen), but does NOT police cross-resource
      consistency: set `rate_eth : rate_bold` to the resources' real
      relative value (e.g. equal USD-per-budget-unit, as the GP.6.5
      calibration corpus does).  Warned in
      `RefundRateSidecar.RefundRateConfig`'s docstring + the CLI help.
    * *Cross-stack product overflow (N2, for the L1 follow-on).*
      `budgetUnits` and `weiPerBudgetUnit` are each `fieldsBounded` < 2^64
      (so each fits a `uint64` cell), but their PRODUCT (the payout) can
      reach ~2^128, so the future Solidity `_step22` MUST compute it in
      `uint256`.  Flagged at the `actionFieldsForL1` claimBudgetRefund
      arm.

  * **Solidity step-VM execution arm + Rust mirrors (LANDED).**  The
    operator CLI + sidecar (Landed item 10 above) and now the L1
    step-VM arm + the Rust mirrors are complete:
    * *L1 step-VM execution arm* (LANDED): the Lean `stepVMHash` kind-22
      recipe (`stepCommitClaimBudgetRefund` + the dispatcher arm +
      `stepVMHash_claimBudgetRefund_kind`; `actionKindByteCases` widened
      to 22, `stepVMHash_unknown_kind_empty` re-pinned at 23) + the
      Solidity `KnomosisStepVM._stepClaimBudgetRefund` (the **uint256**
      payout per N2; credit-claimant / debit-pool; pool-solvency guard)
      + the cross-stack `step_vm.json` corpus widened 248 → 258 (6 happy
      + 4 adversarial), so a refund step is L1-fault-proof-executable.
      The two parity theorems `coherence_claimBudgetRefund` /
      `cellwrites_claimBudgetRefund` close the GP.3.4-style gap.  **No
      `KnomosisBridge` redemption path is needed**: the refund is an L2
      balance credit, redeemed via the existing `withdrawWithProof`.
    * *Rust mirrors* (LANDED): the `knomosis-l1-ingest`
      `Action::ClaimBudgetRefund` encoder (tag 22; byte-pinned against
      Lean via the `deposit_with_fee_action.json` differential), the
      `knomosis-host` budget gate's refund arm (consume `action_cost +
      budget_units`; the policy-independent rejections; strict-mode pool
      solvency) + `CommandKernel` `with_refund_rate` forwarding of the
      `--wei-per-budget-unit-*` flags + the daemon config flags, the
      `knomosis-faultproof-observer` `ActionKind::ClaimBudgetRefund = 22`,
      and the `knomosis-indexer` (verified: NO code change — the widened
      `budgetConsumed` amount flows through the existing tag-20 decoder;
      pinned by a test).

  * **Acceptance criteria.**  Two reviewers (touches the GP.3.2
    admission gate).  The soundness theorems are mechanised (axioms ⊆
    the canonical three — incl. the two new bridge-path refund mirrors);
    `lake build` warning-free; `lake test` green (incl. the
    `bridge-budget-refund` 26 + `runtime-loop-happy-path` +2 +
    `runtime-refund-rate-sidecar` 9 + `encoding-action` +4 cases); the
    audit gates (`count_sorries` / `tcb_audit` / `naming_audit` /
    `deferral_audit` / …) pass.

  * **Dependencies.**  GP.3.2 (the budget admission gate), GP.7.1 /
    GP.7.2 (the `gasPoolActor` reservation + policy), GP.5.1 / GP.5.4
    (the deposit-side `weiPerBudgetUnit` rate), and GP.3.3 / GP.5.3
    (the step-VM dispatcher pattern the new variant follows).

  * **Estimated effort.**  ~16 hours for the remaining cross-stack
    landing (the Lean-side core is complete).

#### WU GP.9.2: Yield-bearing pool (Lido / Rocket Pool)

L1 contract amendment: `_registerDepositWithFee`'s `poolAmount`
portion is forwarded to `Lido.submit()` (or `RocketDepositPool.
deposit()`), and the L2 sees a wrapped-staked-ETH balance for the
gas-pool actor.  Introduces a new trust assumption on the staking
provider; documented in GENESIS_PLAN §15D.

#### WU GP.9.3: Tiered budget-grant schedule

v1.1 already provides per-deposit user-chosen `chosenFeeBps`.
v2 adds a *piecewise* `weiPerBudgetUnit` schedule: a deposit's
effective exchange rate becomes `weiPerBudgetUnit(poolAmount)` —
a piecewise function fixed at deploy time.  Cheaper budget grants
at higher fee tiers (e.g., 1 budget per 10¹² wei up to 0.1 ETH
of fee, 1 budget per 10¹¹ wei above that).  Encourages super-
user deposits without complicating the user-side UX:
`chosenFeeBps` remains a single uint16.  Trivially layerable on
top of GP.5.1's split logic.  No kernel changes.

#### WU GP.9.4: Dual pool (user rewards)

Split the skim into `gasPoolActor` (70%) and `userRewardPoolActor`
(30%).  The latter periodically calls `proportionalDilute` to
redistribute among long-term holders.  Trivially layerable.

#### WU GP.9.5: Stake-bonded identity registration

`KnomosisIdentityRegistry.registerECDSA` requires a slashable deposit
escrowed against the identity.  Independent workstream
(`Workstream SB`); referenced here for cross-link.

---

### Phase GP.10 — Documentation, audits, landing

#### WU GP.10.1: Genesis-Plan amendment §15E final

  * **Goal.**  Land the §15E section drafted in GP.0.1, updated
    to reflect any design refinements that emerged during
    implementation.
  * **File:** `docs/GENESIS_PLAN.md`.
  * **Acceptance criteria.**  Two reviewers; the post-implementation
    text is byte-equivalent to the GP.0.1 draft (any drift is
    flagged in PR review).
  * **Dependencies.**  All prior GP WUs.
  * **Estimated effort.**  ~3 hours.

#### WU GP.10.2: README and CLAUDE.md updates

  * **Goal.**  Update the project's top-level docs to reflect
    Workstream GP completion.
  * **Files:**
    * `README.md` (status badge + new feature description).
    * `CLAUDE.md` and `AGENTS.md` (the "Workstream snapshots"
      section gains a `Workstream GP` entry; the
      "Implementation roadmap" table gains a `GP` row; the
      `kernelBuildTag` is bumped to `"knomosis-unified-gas-pool"`
      and the corresponding regression pin in
      `Test/Umbrella.lean` is updated).
  * **Acceptance criteria.**  One reviewer.  CLAUDE.md and
    AGENTS.md remain byte-identical.
  * **Dependencies.**  GP.10.1.
  * **Estimated effort.**  ~4 hours.

#### WU GP.10.3: `docs/abi.md` extensions

  * **Goal.**  Document the new event variants on the wire.
  * **File:** `docs/abi.md`.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.6.1.
  * **Estimated effort.**  ~3 hours.

#### WU GP.10.4: Migration guide

  * **Goal.**  Concrete migration steps for a legacy Knomosis
    deployment to opt into Workstream GP.
  * **File:** `docs/gas_pool_migration_guide.md` (new).
  * **Acceptance criteria.**  One reviewer; an existing test
    deployment migrated end-to-end as proof of correctness.
  * **Dependencies.**  GP.8.3.
  * **Estimated effort.**  ~6 hours.

#### WU GP.10.6: Build-system + audit-binary updates (v1.4)

  * **Goal.**  Ensure all new Lean modules introduced across
    Phases GP.0 – GP.11 are properly registered in the build
    system (`lakefile.lean`) and the project's audit binaries
    (`tcb_allowlist.txt`, `tcb_audit`, `count_sorries`,
    `naming_audit`, etc.) so that CI gates fire on the new code.
  * **Files:**
    * `lakefile.lean` (add new `lean_lib` targets if needed,
      verify the umbrella module `LegalKernel.lean` re-exports
      every new module).
    * `tcb_allowlist.txt` (mostly should NOT change — new
      modules are non-TCB; verify nothing accidentally
      imports a TCB-core module).
    * `Tools/Common.lean` (the `tcbInternalImports` list —
      should NOT change for v1.0 – v1.3 work since none of
      it is TCB; verify).
    * `docs/std_dependencies.md` (cross-reference for any
      new Std imports — should be none for GP work, but
      verify).
    * `Lex/IndexRegistry.txt` (append the new Lex action-index
      entries for laws GP.2.1, GP.2.2, GP.3.4, GP.11.4 — and
      regenerate codegen sidecars via `lake exe lex_codegen
      --canonical`).
  * **Deliverables.**

    Audit checklist (each item runs as a `lake exe` command
    or shell script):

    1. `lake build` — full project builds without error.
    2. `lake test` — all 1900+ existing tests pass + the new
       GP tests (target ~2500+ total).
    3. `lake exe count_sorries` — returns 0 across all
       kernel-adjacent modules.  Specifically check:
       * `LegalKernel/Kernel.lean`
       * `LegalKernel/RBMapLemmas.lean`
       * `LegalKernel/Laws/*.lean` (every law including new
         `DepositWithFee`, `TopUpActionBudget`,
         `TopUpActionBudgetFor`, `AmmSwap`).
    4. `lake exe tcb_audit` — TCB-core modules import only
       allowlisted modules.  No GP work should appear in
       the TCB import set.
    5. `lake exe stub_audit` — no placeholder bodies.
    6. `lake exe naming_audit` — no forbidden tokens in
       declaration names.  Verify especially that no v1.4
       work names contain `_v3` / `_v4` / `wu_` / `audit_` /
       `tmp` / `todo`.
    7. `lake exe deferral_audit` — no `sorry`-in-disguise.
    8. `lake exe lex_lint` — Lex registry is append-only;
       all new action indices (19, 20, 21, 22) properly
       registered.
    9. `lake exe lex_codegen --check` — sidecars match.
    10. `lake exe mock_import_audit` — no production module
        imports `Test/*` (AR.9).
    11. CI workflow `.github/workflows/ci.yml` updated to run
        all of the above on every PR + push.

    Build-tag update:
    `LegalKernel.lean`'s `kernelBuildTag` bumps from
    `"knomosis-step-vm-coherence"` to
    `"knomosis-gas-pool-amm"` (per the v1.4-landing PR).
    `Test/Umbrella.lean`, `Lex/Test/M2.lean`, and
    `Lex/Test/ExampleLex.lean` regression pins all updated
    in the same PR.

    Tests:
    * Each new module has at least one test in its
      `LegalKernel/Test/...` companion.
    * The umbrella test driver (`Tests.lean`) imports every
      new test module.

  * **Acceptance criteria.**  All audit binaries green; CI
    passes; build-tag updated everywhere consistently.
  * **Dependencies.**  Every prior WU (this is the
    "make-sure-CI-is-actually-checking-our-work" pass).
  * **Estimated effort.**  ~6 hours.

#### WU GP.10.5: Full audit pass

  * **Goal.**  End-to-end review of the workstream including:
    * `lake exe count_sorries` = 0
    * `lake exe tcb_audit` clean
    * `lake exe stub_audit` clean
    * `lake exe naming_audit` clean
    * `lake exe deferral_audit` clean
    * `lake exe lex_lint` clean
    * `lake exe lex_codegen --check` clean
    * `cargo test --workspace --locked` green
    * `cargo clippy --workspace --all-targets -- -D warnings` clean
    * `forge test` green
    * Manual security review of the gas-pool policy + fee-split
      L1 logic against the attack tree in Appendix B.
  * **Acceptance criteria.**  Two reviewers; security checklist
    in Appendix B fully ticked.
  * **Dependencies.**  All prior WUs.
  * **Estimated effort.**  ~16 hours.

---

### Phase GP.11 — Embedded ETH↔BOLD AMM (v1.3)

The embedded AMM provides internal price discovery between ETH
and BOLD reserves, replacing the v1.2 "external L1 DEX" path for
sequencer claims and calibration drift mitigation.  The design is
constrained by the answers to OQ-GP-12 + the four AMM follow-up
questions:

* Constant-product `R_eth × R_bold = k` (Uniswap v2-style).
* 0.30 % swap fee (compile-time constant).
* Permissionless swapping.
* Gas pool is the sole LP — no LP tokens, no external LPs.
* MEV protection via `minAmountOut` + `deadline` parameters.

**v1.4 sub-WU subdivision.**  The AMM phase is the largest single
addition in v1.3.  v1.4 subdivides the work into focused sub-WUs
to enable parallel implementation by 2-3 contributors and to
make each sub-WU's audit obligation tractable in isolation.

| Sub-WU       | Scope                                                                              | Effort (h) | Reviewers | Files                                  |
| ------------ | ---------------------------------------------------------------------------------- | ---------- | --------- | -------------------------------------- |
| GP.11.1.a    | AMM storage variables (`ammReserveEth`, `ammReserveBold`)                          | 1          | 1         | `KnomosisBridge.sol`                      |
| GP.11.1.b    | Immutable `ammSeedRatioBps` + `MAX_AMM_SEED_RATIO_BPS` cap; constructor validation | 2          | 2         | `KnomosisBridge.sol` (constructor)        |
| GP.11.1.c    | Test: `ammSeedRatioBps = 0` (AMM disabled) preserves v1.2 behaviour                | 1          | 1         | `test/AmmStorage.t.sol`                |
| **GP.11.1 total** |                                                                              | **4**      |           |                                        |
| GP.11.2.a    | `_registerDepositWithFee` extension: split `poolAmount` into ammSeed + freePool    | 3          | 2         | `KnomosisBridge.sol`                      |
| GP.11.2.b    | Event extension: `DepositWithFeeInitiated` gains `ammSeedAmount` field             | 1          | 1         | `KnomosisBridge.sol`                      |
| GP.11.2.c    | Forge tests: `ammSeedAmount + freePoolAmount = poolAmount` for 1000+ fuzz inputs   | 3          | 1         | `test/AmmDepositSeeding.t.sol`         |
| **GP.11.2 total** |                                                                              | **7**      |           |                                        |
| GP.11.3.a    | Uniswap v2 swap-math library (`AmmMath.sol`) — pure functions                      | 4          | 2         | `solidity/src/lib/AmmMath.sol`         |
| GP.11.3.b    | `ammSwap` ETH→BOLD branch (with `payable`, `minAmountOut`, `deadline`)             | 4          | 2         | `KnomosisBridge.sol`                      |
| GP.11.3.c    | `ammSwap` BOLD→ETH branch (with `transferFrom` + balance-delta check)              | 4          | 2         | `KnomosisBridge.sol`                      |
| GP.11.3.d    | Event + error declarations (`AmmSwapExecuted`, 10+ error types)                    | 2          | 1         | `KnomosisBridge.sol`                      |
| GP.11.3.e    | Reentrancy tests (malicious BOLD mock + recursive ETH callback)                    | 3          | 1         | `test/AmmReentrancy.t.sol`             |
| GP.11.3.f    | k-monotonicity invariant test harness (1000+ randomized swap sequences)            | 4          | 1         | `test/AmmInvariants.t.sol`             |
| GP.11.3.g    | Slippage + deadline tests (12+ cases)                                              | 2          | 1         | `test/AmmSlippage.t.sol`               |
| GP.11.3.h    | Sandwich-attack simulator (4 cases: front-run, back-run, slippage stops it)        | 2          | 1         | `test/AmmSandwich.t.sol`               |
| **GP.11.3 total** |                                                                              | **25**     |           |                                        |
| GP.11.4.a    | New `Action.ammSwap` constructor at frozen index 22 (action layer)                 | 2          | 1         | `Authority/Action.lean`                |
| GP.11.4.b    | `Laws/AmmSwap.lean` definition (kernel law)                                        | 3          | 2         | `Laws/AmmSwap.lean`                    |
| GP.11.4.c    | Theorem ladder (8 theorems: increase_from, decrease_to, locality, ...)             | 5          | 2         | `Laws/AmmSwap.lean`                    |
| GP.11.4.d    | Lex re-expression of `ammSwap` for the Lex registry                                | 2          | 1         | `Laws/AmmSwap.lean`                    |
| GP.11.4.e    | Action-index registry update (`Lex/IndexRegistry.txt` append)                      | 0.5        | 1         | `Lex/IndexRegistry.txt`                |
| GP.11.4.f    | CBE encoding for `Action.ammSwap`                                                  | 2          | 1         | `Encoding/Action.lean`                 |
| GP.11.4.g    | Tests: 35 cases for the theorem ladder + boundary cases                            | 4          | 1         | `LegalKernel/Test/Laws/AmmSwap.lean`   |
| **GP.11.4 total** |                                                                              | **18.5**   |           |                                        |
| GP.11.5      | `ammReserveActor` reservation at `ActorId 3`; nextActorId bump                     | 2          | 1         | `Bridge/BridgeActor.lean`, `AddressBook.lean` |
| GP.11.6      | `ammReservePolicy` declaration + theorems                                          | 3          | 1         | `Bridge/AmmReservePolicy.lean`         |
| GP.11.7.a    | Cross-stack fixture generator: 60+ honest entries                                  | 6          | 1         | `LegalKernel/Test/Bridge/CrossCheck/AmmSwap.lean` |
| GP.11.7.b    | Cross-stack consumer: Solidity-side fixture replay                                 | 4          | 1         | `solidity/test/CrossCheck/AmmSwapFixtures.t.sol` |
| GP.11.7.c    | Cross-stack consumer: Rust-side fixture replay (knomosis-l1-ingest)                   | 4          | 1         | `runtime/knomosis-l1-ingest/tests/`       |
| **GP.11.7 total** |                                                                              | **14**     |           |                                        |
| GP.11.8      | State-root commitment integration (new in v1.4)                                    | 12         | 2         | Multiple                               |
| GP.11.9      | Gas-cost benchmarks (new in v1.4)                                                  | 8          | 1         | `test/BenchmarkGasV1_3.t.sol`          |
| GP.11.10     | AMM disaster recovery (new in v1.4)                                                | 12         | 2         | `KnomosisBridge.sol`, runbook             |
| **Phase GP.11 total** |                                                                          | **~118**   |           |                                        |

Most sub-WUs are 2-4 hours; the longest is GP.11.3.a + b + c
(the swap function implementation, 12 hours combined).  Parallel
plan: contributor A on GP.11.{1,2,3,8,9,10} (Solidity);
contributor B on GP.11.4 (Lean); contributor C on GP.11.5,
GP.11.6, GP.11.7 (cross-stack glue).  Expected
calendar: 3-4 weeks of focused parallel work.

The original WU specs that follow are the design rationale; the
sub-WU table above is the implementation roadmap.

---

#### WU GP.11.1: AMM state variables and reserves

  * **Goal.**  Add the AMM's L1 state variables to `KnomosisBridge`
    and the bookkeeping to track the gas pool's split between
    "free reserves" (claimable by sequencer) and "AMM liquidity"
    (locked in the constant-product curve).
  * **File:** `solidity/src/contracts/KnomosisBridge.sol`.
  * **Deliverables.**

    ```solidity
    /// @notice ETH currently in the AMM's reserves.  Funded from
    /// the gas pool's L1 reserve fraction allocated to AMM
    /// liquidity (see `ammSeedRatioBps`).  Mutated by every
    /// `ammSwap` call; never directly settable.
    uint256 public ammReserveEth;

    /// @notice BOLD currently in the AMM's reserves.  Same
    /// constraints as `ammReserveEth` on the BOLD leg.
    uint256 public ammReserveBold;

    /// @notice Compile-time fraction of pool deposits that
    /// flows to AMM liquidity vs free pool reserves.  At
    /// deployment time, operator sets this fraction; e.g.,
    /// 5000 bps = 50 % of each fee deposit goes to AMM
    /// liquidity, 50 % stays as free pool reserves claimable by
    /// sequencer.  Once set, immutable.
    uint16 public immutable ammSeedRatioBps;

    /// @notice Compile-time AMM swap fee in basis points.
    /// 30 bps = 0.30 %, matching Uniswap v2's standard fee.
    uint16 public constant AMM_SWAP_FEE_BPS = 30;

    /// @notice Compile-time hard cap on the AMM seed ratio.
    /// At 80 % seed ratio, only 20 % of pool fees stay claimable
    /// by the sequencer for immediate L1-gas reimbursement; the
    /// rest is committed to the AMM.  Higher ratios risk
    /// starving sequencer claims during peak L1-gas periods.
    uint16 public constant MAX_AMM_SEED_RATIO_BPS = 8000;
    ```

  * **Constructor extension:**

    ```solidity
    constructor(
        ...,
        uint16 _ammSeedRatioBps
    ) {
        if (_ammSeedRatioBps > MAX_AMM_SEED_RATIO_BPS)
            revert AmmSeedRatioExceedsMax(_ammSeedRatioBps);
        ammSeedRatioBps = _ammSeedRatioBps;
        // ammReserveEth and ammReserveBold start at 0; seeded by
        // the first deposit that produces non-zero pool fees.
    }
    ```

  * **Soundness analysis:**
    * `ammSeedRatioBps = 0` means the AMM is disabled at
      construction.  Useful for deployments that don't want the
      AMM but want the rest of the v1.3 mechanism.  In this
      case the AMM reserves stay at zero and `ammSwap` reverts
      with `AmmEmpty`.
    * `ammSeedRatioBps = MAX_AMM_SEED_RATIO_BPS` (80 %) is the
      maximum allowed.  Higher values would risk starving
      sequencer claims; this cap is the structural defence.
    * The two reserves are mutated exclusively by deposit-side
      seeding (in `_registerDepositWithFee`) and swap-side
      execution (in `ammSwap`).  No other write paths exist.

  * **Tests.**  10 cases including `ammSeedRatioBps = 0`,
    `ammSeedRatioBps = MAX`, constructor reverts on
    `> MAX`, immutability check (cannot mutate post-deploy
    even via admin functions).
  * **Acceptance criteria.**  One reviewer; constructor
    extension does not break existing v1.2 deployments
    (default `ammSeedRatioBps = 0` preserves v1.2 behaviour).
  * **Dependencies.**  GP.5.1.
  * **Estimated effort.**  ~4 hours.
  * **Status: COMPLETE (Solidity side).**  `KnomosisBridge.sol`
    ships the two AMM reserve slots (`ammReserveEth` /
    `ammReserveBold`, mutable, no direct setter), the immutable
    `ammSeedRatioBps` (validated `<= MAX_AMM_SEED_RATIO_BPS` at
    construction, `AmmSeedRatioExceedsMax` otherwise), and the two
    constitutional caps `AMM_SWAP_FEE_BPS = 30` /
    `MAX_AMM_SEED_RATIO_BPS = 8000`.  The seed ratio is threaded as a
    new `ConstructorArgs.ammSeedRatioBps` field; every existing
    initializer (the `Deployer` helper + 15 test sites) passes `0`, so
    pre-v1.3 deployment shapes are byte-unchanged and `AMM-disabled`.
    The two new caps join the GP.5.2 source-level audit gate
    (`scripts/audit_compile_time_caps.sh`, now 6 caps + 4 address
    pins + 1 symbol pin; self-test 37 → 45 cases) AND a runtime pin
    (`AmmStorage.t.sol::test_ammCompileTimeCaps_pinned`), matching the
    dual-layer protection the fee-split caps already carry.  GP.11.1 is
    purely additive: no deposit-seeding (GP.11.2) or swap (GP.11.3)
    logic ships yet, so the reserves stay 0 for the lifetime of a
    GP.11.1-era deployment regardless of the seed ratio — proven by
    `AmmStorage.t.sol` (16 cases: caps pinned, seed-ratio
    store/validate incl. the `> MAX` + `uint16`-max reverts and a
    `[0, MAX]` accept / `(MAX, uint16Max]` reject fuzz pair, reserves
    start-and-stay zero, the v1.2-preservation acceptance criterion
    — a disabled deposit matches the `FeeSplitMath` reference and a
    `0`-vs-`MAX` cross-ratio deposit emits a byte-identical split via
    `vm.expectEmit` — the "no mutation surface even via admin functions"
    criterion via a no-AMM-setter-selector probe, the BOLD leg via a
    real `depositBoldWithFee` that leaves both reserves at 0, and a
    constructor-guard ordering pin).
    `forge build` warning-free; full `forge test` green (661 passed,
    +16).  Lean / Rust untouched (the L2 mirror is GP.11.4 / GP.11.5);
    the lockstep version bump's inertness is confirmed by re-running the
    Lean (`lake build` + `lake test`) and Rust (`cargo` build / test /
    clippy / fmt) gates green.

#### WU GP.11.2: AMM seeding on deposit

  * **Goal.**  Modify `_registerDepositWithFee` to split the
    `poolAmount` between the gas pool's free reserves and the
    AMM's locked liquidity, per the immutable `ammSeedRatioBps`.
  * **File:** `solidity/src/contracts/KnomosisBridge.sol`.
  * **Deliverables.**

    ```solidity
    function _registerDepositWithFee(
        uint64 resourceId,
        address token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant
    ) internal {
        // (existing global TVL cap check)
        // (existing per-BOLD TVL cap check)

        // v1.3: split poolAmount between AMM liquidity and free
        // pool reserves.
        //
        // v1.5 fix: if the AMM has been disabled via
        // `emergencyDisableAmm()` (GP.11.10), route the ENTIRE
        // poolAmount to free pool reserves and skip AMM
        // seeding.  Continuing to seed a disabled AMM would
        // grow reserves that can no longer participate in
        // swaps, which (a) wastes operator capital, (b) makes
        // the disabled state less recoverable, and (c) could
        // amplify the impact of whatever bug or condition
        // motivated the disable in the first place.
        uint256 ammSeedAmount;
        if (ammDisabled) {
            ammSeedAmount = 0;
        } else {
            ammSeedAmount =
                (poolAmount * uint256(ammSeedRatioBps)) / 10_000;
        }
        uint256 freePoolAmount;
        unchecked { freePoolAmount = poolAmount - ammSeedAmount; }

        // Add the seed amount to the appropriate AMM reserve.
        // (When ammDisabled, ammSeedAmount = 0, so these +=
        // calls are no-ops; safe to skip the conditional but
        // clearer to keep the structure parallel to v1.3.)
        if (resourceId == RESOURCE_ID_NATIVE_ETH) {
            ammReserveEth += ammSeedAmount;
        } else if (resourceId == RESOURCE_ID_BOLD) {
            ammReserveBold += ammSeedAmount;
        }
        // Other resources: no AMM seeding (out of scope for v1.3).

        // Emit DepositWithFeeInitiated with the split breakdown.
        // The L2 ingest needs both freePoolAmount and
        // ammSeedAmount to reflect the gas pool's L2 balance
        // correctly (free pool credits gasPoolActor at L2; AMM
        // seed credits a new ammReserveActor at L2 — see GP.11.4).

        // v1.4 fix: receiptHash MUST include every emitted field
        // to prevent malicious replay-with-modified-fields.  The
        // L2 ingestor verifies the receiptHash matches what it
        // would have computed for the (sender, resourceId, token,
        // userAmount, freePoolAmount, ammSeedAmount, budgetGrant,
        // depositNonce) tuple before constructing the L2 action.
        bytes32 receiptHash = keccak256(abi.encode(
            msg.sender,
            resourceId,
            token,
            userAmount,
            freePoolAmount,
            ammSeedAmount,
            budgetGrant,
            depositNonce
        ));

        emit DepositWithFeeInitiated(
            msg.sender, resourceId, token,
            userAmount, freePoolAmount, ammSeedAmount, budgetGrant,
            depositNonce, receiptHash
        );
        depositNonce++;
    }
    ```

    Event signature extended: `DepositWithFeeInitiated` now
    includes `ammSeedAmount` as a new field (v1.3 wire-format
    addition; bumps the event signature hash so v1.3 ingest
    decoders are required for v1.3 deployments).

  * **Soundness analysis:**
    * `ammSeedAmount ≤ poolAmount` because
      `ammSeedRatioBps ≤ 10000`.  So `freePoolAmount = poolAmount
      - ammSeedAmount ≥ 0`.  Safe under `unchecked`.
    * Conservation: `userAmount + freePoolAmount + ammSeedAmount
      = userAmount + poolAmount = msg.value` (for ETH).  All
      funds accounted for; nothing minted from nothing.
    * `ammReserveEth` / `ammReserveBold` grow monotonically with
      deposits.  Never shrink due to deposit-side flow; only the
      `ammSwap` function can decrement them (and only via
      exchange — total reserve value monotonically increases due
      to swap fees, see GP.11.3 invariant).
    * The split is deterministic given `(poolAmount,
      ammSeedRatioBps)`, both of which are well-defined; so the
      math is reproducible across the cross-stack equivalence
      corpus.

  * **Tests.**  15 cases.  Specifically test that
    `ammSeedAmount + freePoolAmount = poolAmount` exactly,
    across the full range of `(poolAmount, ammSeedRatioBps)`
    inputs.
  * **Acceptance criteria.**  One reviewer; conservation
    invariant verified for every fuzz input.
  * **Dependencies.**  GP.11.1, GP.5.1.
  * **Estimated effort.**  ~6 hours.
  * **Status: COMPLETE (plan-literal, cross-stack).**  `KnomosisBridge.sol`'s
    shared `_registerDepositWithFee` now seeds the embedded AMM from the
    pool fee via the new `private _seedAmmReserves(resourceId, poolAmount)`
    helper: it computes `ammSeedAmount = floor(poolAmount *
    ammSeedRatioBps / 10000)` (`0` when the AMM is disabled, the seed
    floors to zero, or the resource is off the ETH/BOLD gas legs) and
    grows the matching reserve (`ammReserveEth` / `ammReserveBold`).  The
    free-pool remainder is the implicit `poolAmount - ammSeedAmount`.
    Conservation holds end-to-end — `userAmount + poolAmount == deposit`
    (the entry point's floor split) and `poolAmount == ammSeedAmount +
    freePoolAmount` (the GP.11.2 internal-accounting split), so `userAmount
    + ammSeedAmount + freePoolAmount == deposit` — and the seed is a
    reclassification of value already inside `totalLockedValue`, so no TVL
    re-accounting is needed (`ammReserveEth + ammReserveBold <=
    totalLockedValue` is a Foundry invariant).  The `poolAmount * ratio`
    multiply and the `reserve + ammSeedAmount` add use checked arithmetic
    (`ratio <= MAX_AMM_SEED_RATIO_BPS = 8000 < 10000` makes `ammSeedAmount
    <= poolAmount`; both are physically unreachable to overflow and revert
    rather than wrap on the impossible case).  `_seedAmmReserves` carries
    a `GP.11.10 hook point` comment marking the exact line the future
    `emergencyDisableAmm()` early-out will occupy.

    **Wire format — plan-literal (the split lives in the canonical event +
    receiptHash).**  The split is carried in the canonical
    `DepositWithFeeInitiated` event by inserting a `uint256 ammSeedAmount`
    field after `poolAmount`, and BOUND in the `receiptHash`
    (`keccak256(abi.encode(deploymentId, sender, resourceId, token,
    userAmount, poolAmount, ammSeedAmount, budgetGrant, depositorNonce))`).
    The L2 reconstructs `freePoolAmount = poolAmount - ammSeedAmount` from
    ONE event, and a replay with a tampered split is rejected (the
    receiptHash is sensitive to `ammSeedAmount`, pinned by
    `AmmDepositSeeding.t.sol::test_receiptHash_bindsAmmSeedAmount`).  This
    is the additive form (keep `poolAmount`, insert `ammSeedAmount`) rather
    than the sketch's rename `poolAmount → freePoolAmount`: it preserves
    the informative total fee, minimises corpus churn, and is equally
    tamper-evident (`poolAmount` and `ammSeedAmount` together fully
    determine the split).  `ammSeedAmount == 0` on an AMM-disabled
    deployment, so the field is present but zero there.

    The change bumps the event's topic-0 hash (to
    `0xdffb2055…e4c8f5`) and the receiptHash preimage (9 fields / 288
    bytes; tail 8 fields / 256 bytes), which the plan explicitly accepts as
    a v1.3 wire-format addition.  It is propagated cross-stack in lockstep:

      * **Rust ingestor** (`knomosis-l1-ingest::events`):
        `DEPOSIT_WITH_FEE_INITIATED_TOPIC` + the signature string + the
        `decode_event` field offsets (`ammSeedAmount` at data offset 64;
        `budgetGrant`/`nonce`/`receiptHash` shifted to 96/128/160) + the
        `IngestedEvent::DepositWithFeeInitiated.amm_seed_amount` variant
        field + the `.cxsf` serializer/deserializer + the affected tests.
        Translation stays `NoAction` (deposit materialisation remains the
        sequencer's responsibility).
      * **Cross-stack receiptHash corpora** (`deposit_fee_split.json` +
        `deposit_fee_split_bold.json`): the Lean generators
        (`DepositFeeSplit.lean` / `DepositFeeSplitBold.lean`) add the
        `ammSeed` reference (+ the proof-carrying `ammSeed_le` /
        `ammSeed_conserves` bounds), the per-entry `ammSeedRatioBps` /
        `ammSeedAmount` fields, and the 9-field receiptHash recipe; the 16
        fee-split corners stay AMM-disabled (ratio 0), 6 AMM-enabled boundary
        corners (`ammcorner:*` — max-fee × max-ratio, budget-clamp ×
        max-ratio, exact-half × max-ratio, dust-floors-to-zero @ ratio 8000,
        min-non-zero ratio, realistic mid-ratio) are appended (corpus 80 →
        86), and the 64 randomised entries draw a random `ammSeedRatioBps ∈
        [0, 8000]`, so 69 of 86 entries carry a NON-ZERO `ammSeedAmount`
        whose receiptHash binding is verified cross-stack — and the
        generator publishes a `countNonZeroSeed` header each Solidity
        consumer independently recounts + asserts (`>= 50`), so the binding
        coverage cannot silently regress to all-zero.  The Solidity consumers
        (`DepositFeeSplit.t.sol` / `DepositFeeSplitBold.t.sol`) recompute the
        split via `FeeSplitMath.ammSeedSplit`, byte-match the 256-byte
        preimage tail, and deploy each entry's bridge at its `ammSeedRatioBps`
        so the EMITTED `ammSeedAmount` (and the live reserve delta) match the
        Lean value.  `bold_deposit.json` (GP.6.5, an L2 action + budget
        corpus) and `DepositReceiptHash` (the plain-deposit corpus) are
        unchanged; their Solidity consumers' event decoders absorb the new
        (zero) `ammSeedAmount` field.

    **Tests.**  New `test/AmmDepositSeeding.t.sol` (~26 cases — 19 unit /
    fuzz + a 7-invariant stateful suite): per-leg seeding with
    the canonical event's `ammSeedAmount` field, the disabled / zero-fee /
    dust-floor `ammSeedAmount == 0` paths (decoded from the event),
    `test_receiptHash_bindsAmmSeedAmount` + the BOLD-leg
    `test_boldReceiptHash_bindsAmmSeedAmount` (tamper-evidence), leg
    independence, monotonic accumulation, the reserve-subset-of-TVL bound,
    `test_cappedDeposit_revertsAndDoesNotSeed` + `test_plainDepositETH_doesNotSeed`
    (the negative paths — a reverted or non-fee-split deposit seeds nothing),
    `test_seedAmmReserves_offLeg_seedsNothing` (the off-gas-leg `else` branch
    via a `SeedHarness` exposing the now-`internal` helper),
    `test_ammSeedSplit_knownVectors` (a non-circular hand-computed anchor for
    the `FeeSplitMath` reference), `test_gas_seedingOverhead` (a COMPARATIVE
    gas pin — enabled minus disabled overhead `< 15k`, far tighter than the
    absolute envelope), the conservation fuzz over both legs + the whole `[0,
    8000]` ratio range, and the stateful `AmmDepositSeedingInvariantTest`
    (a 7-invariant suite: `ammReserveEth == sum-of-admitted-ETH-seeds`,
    `ammReserveBold == sum-of-admitted-BOLD-seeds`, the global `reserves <=
    TVL`, the two PER-CURRENCY bounds `ammReserveBold <=
    boldTotalLockedValue` + `ammReserveEth + boldTotalLockedValue <=
    totalLockedValue` — which catch a wrong-leg seed the global bound would
    mask when the other leg has slack — AND the two REAL-TOKEN backing
    bounds `ammReserveEth <= address(bridge).balance` / `ammReserveBold <=
    BOLD.balanceOf(bridge)`, the ultimate solvency statement that the
    reserve is backed by actual tokens the bridge holds, not merely the TVL
    accounting variable (catches a TVL-vs-balance divergence the
    accounting-only bounds would miss) — over 128 000 random ETH+BOLD
    deposits at a moderate cap so some deposits revert).  The deposit→withdraw
    interaction (the seeded reserve
    surviving a withdrawal) is covered end-to-end by the AMM-enabled
    `BridgeFeeSplitBold.t.sol::test_e2e_ammReserveSurvivesBoldWithdrawal`,
    which drains TVL to exactly the seed floor and asserts `ammReserveBold <=
    boldTotalLockedValue <= totalLockedValue` survives.
    `AmmStorage.t.sol`'s ratio-invariance test is
    `test_coreSplit_ratioInvariant_butAmmSeedScales` (the core
    user/pool/budget triple is ratio-invariant while the canonical event's
    `ammSeedAmount` + receiptHash scale with the ratio).  The behavioural
    fee-split suites (`BridgeFeeSplit.t.sol` / `BridgeFeeSplitBold.t.sol`)
    + `FeeSplitMath.receiptHash` thread the new `ammSeedAmount` field.
    `forge build` warning-free; full `forge test` green; the GP.5.2
    cap-audit gate + self-test (45 cases) stay green (no cap changed); the
    full Lean (`lake build` + `lake test`) and Rust (build / test / clippy
    / fmt) gates green.  The L2 `Action.ammSwap` mirror + `ammReserveActor`
    remain GP.11.4 / GP.11.5; the deposit-side L2 reconstruction that
    consumes the `ammSeedAmount` field lands with the sequencer-side
    deposit-materialisation work.

#### WU GP.11.3: AMM swap function

  * **Goal.**  Implement the constant-product swap function with
    Uniswap v2-style math, 0.30 % fee, and slippage protection.
  * **File:** `solidity/src/contracts/KnomosisBridge.sol`.
  * **Deliverables.**

    ```solidity
    /// @notice Permissionless ETH↔BOLD swap via the bridge's
    /// internal constant-product AMM.  Fee is 0.30 %; fee
    /// revenue stays in the reserves (Uniswap v2-style),
    /// growing the pool over time.
    ///
    /// @param fromResource Resource the caller is supplying
    /// (0 = ETH, 1 = BOLD).
    /// @param amountIn Amount of the input resource the caller
    /// is supplying.
    /// @param minAmountOut Minimum acceptable output amount;
    /// transaction reverts if actual output is less.
    /// @param deadline Unix timestamp after which the
    /// transaction reverts.  MEV-protection against
    /// transactions sitting in the mempool too long.
    function ammSwap(
        uint64 fromResource,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable nonReentrant ammActive returns (uint256 amountOut) {
        // v1.5 fix: `ammActive` modifier was specified in
        // GP.11.10's disaster-recovery section but missing
        // from this function signature in v1.3-v1.4.  The
        // modifier reverts with AmmDisabled when the operator
        // has triggered `emergencyDisableAmm()`.
        if (block.timestamp > deadline) revert SwapDeadlineExpired();
        if (amountIn == 0) revert ZeroSwapInput();

        uint256 reserveIn;
        uint256 reserveOut;
        uint64 toResource;

        if (fromResource == RESOURCE_ID_NATIVE_ETH) {
            if (msg.value != amountIn) revert EthAmountMismatch();
            reserveIn = ammReserveEth;
            reserveOut = ammReserveBold;
            toResource = RESOURCE_ID_BOLD;
        } else if (fromResource == RESOURCE_ID_BOLD) {
            if (msg.value != 0) revert UnexpectedEth();
            // Pull BOLD from caller via transferFrom.
            IERC20 boldToken = IERC20(BOLD_TOKEN_ADDRESS);
            uint256 balBefore = boldToken.balanceOf(address(this));
            bool ok = boldToken.transferFrom(
                msg.sender, address(this), amountIn);
            if (!ok) revert TransferFailed();
            uint256 balAfter = boldToken.balanceOf(address(this));
            if (balAfter - balBefore != amountIn)
                revert BoldTransferAmountMismatch(amountIn,
                    balAfter - balBefore);

            reserveIn = ammReserveBold;
            reserveOut = ammReserveEth;
            toResource = RESOURCE_ID_NATIVE_ETH;
        } else {
            revert UnsupportedSwapResource(fromResource);
        }

        if (reserveIn == 0 || reserveOut == 0) revert AmmEmpty();

        // Uniswap v2 swap math:
        //   amountInWithFee = amountIn × (10000 − AMM_SWAP_FEE_BPS)
        //   numerator       = amountInWithFee × reserveOut
        //   denominator     = reserveIn × 10000 + amountInWithFee
        //   amountOut       = numerator / denominator
        //
        // The fee stays in the pool: new reserveIn =
        // reserveIn + amountIn (full amount), but only
        // amountInWithFee participates in the swap math.
        // This makes k = R_in × R_out monotonically non-
        // decreasing, with strict increase per swap.
        uint256 amountInWithFee =
            amountIn * (10_000 - uint256(AMM_SWAP_FEE_BPS));
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator =
            reserveIn * 10_000 + amountInWithFee;
        amountOut = numerator / denominator;

        if (amountOut < minAmountOut)
            revert SlippageExceeded(amountOut, minAmountOut);
        if (amountOut >= reserveOut) revert ReserveExhausted();

        // Update reserves.
        uint256 newReserveIn;
        uint256 newReserveOut;
        unchecked {
            newReserveIn = reserveIn + amountIn;
            newReserveOut = reserveOut - amountOut;
        }
        // Safe: newReserveIn = reserveIn + amountIn ≤ uint256.max
        // for any realistic amountIn (the existing TVL cap also
        // bounds this).  newReserveOut = reserveOut - amountOut
        // is safe because amountOut < reserveOut is checked above.

        if (fromResource == RESOURCE_ID_NATIVE_ETH) {
            ammReserveEth = newReserveIn;
            ammReserveBold = newReserveOut;
            // Send the BOLD output to the caller.
            IERC20(BOLD_TOKEN_ADDRESS).transfer(msg.sender, amountOut);
        } else {
            ammReserveBold = newReserveIn;
            ammReserveEth = newReserveOut;
            // Send the ETH output to the caller.
            (bool sent,) = msg.sender.call{value: amountOut}("");
            if (!sent) revert EthTransferFailed();
        }

        emit AmmSwapExecuted(
            msg.sender, fromResource, toResource,
            amountIn, amountOut,
            newReserveIn, newReserveOut
        );

        return amountOut;
    }
    ```

  * **Mathematical soundness double-check.**

    1. **`amountOut < reserveOut`** (no drain to zero).
       By the constant-product formula:
       `amountOut = numerator / denominator
                  = (amountInWithFee × reserveOut)
                    / (reserveIn × 10000 + amountInWithFee)`.
       Since `amountInWithFee > 0` and both reserves > 0,
       `denominator > amountInWithFee`, so
       `amountOut < reserveOut`.  Strict inequality;
       reserveOut never reaches zero.  ✓

       Explicit verification: `amountOut < reserveOut`
       ⟺ `numerator < denominator × reserveOut`
       ⟺ `amountInWithFee × reserveOut <
           (reserveIn × 10000 + amountInWithFee) × reserveOut`
       ⟺ `amountInWithFee < reserveIn × 10000 + amountInWithFee`
       ⟺ `0 < reserveIn × 10000`.
       Holds whenever `reserveIn > 0`, which we checked above.  ✓

    2. **k monotonically non-decreasing** (constant-product
       invariant).
       Before swap: `k_old = reserveIn × reserveOut`.
       After swap: `k_new = newReserveIn × newReserveOut
                          = (reserveIn + amountIn) ×
                            (reserveOut - amountOut)`.
       Expanding:
       `k_new = reserveIn × reserveOut
              − reserveIn × amountOut
              + amountIn × reserveOut
              − amountIn × amountOut`
            `= k_old + amountIn × reserveOut
              − reserveIn × amountOut
              − amountIn × amountOut`.

       We want `k_new ≥ k_old`, i.e.,
       `amountIn × reserveOut ≥
        reserveIn × amountOut + amountIn × amountOut`
       ⟺ `amountIn × reserveOut ≥
          (reserveIn + amountIn) × amountOut`.

       Substituting `amountOut = amountInWithFee × reserveOut /
       (reserveIn × 10000 + amountInWithFee)`:
       `amountIn × reserveOut ≥
        (reserveIn + amountIn) ×
        amountInWithFee × reserveOut /
        (reserveIn × 10000 + amountInWithFee)`
       ⟺ `amountIn × (reserveIn × 10000 + amountInWithFee) ≥
          (reserveIn + amountIn) × amountInWithFee`
       ⟺ `amountIn × reserveIn × 10000 +
          amountIn × amountInWithFee ≥
          reserveIn × amountInWithFee +
          amountIn × amountInWithFee`
       ⟺ `amountIn × reserveIn × 10000 ≥
          reserveIn × amountInWithFee`
       ⟺ `amountIn × 10000 ≥ amountInWithFee`
       ⟺ `amountIn × 10000 ≥
          amountIn × (10000 − AMM_SWAP_FEE_BPS)`
       ⟺ `amountIn × AMM_SWAP_FEE_BPS ≥ 0`.

       True for `AMM_SWAP_FEE_BPS ≥ 0` and `amountIn ≥ 0`.  ✓
       Strict inequality when `AMM_SWAP_FEE_BPS > 0` AND
       `amountIn > 0`; both hold per our constants and the
       `if (amountIn == 0) revert` guard.

    3. **Slippage protection.**  `amountOut < minAmountOut`
       reverts.  Caller can set `minAmountOut = 0` to disable
       (e.g., for an arbitrage bot that has computed the exact
       output), but UI/wallet should never do this in normal
       flow.

    4. **Deadline protection.**  `block.timestamp > deadline`
       reverts.  Standard Uniswap pattern.  Caller should set
       deadline = block.timestamp + ~5 minutes.

    5. **Reentrancy.**  `nonReentrant` modifier prevents
       reentrancy via the ETH `call` or the BOLD `transfer`.
       Both external calls happen after the state updates
       (CEI pattern: Checks, Effects, Interactions).  Safe.

    6. **Front-running / sandwich.**  Standard AMM exposure;
       mitigated by `minAmountOut`.  Users wanting stronger
       protection should route through MEV-protected RPCs
       (Flashbots Protect, Cowswap intent system) or use the
       commit-reveal extension (future work, not in v1.3).

    7. **First-swap edge case.**  If `reserveIn == 0` or
       `reserveOut == 0`, the function reverts with `AmmEmpty`.
       The reserves are seeded by deposits (GP.11.2), so a
       deployment must accumulate at least one ETH-side and
       one BOLD-side deposit before swaps work.  Operator
       should pre-seed via initial deposits.

  * **Events.**

    ```solidity
    event AmmSwapExecuted(
        address indexed swapper,
        uint64 indexed fromResource,
        uint64 indexed toResource,
        uint256 amountIn,
        uint256 amountOut,
        uint256 newReserveIn,
        uint256 newReserveOut
    );

    error SwapDeadlineExpired();
    error ZeroSwapInput();
    error EthAmountMismatch();
    error UnexpectedEth();
    error UnsupportedSwapResource(uint64 resource);
    error AmmEmpty();
    error SlippageExceeded(uint256 actualOut, uint256 minOut);
    error ReserveExhausted();
    error EthTransferFailed();
    error AmmSeedRatioExceedsMax(uint16 ratio);
    error AutoCircuitTriggerDisabled();
    error RedemptionRateBelowThreshold(uint256 rate);
    ```

  * **Tests.**  60+ cases:
    * **Math invariants:**  k-monotonicity verified for 1000+
      randomized swaps; reserve-non-zero invariant verified
      across the boundary.
    * **Slippage protection:** `amountOut < minAmountOut`
      reverts.
    * **Deadline:** `block.timestamp > deadline` reverts.
    * **Direction:** ETH→BOLD and BOLD→ETH both work
      symmetrically.
    * **First-swap edge case:** revert with `AmmEmpty` before
      seeding.
    * **Calibration parity:** post-swap reserve ratio matches
      pre-swap ratio modulo fee accumulation (verified
      algebraically per the k-monotonicity proof above).
    * **Reentrancy:** malicious BOLD mock attempting reentry
      reverts.
    * **Fee accumulation:** repeated swaps grow k by the
      expected amount.
    * **Sandwich attack:** simulated front-run + user swap +
      back-run; user's `minAmountOut` correctly stops the
      attack (user reverts; only the sandwich bot loses gas).

  * **Acceptance criteria.**  Two reviewers; full mathematical
    proof of the k-monotonicity invariant included in the
    auditor's review.
  * **Dependencies.**  GP.11.1, GP.11.2.
  * **Estimated effort.**  ~24 hours including the
    invariant-test harness.
  * **Status: COMPLETE (Solidity side).**  `KnomosisBridge.sol` ships the
    permissionless `ammSwap(fromResource, amountIn, minAmountOut, deadline)
    payable nonReentrant returns (uint256 amountOut)` entry point, backed by
    a new pure swap-math library `solidity/src/lib/AmmMath.sol`
    (`getAmountOut` / `getAmountIn`, fee-parameterised, self-validating,
    `internal` ⇒ inlined, checked arithmetic).  Both directions work
    symmetrically: ETH→BOLD takes `msg.value` and sends BOLD via
    `safeTransfer`; BOLD→ETH pulls via `safeTransferFrom` with a
    `balanceOf`-delta check (fee-on-transfer defence, reusing
    `BoldTransferAmountMismatch`) and sends ETH via a low-level `call`.  The
    0.30% `AMM_SWAP_FEE_BPS` is retained in the reserves, so
    `k = ammReserveEth × ammReserveBold` is monotonically non-decreasing
    (strictly increasing per non-trivial swap).  Event `AmmSwapExecuted` +
    eleven swap errors (`SwapDeadlineExpired`, `ZeroSwapInput`,
    `ZeroSwapOutput`, `EthAmountMismatch`, `UnexpectedEth`,
    `UnsupportedSwapResource`, `AmmEmpty`, `SlippageExceeded`,
    `ReserveExhausted`, `EthTransferFailed`, `AmmKInvariantViolated`).
  * **Design decisions vs. the v1.5 sketch above** (recorded so a reviewer
    can diff intent against implementation):
    1. **Accounting (Option C).**  `ammSwap` deliberately does NOT touch
       `totalLockedValue` / `boldTotalLockedValue` (the sketch is silent;
       this makes it explicit).  The AMM is a self-contained,
       value-conserving sub-pool whose total value is preserved (and grows
       by the fee) on every swap, while a raw-unit `reserves ≤ TVL` bound
       mixes incommensurable ETH-wei and BOLD-wei and is NOT a swap
       invariant.  Solvency rides instead on the REAL-TOKEN-BACKING
       invariants `ammReserveEth ≤ address(this).balance` and
       `ammReserveBold ≤ BOLD.balanceOf(this)`: each reserve moves in EXACT
       lockstep with the matching real balance (input reserve and balance
       both `+= amountIn`; output reserve and balance both `-= amountOut`),
       so a swap touches only AMM reserves, never any L2 user's backing, and
       updating TVL (the rejected alternative) would let a cross-currency
       swap brick deposits at the cap or behave wildly with the ETH/BOLD
       exchange rate.  Pinned by `test_swap_doesNotTouchTvl` +
       `invariant_tvlUntouchedBySwaps` + the real-backing invariants.
    2. **Kill switch + depeg breaker (IMPLEMENTED in the v1.24 completion;
       the original v1.23 swap deferred these to GP.11.10).**  The GP.11.10
       `ammActive` kill switch is pulled forward: a one-way
       `emergencyDisableAmm()` gated by a new immutable `ammDisasterRecovery`
       role sets `ammDisabled`, after which the `ammActive` modifier reverts
       `AmmIsDisabled` on `ammSwap` and `_seedAmmReserves` stops accruing
       reserves (the reserves are PRESERVED — a graceful shutdown).  The role
       is REQUIRED non-zero for a FUNCTIONAL AMM (BOLD-enabled, ratio > 0) —
       `AmmDisasterRecoveryRequired` otherwise, mirroring the GP.5.5 rule that
       an enabled feature ships its safety roles — and validated `!=
       address(this)` (`AmmRoleIsBridge`).  ADDITIONALLY, `ammSwap` reverts
       `AmmPausedByBoldCircuit` while the GP.5.5 BOLD circuit breaker is closed
       (a depeg freeze, both directions), so the AMM does not offer a stale
       price during a depeg while L2 withdrawals stay open.  (The GP.11.10
       `onlyDisasterRecovery` MULTISIG hardening + the operator runbook remain
       GP.11.10; the mechanism itself is now live.)
    3. **`ZeroSwapOutput` guard added.**  A dust input whose output floors
       to zero is rejected (Uniswap v2's positive-output rule), so a swap
       can never donate its input for nothing.  Does not break the
       `minAmountOut == 0` arbitrage escape hatch (non-dust swaps still pass).
    4. **Checked add + on-chain k-check.**  `newReserveIn = reserveIn +
       amountIn` is CHECKED (the sketch's `unchecked` is a premature
       optimisation; reserves are TVL-bounded so overflow is unreachable
       but a hypothetical one reverts).  A belt-and-braces
       `newReserveIn * newReserveOut < reserveIn * reserveOut` assertion
       (`AmmKInvariantViolated`) + the proven `amountOut < reserveOut`
       bound (`ReserveExhausted`) make a swap-math regression fail closed
       rather than drain the pool.  `safeTransfer`/`safeTransferFrom`
       replace the sketch's raw `transfer`/`transferFrom`+bool;
       `EthAmountMismatch` carries `(expected, actual)` for diagnostics; a
       `!boldEnabled ⇒ AmmEmpty` early-out gives a clean revert on a
       BOLD-disabled deployment (whose BOLD reserve is permanently zero)
       before any token call.
  * **Tests (54 new cases over a shared `test/utils/AmmTestBase.sol`, all
    green; `MockBold.transfer` made `virtual` for the reentrancy mock):**
    * `AmmMath.t.sol` (20) — exact hand-computed vectors, the fee-reduces-
      output / monotone-in-input / strictly-below-`reserveOut` structural
      guarantees, the full revert surface, the `getAmountIn` round-trip,
      and the headline k-monotonicity fuzz (`(reserveIn+amountIn) ×
      (reserveOut-amountOut) ≥ reserveIn × reserveOut`).
    * `AmmSwap.t.sol` (20) — both directions with full reserve / real-balance
      accounting + the canonical event + return value, the TVL-untouched
      design pin, real-token-backing, fee-accumulation (k grows), the
      full revert surface (`AmmEmpty` before / one-leg / BOLD-disabled,
      `ZeroSwapInput`, `UnsupportedSwapResource`, `EthAmountMismatch`,
      `UnexpectedEth`, `ZeroSwapOutput`), a tightened warm-swap gas pin, and
      two stateless single-swap fuzz tests (added in the v1.24 completion
      round; see below).
    * `AmmReentrancy.t.sol` (3) — a malicious ETH recipient re-entering a
      WOULD-SUCCEED swap is rejected by `nonReentrant` with NO double-spend
      (exactly one swap's accounting applied), a malicious BOLD token in the
      output path fails safe (`ReentrancyGuardReentrantCall` bubbles via
      `safeTransfer`, reserves unchanged), and an honest contract caller
      still settles.
    * `AmmInvariants.t.sol` (5) — the stateful k-never-decreases +
      reserves-stay-positive + real-token-backing + TVL-untouched harness
      over 128 000 random ETH↔BOLD swaps (0 reverts).
    * `AmmSlippage.t.sol` (9) — `minAmountOut` and `deadline` exact
      boundaries (the strict `<` / `>`), the zero-min disable, unrealistic
      bounds, and the deadline-before-slippage ordering.
    * `AmmSandwich.t.sol` (4) — a front-run degrades the user's execution, a
      full front-run+back-run sandwich profits without protection, and
      `minAmountOut` deterministically STOPS the attack (user reverts).
  * **Gates.**  `forge build` warning-free (the deadline `block.timestamp`
    comparison carries an explicit `forge-lint: disable-next-line` with a
    rationale); full `forge test` green; the GP.5.2 cap-audit gate +
    self-test (45 cases) unchanged — no constitutional cap is added (the
    swap reuses `AMM_SWAP_FEE_BPS`; `AmmMath`'s `BPS_DENOMINATOR` lives
    outside the audited `KnomosisBridge.sol`).  Solidity-only; the L2
    `Action.ammSwap` mirror + cross-stack corpus are GP.11.4 / GP.11.7.
  * **Completion round (v1.24 — kill switch + breaker + machine-checked
    k-monotonicity + audit-gap closures).**  A code-first deep audit drove
    GP.11.3 to its optimal form:
    * **Machine-checked k-monotonicity.**  `LegalKernel/Bridge/AmmMath.lean`
      (Lean-core only) mirrors the Solidity `getAmountOut` over `Nat` and
      proves `getAmountOut_lt_reserveOut` (no-drain) + `k_nondecreasing`
      (the constant product never decreases).  Both `#print axioms`-clean
      (`{propext, Classical.choice, Quot.sound}` only), zero sorries; the
      `bridge-amm-math` suite (6 cases) pins the SAME hand-vectors as
      `AmmMath.t.sol`, so Lean-spec == Solidity-formula == ground truth.
      The swap's headline safety property is now a theorem, not just an
      assertion + tests (matching GP.5.1 / GP.11.2's proof-carrying pattern).
    * **Kill switch + depeg breaker** (design decision 2, above): the
      `emergencyDisableAmm` one-way pause + the required `ammDisasterRecovery`
      role + the `boldCircuitClosed` swap freeze.  Pinned by the new
      `AmmKillSwitch.t.sol` suite (the GP.11.10 theorems
      `emergencyDisableAmm_preserves_reserves` / `ammDisabled_implies_swap_reverts`
      / `ammDisabled_is_monotonic` as tests, the role access control, the
      `AmmRoleIsBridge` + `AmmDisasterRecoveryRequired` constructor guards, the
      breaker gating, and the brake independence/precedence).
    * **Reachable-branch closures.**  `EthTransferFailed` (a contract
      recipient that rejects the ETH output → fail-safe rollback), calibration
      parity, EXACT fee-accrual `k` delta, a deposit↔swap composition test, a
      warm-swap gas pin, and +4 slippage/deadline boundary cases (the
      dedicated suite is now 13 ≥ the plan's 12+).
    * **Lean→Solidity pricing cross-stack corpus** (distinct from the
      GP.11.4 / GP.11.7 L2-mutation corpus — this one closes the
      "the two implementations of the same `getAmountOut` formula agree"
      gap).  The Lean generator `LegalKernel/Test/Bridge/CrossCheck/AmmMath.lean`
      (`crosscheck-amm-getamountout`, 4 cases) computes
      `LegalKernel.Bridge.AmmMath.getAmountOut` over a 204-entry corpus
      (a 192-entry amount×reserve×reserve×fee grid + 12 boundary corners),
      PROOF-CARRIES every entry against `getAmountOut_lt_reserveOut` +
      `k_nondecreasing`, and emits `amm_getamountout.json`; the Solidity
      consumer `solidity/test/CrossCheck/AmmMath.t.sol` (5 cases) recomputes
      `src/lib/AmmMath.sol::getAmountOut` over the SAME inputs and byte-matches
      every entry (plus no-drain / k-monotonicity re-checks + a hand-vector
      anchor).  Hash-independent, so it runs in every binding mode.
    * **Stateless swap fuzz.**  `AmmSwap.t.sol` gains two single-swap fuzz
      tests (both directions, 256 runs each, dust→whale input range) pinning
      output==reference + reserve accounting + k-monotonicity + real-token
      backing per random input — complementing the stateful `AmmInvariants`
      sequences (suite now 20).  The warm-swap gas pin was tightened from a
      placeholder 200k to 30k (~16.5k actual; trips on an accidental cold
      SSTORE), and the shared AMM disaster-recovery test role is a named
      `AMM_DR` constant per suite rather than a repeated `0xA33D6` literal.
    * **Coverage made runnable + confirmed full-suite.**  `forge coverage`
      was infeasible (the via_ir contracts defeat its instrumentation); the
      test `Deployer` is stack-fit (params threaded through one `DeployParams`
      memory struct, external signature unchanged), so `forge coverage
      --ir-minimum` now runs end-to-end.  A full-suite run reports
      `src/lib/AmmMath.sol` at 100% line/statement/branch/function and
      `KnomosisBridge.sol`'s AMM functions at 100% function coverage — and
      `make coverage` documents the `--ir-minimum` requirement.  The two
      provably-unreachable defensive branches (`ReserveExhausted`,
      `AmmKInvariantViolated`) are by design uncovered.
    * `forge test` 744 → 772 passed / 0 failed / 12 keccak-gated skips;
      `lake build` (warning-free) + `lake test` + `count_sorries` (0) +
      `naming_audit` + `tcb_audit` + `stub_audit` green; codemaps regenerated
      (CI-idempotent).
  * **PR #116 review hardening.**  Two fixes a code review surfaced, both
    verified against the contract before acting:
    * **BOLD-disabled deployments seed nothing.**  The constructor permits a
      `ammSeedRatioBps > 0` deployment with BOLD disabled (the
      `AmmDisasterRecoveryRequired` guard is nested under `boldEnabled`), and
      `_seedAmmReserves` previously diverted part of every ETH fee into
      `ammReserveEth` — a reserve `ammSwap` can never drain (it reverts
      `AmmEmpty` with no BOLD leg), permanently locking that ETH.
      `_seedAmmReserves` now returns 0 when `!boldEnabled`, so every ETH fee
      stays sequencer-claimable free pool.  Pinned by the new
      `AmmStorage.t.sol::test_boldDisabled_seedsNothing_despitePositiveRatio`;
      the ETH-seeding suites (`AmmStorage` / `AmmDepositSeeding` / the
      `DepositFeeSplit` ETH cross-check) now deploy BOLD-enabled bridges, since
      seeding only accrues on a functional AMM.
    * **`ammSwap` freezes on migration.**  The swap ran under only
      `nonReentrant + ammActive` + the BOLD-breaker freeze, NOT `circuitOpen`,
      so a migrated (retired) bridge's AMM stayed live.  `ammSwap` now reverts
      `MigrationActivated` once `migration.activated()` — the migration arm of
      `circuitOpen` applied to the AMM; the transient attestation-stale /
      dispute-cooldown arms are deliberately NOT applied (the AMM stays up as an
      optional liquidity service during recoverable states).  Pinned by
      `AmmKillSwitch.t.sol::test_swap_freezesAfterMigration`.
    * A third comment (gate the AMM until the GP.11.4 L2 mirror lands) was
      investigated and found to overstate user-fund risk: a swap preserves
      combined real-token solvency (`balance ≥ user-escrow + ammReserve` is
      invariant) and never touches `totalLockedValue` / user escrow, so pending
      withdrawals stay fully backed; the residual is gas-pool accounting
      completeness (GP.11.4) and every shipped deployment defaults to
      `ammSeedRatioBps = 0` (AMM inert), so no code change was made.
    * `forge test` 772 → 774 passed / 0 failed / 12 keccak-gated skips;
      `forge build` warning-free; cap-audit unchanged (Solidity-only; no Lean /
      Rust source touched).

#### WU GP.11.4: L2-side AMM mirroring

  * **Goal.**  Mirror AMM swaps onto L2 state so the gas pool's
    L2 view reflects the AMM's L1 reserve mix accurately.
  * **Files:**
    * `LegalKernel/Authority/Action.lean` (new constructor
      `ammSwap` at index 22).
    * `LegalKernel/Laws/AmmSwap.lean` (new law).
    * `LegalKernel/Bridge/AmmReserves.lean` (new module
      tracking the L2 reflection of AMM state).
  * **Deliverables.**

    ```lean
    namespace LegalKernel.Laws

    /-- AMM swap law: reflect an L1 swap event onto L2 by
        adjusting the AMM-reserve actor's balances.

        The L1 user sends `amountIn` of `fromResource` to the
        bridge; the bridge sends `amountOut` of `toResource`
        back to the user.  On L2, the corresponding mutation is
        at the `ammReserveActor` slot:

          * `ammReserveActor`'s (fromResource) balance += amountIn
          * `ammReserveActor`'s (toResource) balance −= amountOut

        Signed by `bridgeActor` in response to the L1
        `AmmSwapExecuted` event.

        Conservation: NOT globally conserved.  Supply at
        `fromResource` increases by amountIn (the user added
        funds to the pool); supply at `toResource` decreases by
        amountOut (the pool sent funds to the user).  In a
        per-resource sense, the kernel proof obligations are:
          * `amm_swap_increases_from`:
            getBalance s' fromResource ammReserveActor =
              getBalance s fromResource ammReserveActor + amountIn.
          * `amm_swap_decreases_to`:
            getBalance s' toResource ammReserveActor =
              getBalance s toResource ammReserveActor − amountOut.
          * `amm_swap_locality`: no other actor's balance changes.
          * `amm_swap_freezePreserving`: any resource outside
            {fromResource, toResource} is freeze-preserved.

        The kernel does NOT prove `k = R_eth × R_bold` is
        non-decreasing; that invariant lives on the L1 side
        (GP.11.3) and is enforced operationally by the L1
        contract's deterministic math.  The L2 ingestor trusts
        the L1 contract's k-monotonicity claim because the
        cross-stack fixture corpus (GP.11.7) verifies byte-
        equivalence of the L2 mutations against the L1 events.
    -/
    def ammSwap (fromResource toResource : ResourceId)
        (amountIn amountOut : Amount)
        (ammReserveActor : ActorId) : Transition where
      pre := fun s =>
        getBalance s toResource ammReserveActor ≥ amountOut ∧
        fromResource ≠ toResource ∧
        amountIn > 0
      decPre := fun _ => inferInstance
      apply_impl := fun s =>
        let s1 := setBalance s fromResource ammReserveActor
                    (getBalance s fromResource ammReserveActor + amountIn)
        setBalance s1 toResource ammReserveActor
          (getBalance s1 toResource ammReserveActor - amountOut)

    end LegalKernel.Laws
    ```

  * **Theorems** (mathematical soundness):

    1. `ammSwap_increases_from_balance`: after `step_impl s
       ammSwap...`, `ammReserveActor`'s `fromResource` balance
       increases by exactly `amountIn`.
    2. `ammSwap_decreases_to_balance`: after, `ammReserveActor`'s
       `toResource` balance decreases by exactly `amountOut`.
    3. `ammSwap_other_actor_untouched`: no other actor's
       balance changes.
    4. `ammSwap_other_resource_untouched`: at any resource
       outside `{fromResource, toResource}`, the balance map is
       untouched.
    5. `ammSwap_localTo [fromResource, toResource]` instance.
    6. `ammSwap_freezePreserving S` for `S ∩ {fromResource,
       toResource} = ∅`.
    7. `ammSwap_not_conservative`: explicit witness that the
       law is not `IsConservative` at `fromResource` or
       `toResource` (when amounts are positive).
    8. `ammSwap_not_monotonic`: explicit witness that the law
       is not `IsMonotonic` at `toResource` (supply decreases
       by amountOut).

  * **Author's soundness verification:**
    * Both `setBalance` operations preserve `LocalTo` because
      `fromResource ≠ toResource` is a precondition.  No
      collision between the two slots.
    * The `getBalance ≥ amountOut` precondition ensures the
      `Nat` subtraction in `step 2` is truncation-safe.
    * Conservation is NOT a property of this law; the global
      "supply preserved" theorem set must exclude `ammSwap`
      from any `ConservativeLawSet`.  Deployments that admit
      `ammSwap` cannot claim global supply conservation —
      they get the weaker "per-resource supply changes are
      bounded by the AMM's deterministic math" guarantee.

  * **Tests.**  35 cases including all eight theorems
    above plus boundary cases (`amountIn = 1`,
    `amountOut = reserveOut - 1`, `amountIn` at uint64 max).

  * **Acceptance criteria.**  Two reviewers (touches kernel-
    adjacent law with novel non-conservation classification);
    `lake exe count_sorries` green.
  * **Dependencies.**  GP.2.3 (Action layer integration —
    extended to handle index 22).
  * **Estimated effort.**  ~16 hours.

#### WU GP.11.5: `ammReserveActor` reservation

  * **Goal.**  Reserve `ActorId 3` for `ammReserveActor`.  This
    is the L2-side counterpart to the L1 `ammReserveEth` and
    `ammReserveBold` storage slots.
  * **Files:** `LegalKernel/Bridge/BridgeActor.lean` (constants).
  * **Deliverables.**

    ```lean
    /-- The reserved actor id of the AMM-reserve actor
        (Workstream GP v1.3).  Holds the L2 reflection of the
        L1 bridge's AMM liquidity at both `ResourceId 0` (ETH)
        and `ResourceId 1` (BOLD).  Outflow is gated by
        `bridgeActor`-signed `ammSwap` actions (admission
        layer); no other action can mutate this actor's
        balances. -/
    def ammReserveActor : ActorId := 3
    ```

    `AddressBook.empty.nextActorId` becomes `4`, replacing the
    current `3` (set in GP.7.1).

  * **Theorems:**
    * `ammReserveActor_ne_bridgeActor`
    * `ammReserveActor_ne_gasPoolActor`
    * `ammReserveActor_ne_sequencerActor`
    * `addressBook_empty_nextActorId_v1_3`: equals 4

  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.7.1.
  * **Estimated effort.**  ~2 hours.

#### WU GP.11.6: `ammReserveActor` local policy

  * **Goal.**  Constrain `ammReserveActor`'s outflow via a
    `LocalPolicy` declaration: it can only be mutated by
    `ammSwap` actions (signed by `bridgeActor`).
  * **File:** `LegalKernel/Bridge/AmmReservePolicy.lean` (new).
  * **Deliverables.**

    ```lean
    /-- The canonical `LocalPolicy` for the AMM-reserve actor.

        The simplest possible policy: `denyTags` on every Action
        tag EXCEPT `ammSwap` (= 22).  This means an `ammSwap`
        signed by `bridgeActor` and targeting `ammReserveActor`
        passes; everything else is rejected.

        No `requireRecipientIn` or `capAmount` clauses because
        the L1 contract's `ammSwap` math (GP.11.3) already
        provides the recipient (caller is implicit) and the
        amount (deterministic from reserves + caller's input)
        bound.  The kernel-side policy is the simplest
        "only-this-action" filter.

        Combined with `bridgePolicy` (which only allows
        `bridgeActor` to sign actions in a deployment-approved
        registry), this means `ammSwap` actions reach
        `ammReserveActor` only when (a) the L1 contract emits
        an `AmmSwapExecuted` event AND (b) the Rust ingestor
        signs the corresponding `Action.ammSwap` with the
        `bridgeActor` key AND (c) the kernel-level
        `ammReserveActor` policy permits the action tag. -/
    def ammReservePolicy : LocalPolicy :=
      { clauses :=
          [ .denyTags (List.range 23 |>.filter (· ≠ 22)) ] }
    ```

  * **Soundness check (author):**
    * `List.range 23` produces `[0, 1, 2, ..., 22]`.  Filtering
      out `22` produces `[0, 1, 2, ..., 21]` — every Action
      tag except `ammSwap`.
    * A `bridgeActor`-signed `ammSwap` action with `signer =
      ammReserveActor` (i.e., the policy is checked against
      the actor whose balance is being mutated): wait, this
      isn't quite right.  Let me re-check the LocalPolicy
      mechanism.

      Looking at `Authority/LocalPolicy.lean:122-141`, the
      policy is keyed by SIGNER, not by the actor whose
      balance is mutated.  So if the action is signed by
      `bridgeActor` (not `ammReserveActor`), the policy
      checked is `bridgeActor`'s policy, not
      `ammReserveActor`'s.

      For our case: `ammSwap` is signed by `bridgeActor` (as
      a result of L1 event).  The mutation target is
      `ammReserveActor`.  So `bridgeActor`'s policy is the
      one checked at admission — not `ammReserveActor`'s.

      Therefore, `ammReservePolicy` declared on
      `ammReserveActor` doesn't directly gate this action.
      The actual gating happens via `bridgePolicy`
      (`Bridge/BridgeActor.lean:139-143`) which restricts
      `bridgeActor` to signing only registered bridge-actor
      actions.  We need to add `ammSwap` to the
      `bridgePolicy`'s allowed-tags list.

      `ammReservePolicy` then serves a DIFFERENT purpose: if
      `ammReserveActor`'s key is somehow compromised (worst
      case), the policy prevents the compromised key from
      signing any non-`ammSwap` action.  But since
      `ammReserveActor` doesn't have an externally-controllable
      key (it's a virtual actor representing AMM reserves, with
      no associated keypair), this is a belt-and-braces defence
      that's structurally unreachable.

      **Conclusion:** the policy declared on `ammReserveActor`
      is theoretically defensive but practically inactive.
      Keep it for symmetry with `gasPoolPolicy`; the real
      gating happens in `bridgePolicy`.

  * **Tests.**  5 cases.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.11.5.
  * **Estimated effort.**  ~3 hours.

#### WU GP.11.7: Cross-stack AMM fixture corpus

  * **Goal.**  Extend the cross-stack fixture corpus to cover
    the AMM swap path byte-equivalently between Solidity, Rust,
    and Lean.
  * **Files:**
    * `runtime/tests/cross-stack/amm_swap.cxsf` (new).
    * `LegalKernel/Test/Bridge/CrossCheck/AmmSwap.lean`
      (new Lean fixture generator).
    * `solidity/test/CrossCheck/AmmSwapFixtures.t.sol`
      (new Solidity consumer).
  * **Deliverables.**
    * 60+ fixture entries covering:
      - Starting reserves: small (1 ETH / 3000 BOLD), medium
        (100 ETH / 300000 BOLD), large (1000 ETH / 3M BOLD).
      - Swap directions: ETH→BOLD and BOLD→ETH.
      - Swap sizes: 1 % of reserve, 10 % of reserve, 50 % of
        reserve (extreme).
      - Slippage thresholds: minOut at expected output,
        minOut at expected output × 0.99 (small slack), minOut
        at expected output × 0.5 (always passes).
      - Each entry includes the L1-side
        `(fromResource, amountIn, R_in, R_out)` inputs and the
        expected `(amountOut, new_R_in, new_R_out)` outputs,
        plus the expected CBE-encoded `Action.ammSwap` bytes,
        plus the expected `ammReserveActor` L2 balance
        deltas.

  * **Mathematical soundness verification (across the corpus):**
    * For every entry: `(R_in + amountIn) × (R_out - amountOut)
      ≥ R_in × R_out` (k-monotonicity).
    * For every entry: `amountOut < R_out` (no drain to zero).
    * For every entry: `amountOut × denominator =
      numerator` (formula compliance modulo floor division).
    * For paired entries (ETH→BOLD followed by BOLD→ETH at
      same reserves): k grows by the expected double-fee
      amount.

  * **Tests.**  60+ cases via the cross-stack harness.
  * **Acceptance criteria.**  One reviewer; Solidity, Rust, and
    Lean all produce identical results.
  * **Dependencies.**  GP.11.3, GP.11.4, GP.6.5.
  * **Estimated effort.**  ~14 hours.

#### WU GP.11.8: AMM state-root commitment integration (v1.4)

  * **Goal.**  Ensure the AMM's L1 state (`ammReserveEth`,
    `ammReserveBold`, `boldCircuitClosed`, `boldTvlCap`,
    `boldTotalLockedValue`) is committed to the bridge's
    state-root so the fault-proof game can adjudicate disputes
    that turn on AMM state.
  * **Files:**
    * `solidity/src/contracts/KnomosisBridge.sol` (extend the
      state-root preimage).
    * `LegalKernel/FaultProof/Commit.lean` (extend the L2-side
      commitment derivation if applicable).
    * `LegalKernel/Bridge/State.lean` (extend `BridgeState` if
      the AMM state needs L2-side reflection in the commit).
  * **Background.**  The bridge's state-root (per Workstream H,
    `KnomosisStateRootSubmission`) commits to a Merkle-ised
    representation of the bridge's state.  v1.0 covered the
    deposit / withdrawal state; v1.2 added the BOLD-specific
    state; v1.3 added the AMM reserves but did NOT specify how
    they're committed.  Without commitment, a sequencer could
    submit a state-root that's inconsistent with the actual L1
    AMM reserves, and the fault-proof game would have no way
    to challenge it.
  * **Deliverables.**

    Extend the state-root preimage to include:

    ```
    h_state_root = keccak256(abi.encode(
      // Pre-v1.3 fields (existing):
      bridgeStateMerkleRoot,
      ...,
      // v1.3 additions:
      ammReserveEth,
      ammReserveBold,
      boldCircuitClosed,
      boldTvlCap,
      boldTotalLockedValue
    ));
    ```

    The Solidity `submitStateRoot` function continues to take
    a single root hash, but the operator's off-chain
    computation now MUST include the AMM state in the preimage.

  * **Mathematical-soundness analysis.**
    * **Coverage:** every state variable mutated by AMM-
      related operations (deposits, swaps, circuit-breaker
      events) is now committed.  No mutation path bypasses the
      commitment.
    * **Cross-stack consistency:** the Lean-side
      `BridgeState.encode` already covers the v1.2 fields;
      v1.4 extends to cover the v1.3 AMM additions
      symmetrically.  Round-trip + injectivity proofs extend
      naturally (mirroring the EI.6 / EI.7 patterns for the
      consumed / pending maps).
    * **Fault-proof game integration:** the bisection game's
      step-VM equivalence theorem (`recomputeCommitment_
      coherent_with_kernelOnlyApply`) extends to the new
      Action.ammSwap variant via the GP.11.4 / GP.3.3 work.
      State-root commitment closes the loop.

  * **Theorems.**
    * `bridgeState_commit_includes_ammState` (new): the
      state-root preimage covers `ammReserveEth`,
      `ammReserveBold`, `boldCircuitClosed`, `boldTvlCap`,
      `boldTotalLockedValue`.  Proof: trivial — direct
      computation.
    * `bridgeState_commit_extends_v1_2`: every pre-v1.4
      state-root remains valid under the v1.4 preimage
      formula when the v1.3 fields are at their genesis
      values (0 for reserves, false for circuit-closed, etc.).
      Backwards-compatible migration.

  * **Tests.**  15 cases:
    * Genesis state-root matches expected (all v1.3 fields zero).
    * Post-deposit state-root matches expected.
    * Post-swap state-root matches expected.
    * Post-circuit-close state-root matches expected.
    * Cross-stack: Solidity state-root == Lean reference
      state-root over the 50+ cross-stack fixture corpus.

  * **Acceptance criteria.**  Two reviewers (touches fault-
    proof commit machinery, which is critical for L1 safety);
    `lake test` passes; forge tests pass.
  * **Dependencies.**  GP.11.1, GP.11.2, GP.11.3, GP.11.4.
  * **Estimated effort.**  ~12 hours.

#### WU GP.11.9: Gas-cost benchmarks for v1.3 operations (v1.4)

  * **Goal.**  Establish baseline gas costs for the new v1.3
    L1 operations so deployments can budget L1-gas costs and so
    audit-pass review can spot performance regressions.
  * **Files:**
    * `solidity/test/BenchmarkGasV1_3.t.sol` (new).
    * `docs/gas_pool_runbook.md` (operator runbook section on
      gas economics).
  * **Deliverables.**

    Forge gas-snapshot benchmarks for:

    * `depositETHWithFee` (typical: ~80-120k gas).
    * `depositBoldWithFee` (typical: ~140-180k gas, higher due
      to `transferFrom` + `balanceOf` delta check).
    * `ammSwap` ETH→BOLD (typical: ~110-140k gas).
    * `ammSwap` BOLD→ETH (typical: ~140-170k gas).
    * `closeBoldCircuit` (typical: ~30-40k gas).
    * `closeBoldCircuitIfAnyLiquityBranchShutdown` (typical:
      ~50-70k gas on the fast-path close, includes the
      Liquity V2 external read on the first detected branch;
      up to ~100k for the no-shutdown 3-branch read path).

    Each baseline number committed to the runbook with a
    rationale ("at 30 gwei base fee, a typical deposit costs
    ~$8 in L1 gas; users absorb this in their bridging UX").

    Forge `forge snapshot --diff` invoked in CI on every PR
    touching `solidity/` to detect regressions (>5 %
    increase fails CI).

  * **Acceptance criteria.**  One reviewer; baseline numbers
    documented; CI gate added.
  * **Dependencies.**  GP.5.1, GP.5.4, GP.5.5, GP.11.3.
  * **Estimated effort.**  ~8 hours.

#### WU GP.11.10: AMM disaster recovery (v1.4)

  * **Goal.**  Specify the operator's recovery path if the AMM
    state becomes pathologically imbalanced (one reserve
    asymptotically approaches zero), reserves are stuck below
    a viable trading depth, or the L1 contract is otherwise
    operationally degraded.
  * **Files:**
    * `solidity/src/contracts/KnomosisBridge.sol` (new admin
      function with strict access control).
    * `docs/gas_pool_runbook.md` (disaster recovery section).
  * **Background.**  The constant-product AMM cannot be
    drained to zero by swap activity (proven in GP.11.3).  But
    pathological scenarios exist:
    * If `R_eth` becomes very small (e.g., 0.001 ETH) due to
      ETH price doubling without arbitrage rebalancing, the
      ETH leg has effectively zero depth — even tiny swaps
      cause huge slippage.  Functionally stuck, even though
      mathematically the curve has not "drained".
    * A bug in the swap math (despite our audit) could leave
      the reserves in an inconsistent state.
    * Liquity V2 could become unreachable (e.g., the contract
      becomes unrebootable for some reason), making BOLD-leg
      operations fail.

    These scenarios need an explicit recovery mechanism.

  * **Deliverables.**

    ```solidity
    /// @notice Operator-triggered emergency: pause all AMM
    /// operations and unlock the pre-existing reserves as
    /// "free" gas-pool reserves that the sequencer can claim
    /// via the existing gasPoolPolicy mechanism.  After this
    /// call, ammSwap reverts with AmmDisabled; the reserves
    /// are no longer participating in the constant-product
    /// curve.  The reserves themselves are not moved
    /// physically; they're simply re-tagged for accounting
    /// purposes.
    ///
    /// This is a "graceful shutdown" of the AMM, not a value
    /// drain.  No funds are lost.  The bridge can continue
    /// operating without the AMM (degrading to the v1.2
    /// "external L1 DEX" mode for swaps).
    ///
    /// One-way: ammDisabled cannot be unset.  Reactivating the
    /// AMM requires a new bridge deployment via KnomosisMigration.
    /// This is deliberately stricter than the BOLD circuit
    /// breaker — disasters are rare and rolling them back is
    /// itself a complex operation.
    bool public ammDisabled;

    function emergencyDisableAmm() external onlyDisasterRecovery {
        ammDisabled = true;
        emit AmmDisabled(
            block.timestamp,
            ammReserveEth,
            ammReserveBold
        );
        // Reserves remain in their current state; the
        // sequencer can claim from the gas pool's reserves
        // (which now include the previously-locked AMM amounts)
        // via the existing gasPoolPolicy mechanism on L2.
    }

    modifier ammActive() {
        if (ammDisabled) revert AmmDisabled();
        _;
    }
    ```

    The `ammActive` modifier is applied to `ammSwap` (and any
    future AMM-modifying functions).

    The `onlyDisasterRecovery` modifier is a NEW access-control
    role, distinct from `onlyCircuitBreaker` and `onlyAdmin`.
    Should be a 3-of-N multisig with operator + community
    representatives + auditor signatures.  Specified in the
    deployment configuration.

    On the L2 side: a corresponding `Action.disableAmm` action
    (NEW frozen index 23 if we choose to wire this) emitted by
    the bridge when `AmmDisabled` is observed.  The L2
    handling: mark the `ammReserveActor`'s balances as
    transferable to the `gasPoolActor` via a new
    `LocalPolicyClause.allowAmmFundsClaimBy [sequencerActor]`
    — operator-triggered post-emergency.

    Decision: for v1.4 simplicity, the L2 side does NOT have
    a corresponding `Action.disableAmm`.  The L1 state is
    committed to the state-root, so the L2 ingestor knows the
    AMM is disabled.  Claims against the AMM reserves on L1
    are simply gated by the `ammDisabled` flag.  No new
    Action variant needed.

  * **Mathematical-soundness analysis.**
    * **Reserves are preserved:** `emergencyDisableAmm` only
      sets a flag.  `ammReserveEth` and `ammReserveBold` are
      not zeroed or transferred.  The bridge's L1 escrow
      balance is unchanged; only the AMM's swap operation is
      gated off.
    * **One-way:** by design, `ammDisabled` cannot be unset.
      Forces operator to redeploy via `KnomosisMigration` if they
      want AMM functionality back.  Asymmetric design:
      enabling is heavy (full migration), disabling is light
      (one signed call).  Prevents flip-flopping during a
      crisis.
    * **No fund-drain attack:** the function only sets a bool.
      No transfer happens.  An attacker getting the
      DisasterRecovery key could disable the AMM but cannot
      steal funds via this path.

  * **Theorems.**
    * `emergencyDisableAmm_preserves_reserves`: post-call,
      `ammReserveEth` and `ammReserveBold` are unchanged.
    * `ammDisabled_implies_swap_reverts`: once
      `ammDisabled = true`, every subsequent `ammSwap` call
      reverts with `AmmDisabled`.
    * `ammDisabled_is_monotonic`: once true, never returns to
      false within a single deployment.

  * **Operator runbook section.**  Conditions under which to
    invoke `emergencyDisableAmm`:
    * **Reserve depth pathology**: one leg drops below
      `MIN_VIABLE_DEPTH_USD = $10 000` AND off-bridge
      arbitrage isn't restoring depth within 24 hours.
    * **Math bug suspected**: any reproducible discrepancy
      between Lean fixture reference and Solidity execution
      output.
    * **Liquity V2 unreachable**: persistent
      `LiquityV2ReadFailed` errors AND operator-side
      monitoring confirms Liquity V2 contract failure (not
      just our integration bug).
    * **Audit-flagged severity-critical issue**: independent
      auditor reports a critical vulnerability in the AMM
      swap math, and the fix requires a redeploy.

    Recovery procedure post-disable:
    1. Run a post-mortem (1-7 days).
    2. Decide whether to redeploy with corrections.
    3. If yes: prepare new `KnomosisBridge` deployment via
       `KnomosisMigration`; new contract's initial AMM seeded
       from the (now-unlocked) reserves of the old contract.
    4. If no (AMM remains permanently disabled): operate in
       degraded mode using external L1 DEXes for ETH↔BOLD
       conversion (the v1.2 path).  All other v1.3 mechanisms
       remain functional.

  * **Tests.**  20 cases:
    * `emergencyDisableAmm` from `onlyDisasterRecovery` works.
    * `emergencyDisableAmm` from other roles reverts.
    * Post-disable `ammSwap` reverts.
    * Post-disable deposit + withdraw still work.
    * Re-enabling not possible (`emergencyDisableAmm` is one-way).
    * `ammDisabled` is reflected in state-root preimage.
    * Disaster-recovery multisig: 3-of-N requirement enforced.

  * **Acceptance criteria.**  Two reviewers (touches L1 access
    control + introduces a new role); `forge test` green;
    operator runbook section reviewed by deployment operators.
  * **Dependencies.**  GP.11.3, GP.11.8.
  * **Estimated effort.**  ~12 hours.

---

## Theorem catalogue

The full set of theorems Workstream GP discharges, consolidated for
easy review:

### Kernel-data theorems (GP.1)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `ActorBudget.empty_lastSeenEpoch_zero`             | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.normalise_idempotent`                | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.normalise_lastSeenEpoch_eq_max`      | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.normalise_floors_at_freeTier`        | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.normalise_noop_if_current`           | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.consume_some_preserves_epoch`        | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.consume_some_decreases_balance_by_cost` | `Authority/ActorBudget.lean`       | new    |
| `ActorBudget.consume_none_iff_insufficient`       | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.consume_zero_is_normalise`           | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.consume_monotone_in_cost`            | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.topUp_preserves_epoch`               | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.topUp_increases_balance_by_amount`   | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.topUp_then_consume_roundtrip`        | `Authority/ActorBudget.lean`          | new    |
| `EpochBudgetState.consume_other_actor_unchanged`  | `Authority/ActorBudget.lean`          | new    |
| `EpochBudgetState.topUp_other_actor_unchanged`    | `Authority/ActorBudget.lean`          | new    |
| `EpochBudgetState.currentBudget_after_consume`    | `Authority/ActorBudget.lean`          | new    |
| `EpochBudgetState.currentBudget_after_topUp`      | `Authority/ActorBudget.lean`          | new    |
| `ActorBudget.encode_injective`                    | `Encoding/ActorBudget.lean`           | new    |
| `EpochBudgetState.encodeMap_injective`            | `Encoding/ActorBudget.lean`           | new    |

### Law theorems (GP.2)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `totalSupply_after_depositWithFee`                | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_other_resource_untouched`         | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_recipient_credited`               | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_pool_credited`                    | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_self_credit_collapses`            | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_other_actor_untouched`            | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_isMonotonic`                      | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_localTo`                          | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_freezePreserving`                 | `Laws/DepositWithFee.lean`            | new    |
| `depositWithFee_not_conservative`                 | `Laws/DepositWithFee.lean`            | new    |
| `totalSupply_after_topUpActionBudget`             | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_other_resource_untouched`      | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_signer_debited`                | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_pool_credited`                 | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_self_topup_is_noop`            | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_other_actor_untouched`         | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_isConservative`                | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_isMonotonic`                   | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_localTo`                       | `Laws/TopUpActionBudget.lean`         | new    |
| `topUpActionBudget_freezePreserving`              | `Laws/TopUpActionBudget.lean`         | new    |
| `Action.tag_depositWithFee_eq_19`                  | `Authority/Action.lean`               | new    |
| `Action.tag_topUpActionBudget_eq_20`              | `Authority/Action.lean`               | new    |
| `Action.compile_injective` (extended)             | `Authority/Action.lean`               | upd.   |

### Admission theorems (GP.3)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `admission_consumes_budget_on_success`            | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `admission_rejected_when_budget_zero`             | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `topUpActionBudget_net_budget_change`             | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `depositWithFee_grants_budget`                    | `Authority/SignedAction.lean`         | **done** (GP.3.2 v1.1) |
| `depositWithFee_budget_locality`                  | `Authority/SignedAction.lean`         | **done** (GP.3.2 v1.1) |
| `bridgeActor_budget_exempt`                       | `Authority/SignedAction.lean`         | **done** (GP.3.2 v1.1) |
| `admission_legacy_compat`                         | n/a                                   | dropped — no `.unlimited` variant (post-GP.3.1 wiring closure: every deployment runs `.bounded`) |
| `admission_locality_in_budget`                    | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `replenishment_via_epoch_advance`                 | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `nonce_uniqueness_preserved`                      | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `replay_impossible_preserved`                     | `Authority/SignedAction.lean`         | **done** (GP.3.2) |
| `Action.toTransition`                             | `Authority/Action.lean`               | **done** (GP.2.3, supporting helper) |
| `Action.toTransition_eq_compileTransition_of_ne_topUp` | `Authority/Action.lean`          | **done** (GP.2.3, supporting helper) |
| `Action.toTransition_topUpActionBudget`           | `Authority/Action.lean`               | **done** (GP.2.3, supporting helper) |
| `apply_admissible_base` (extended for GP.2.3 signer-aware match) | `Authority/SignedAction.lean` | upd. (GP.2.3) |
| `apply_admissible_base_topUpActionBudget`         | `Authority/SignedAction.lean`         | **done** (GP.2.3) |
| `stepVMHash_depositWithFee_kind`                  | `FaultProof/StepVMCoherence.lean`     | new (GP.3.3) |
| `stepVMHash_topUpActionBudget_kind`               | `FaultProof/StepVMCoherence.lean`     | new (GP.3.3) |

### Bridge accounting theorems (GP.4)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `DepositRecord.encode_injective`                  | `Encoding/Bridge.lean`                | **done** (GP.4.1) |
| `BridgeState.encodeConsumed_injective`            | `Encoding/BridgeInjective.lean`       | **done** (GP.4.1) |
| `DepositRecord.userAmountAt_add_poolAmountAt`     | `Bridge/Accounting.lean`              | **done** (GP.4.2) |
| `totalUserDeposited_plus_pool_eq_totalDeposited`  | `Bridge/Accounting.lean`              | **done** (GP.4.2; split identity) |
| `totalUserDeposited_step_eq`                      | `Bridge/Accounting.lean`              | **done** (GP.4.2) |
| `totalPoolDeposited_step_eq`                      | `Bridge/Accounting.lean`              | **done** (GP.4.2) |
| `totalUserDeposited_step_eq_deposit` / `totalPoolDeposited_step_eq_deposit` | `Bridge/Accounting.lean` | **done** (GP.4.2; legacy) |
| `accounting_userpool_delta_non_bridge`            | `Bridge/Accounting.lean`              | **done** (GP.4.2) |
| `accounting_userpool_delta_withdraw`              | `Bridge/Accounting.lean`              | **done** (GP.4.2; per-action coverage) |
| `bridge_accounting_equation_balanced`             | `Bridge/Accounting.lean`              | **done** (GP.4.2) |
| `depositWithFee_credits_poolActor`                | `Bridge/Accounting.lean`              | **done** (GP.4.2) |
| `depositWithFee_pool_credit_matches_ledger_delta` | `Bridge/Accounting.lean`              | **done** (GP.4.2; solvency inflow) |
| `pool_balance_eq_totalPoolDeposited_minus_payouts` | `Bridge/Accounting.lean`             | **done** (GP.4.2) |
| `totalUserDeposited_admissible_depositWithFee` / `totalPoolDeposited_admissible_depositWithFee` | `Bridge/Accounting.lean` | **done** (GP.4.2 audit; atomic step) |
| `depositWithFee_admissible_credits_poolActor`     | `Bridge/Accounting.lean`              | **done** (GP.4.2 audit; atomic step) |
| `depositWithFee_admissible_pool_credit_matches_ledger` | `Bridge/Accounting.lean`         | **done** (GP.4.2 audit; atomic coherence) |
| `bridge_accounting_equation_balanced_iff`         | `Bridge/Accounting.lean`              | **done** (GP.4.2 closure; iff w/ totalWithdrawn) |
| `pool_solvency_preserved_by_admitted_depositWithFee` | `Bridge/Accounting.lean`           | **done** (GP.4.2 closure; inductive step) |
| `apply_bridge_admissible_with_budget_base_bridge_eq` | `Bridge/Admissible.lean`           | **done** (GP.4.2 closure; runtime-entry agreement) |
| `depositWithFee_budget_admitted_pool_credit_matches_ledger` | `Bridge/Accounting.lean`    | **done** (GP.4.2 closure; runtime-entry coherence) |

### Pool governance theorems (GP.7)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `gasPoolActor_ne_bridgeActor`                     | `Bridge/BridgeActor.lean`             | new    |
| `sequencerActor_ne_bridgeActor`                   | `Bridge/BridgeActor.lean`             | new    |
| `sequencerActor_ne_gasPoolActor`                  | `Bridge/BridgeActor.lean`             | new    |
| `addressBook_empty_nextActorId`                   | `Bridge/AddressBook.lean`             | upd.   |
| `gasPoolPolicy_denies_all_non_transfer`           | `Bridge/GasPoolPolicy.lean`           | new    |
| `gasPoolPolicy_requires_sequencer_recipient`      | `Bridge/GasPoolPolicy.lean`           | new    |
| `gasPoolPolicy_caps_per_action`                   | `Bridge/GasPoolPolicy.lean`           | new    |
| `pool_drain_bounded_by_action_count`              | `Bridge/PoolDrainBound.lean`          | new    |
| `pool_balance_lower_bound_via_trace`              | `Bridge/PoolDrainBound.lean`          | new    |

### AMM theorems (GP.11, v1.3)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `ammSwap_increases_from_balance`                  | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_decreases_to_balance`                    | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_other_actor_untouched`                   | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_other_resource_untouched`                | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_localTo`                                 | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_freezePreserving`                        | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_not_conservative`                        | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammSwap_not_monotonic`                           | `Laws/AmmSwap.lean`                   | new (v1.3) |
| `ammReserveActor_ne_bridgeActor`                  | `Bridge/BridgeActor.lean`             | new (v1.3) |
| `ammReserveActor_ne_gasPoolActor`                 | `Bridge/BridgeActor.lean`             | new (v1.3) |
| `ammReserveActor_ne_sequencerActor`               | `Bridge/BridgeActor.lean`             | new (v1.3) |
| `addressBook_empty_nextActorId_v1_3`              | `Bridge/AddressBook.lean`             | upd. (v1.3) |
| `Action.tag_ammSwap_eq_22`                        | `Authority/Action.lean`               | new (v1.3) |
| `Action.tag_topUpActionBudgetFor_eq_21`           | `Authority/Action.lean`               | new (v1.3) |
| `delegatedTopUp_grants_budget_to_recipient`       | `Authority/SignedAction.lean`         | new (v1.3) |
| `delegatedTopUp_requires_allowTopUpFrom`          | `Authority/SignedAction.lean`         | new (v1.3) |
| `delegatedTopUp_signer_balance_debited`           | `Authority/SignedAction.lean`         | new (v1.3) |

**Total new theorems: ~81** (+3 v1.0→v1.1 for the bridge-
deposit budget-grant trio; +6 v1.1→v1.2 for the multi-resource
extension; +17 v1.2→v1.3 for the embedded AMM and delegated-
topup mechanisms).  All in non-TCB files; none touches
`Kernel.lean` or `RBMapLemmas.lean`.  All proofs depend only on
`propext`, `Classical.choice`, `Quot.sound` (the canonical three).

**Note on `ammSwap` non-conservation.**  The `ammSwap` law is the
first law in the system that is neither `IsConservative` nor
`IsMonotonic` at every resource.  Deployments that admit
`ammSwap` cannot inhabit a `ConservativeLawSet` for the
`ResourceId 0` or `ResourceId 1` slots; the kernel's strict
"per-law-conservation" theorems still apply to all other resources.
This is a deliberate consequence of having an AMM: cross-resource
trades fundamentally cannot be conservative *within* a single
resource (you're trading one resource for another).  The kernel's
type system catches this — attempting to construct a
`ConservativeLawSet` containing `ammSwap` fails because no
`IsConservative` instance exists.

---

## Cross-stack equivalence requirements

The cross-stack fixture corpus is extended in three places:

| Corpus                                                     | New entries     | What it pins                                        |
| ---------------------------------------------------------- | --------------- | --------------------------------------------------- |
| `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf` (new) | 50              | L1 `DepositWithFeeInitiated` → L2 `Action.depositWithFee` byte-equivalence |
| `solidity/test/CrossCheck/fixtures/step_vm_new_variants.json` (new) | 30 | Solidity `executeStep(19/20, …)` ↔ Lean `kernelOnlyApply` byte-equivalence |
| `runtime/knomosis-host/tests/budget_admission.rs` (new)       | 30              | Rust admission gate ↔ Lean admission gate verdict equivalence |

The Lean fixture generators live alongside the existing SVC.5
generators in `LegalKernel/Test/Bridge/CrossCheck/` and follow the
same `Encodable` discipline.

---

## Migration plan

A legacy Knomosis deployment (pre-GP) becomes a GP-enabled deployment via:

1. **Stop the sequencer cleanly** (drain in-flight signed actions).
2. **Take a final snapshot** under the legacy `BudgetPolicy.unlimited`
   semantics.
3. **Deploy the new `KnomosisBridge` contract** on L1 with chosen
   `(minFeeBps, maxFeeBps, weiPerBudgetUnitEth,
   weiPerBudgetUnitBold, boldTokenAddress)`.  Recommended
   starting values:
   * `minFeeBps = 0` (allow zero-fee deposits for users who
     don't want a budget grant; they rely on `freeTier`).
   * `maxFeeBps = 1000` (allow up to 10 % fee for super-users
     who want a large budget grant).  Higher caps invite UX
     footguns; the compile-time `MAX_FEE_BPS_CAP = 5000` is
     the absolute ceiling.
   * `weiPerBudgetUnitEth = 10¹²` (1 budget unit costs ~10⁻⁶
     ETH ≈ $0.003 at $3000/ETH; 1 ETH of fee buys ~10⁶
     actions — adjust based on actual L1-gas cost per
     state-root publication).
   * `weiPerBudgetUnitBold = 3 × 10¹⁵` (calibrated for USD
     parity with the ETH leg at ETH = $3000 / BOLD = $1).
     Operators expecting BOLD ≠ $1 (depeg period) should
     adjust accordingly; or accept the calibration drift and
     widen `maxFeeBps` so users can compensate.
   * `boldTokenAddress = 0x6440f144b7e50d6a8439336510312d2f54beb01d`
     (the canonical Liquity V2 BOLD address; constructor
     verifies it matches `BOLD_TOKEN_ADDRESS` compile-time
     constant AND that `symbol()` returns `"BOLD"`).
   Note that the L1 contract is **immutable**; bumping any
   of these parameters later requires a new deployment and the
   `KnomosisMigration` handoff.
4. **Bootstrap the new sequencer** with `--budget-policy bounded
   --free-tier <N> --epoch-duration-seconds <D>` starting from the
   snapshot.  No per-resource sequencer config is needed; the
   bounded-policy is denomination-agnostic.
5. **Pre-declare** `gasPoolPolicy maxDrainPerActionEth
   maxDrainPerActionBold` for `gasPoolActor` on first boot.  An
   attempt to claim from either pool slot without this policy
   in place will fail at admission (policy defaults to "no
   constraint" without the explicit declaration, so omitting
   this step would defeat the design; the runbook names this
   as a critical step).  Calibrate the two caps so the
   per-action drain bound is USD-equivalent across the two
   legs.
5a. **Set `boldTvlCap`.** Via `setBoldTvlCap(uint256)` —
    operator picks a starting BOLD reserve ceiling.  Should be
    less than or equal to the global `tvlCap` (constructor
    check enforces this); typically 30-70% of `tvlCap`
    depending on expected BOLD vs ETH user mix.
6. **Begin accepting traffic.**  Existing actor IDs ≥ 3 remain
   unchanged; IDs 0/1/2 are bridge/gasPool/sequencer respectively.
   Any pre-existing actor with ID 1 or 2 must be remapped via a
   one-time genesis-state migration action (operator-supplied
   `actorIdRemap` migration helper, included as a CLI subcommand
   in knomosis).

The migration path supports a "shadow run" — running a GP-enabled
sequencer alongside the legacy sequencer for a period, comparing
verdicts.  This is recommended for any production deployment.

---

## Audit-pass discipline

Each phase concludes with the following audit checks:

| Audit                               | When                  | Blocks merge? |
| ----------------------------------- | --------------------- | ------------- |
| `lake exe count_sorries`            | Every PR              | Yes           |
| `lake exe tcb_audit`                | Every PR              | Yes           |
| `lake exe stub_audit`               | Every PR              | Yes           |
| `lake exe naming_audit`             | Every PR              | Yes           |
| `lake exe deferral_audit`           | Every PR              | Yes           |
| `lake exe lex_lint`                 | Every PR              | Yes           |
| `lake exe lex_codegen --check`      | Every PR              | Yes           |
| `cargo clippy -- -D warnings`       | runtime/** PRs        | Yes           |
| `cargo fmt -- --check`              | runtime/** PRs        | Yes           |
| `forge test`                        | solidity/** PRs       | Yes           |
| Manual TCB review                   | GP.3.2 (only)         | Yes — two-reviewer rule applies because `SignedAction.lean` houses `nonce_uniqueness` |
| Pool-policy security review         | GP.7.x landing        | Yes           |
| Attack-tree review (Appendix B)     | GP.10.5               | Yes           |

---

## Open questions

### OQ-GP-1 — Variable per-action cost

Should every action cost exactly 1 unit, or should expensive variants
(`distributeOthers`, `proportionalDilute`) cost more?

**v1 resolution:** every action costs 1.  Reasoning: variable cost
adds complexity to the admission proof for marginal benefit.  Most
deployments will rate-limit `distributeOthers` at the deployer-key
level (those laws are deployer-signed, so they bypass the user-budget
gate entirely — actors signing them are infrastructure, not users).
v2 may revisit.

### OQ-GP-2 — Free-tier funding source

Should the free tier (e.g., 100 free actions/epoch for every new
actor) drain the pool, or be sequencer-absorbed?

**v1 resolution:** sequencer-absorbed.  The pool funds L1 publishing
only.  Free-tier is sequencer policy.  This keeps the pool's
economic invariant clean (no death spiral from free-tier abuse).

### OQ-GP-3 — Wire-format extension for new rejection reason

Should the knomosis-host wire format add a new top-level verdict for
`InsufficientBudget` (verdict = 4), or fold under the existing
`NotAdmissible` (verdict = 1) with a reason string?

**v1 resolution:** fold under `NotAdmissible` with reason string
`"InsufficientBudget"`.  Preserves wire-format stability; the
reason field already exists.

### OQ-GP-4 — Epoch alignment to L1 block number vs sequencer clock

Should `currentEpoch` track L1 block number / `EPOCH_DURATION` or
sequencer wall-clock / `EPOCH_DURATION`?

**v1 resolution:** **L1 block number / `EPOCH_DURATION`**.  Reasoning:
sequencer wall-clock is non-deterministic across replays; L1 block
number is deterministic and observable on the bridge's `L1Source`
trait.  This is also what the existing fault-proof game uses for its
`currentBlock` field.  The trade-off: epoch transitions happen at L1
block granularity (~12 s under post-merge Ethereum), which is
acceptable.

**GP.6.2 update (implemented — L2-action-clock realisation).**  The
epoch-advancement *mechanism* now ships, deterministically and with
the proven GP.3.2 gate + its 10 theorems UNTOUCHED.  Rather than
recording an L1 block per log entry (a wire/on-disk-format change),
the runtime advances the budget epoch as a pure function of the
*log index*: `BudgetPolicy.advanceEpoch` increments the effective
epoch by one each time the log index crosses a positive multiple of
the deployment's `epochLength` (`Authority/Nonce.lean`).  The runtime
applies it via `ExtendedState.withAdvancedEpoch` immediately before
the gate in `processSignedActionWith` / `processPure` /
`replayStepWith` (`Runtime/Loop.lean`, `Runtime/Replay.lean`),
threading `epochLength` through `RuntimeState` + the replay entries
(default `0` ⇒ no advancement, byte-identical to the pre-GP.6.2
runtime).  Because the epoch is a deterministic function of the log
index (and the snapshot path resumes at the ABSOLUTE `baseIdx`),
`process` and `replay` compute identical epochs ⇒ identical
per-entry post-state hashes (deterministic replay, pinned by
`epochAdvanceReplenishesAndReplays`).  Operators enable it via
`--epoch-length N` on the `knomosis` binary / `knomosis-host` CLI /
`CommandKernel`.  This is the L2's own action-clock, not the L1
block clock — a future refinement recording the L1 block per entry
could swap the clock source without changing the gate; the
action-clock is the deterministic, format-stable realisation chosen
here.  The budget config (incl. `epochLength`) is persisted to a
`<log>.budgetcfg` sidecar and cross-checked on every restart
(`LegalKernel.Runtime.BudgetSidecar`), so a forgotten/changed flag
fails with a clear error rather than an opaque hash mismatch.

### OQ-GP-5 — Recipient-of-skim immutability

Should the skim's recipient (`gasPoolActor` = `ActorId 1`) be
configurable per-deployment, or hard-coded?

**v1 resolution:** **hard-coded.**  Different deployments can have
different `gasPoolPolicy` and `sequencerActor`, but the *identity*
of the pool actor is canonical.  Configurable would invite
mis-deployments where the skim flows to an attacker-controlled
address.

### OQ-GP-6 — Epoch budget for the bridge actor

Does `bridgeActor` itself need a budget?  It signs `depositWithFee`,
`registerIdentity`, etc.

**v1 resolution:** **`bridgeActor` is exempted via a special-case in
admission** (the bounded policy treats `bridgeActor` as `unlimited`
regardless).  Rationale: bridgeActor actions are L1-gated already
(see §2.1); double-gating adds no security.  The exemption is
mechanically enforced in admission and documented in §15E.

### OQ-GP-7 — Multi-signer top-up

Can a third party top up another actor's budget?  E.g., a service
provider pre-funds its users' budgets.

**v1.0 resolution:** **no** (the `topUpActionBudget` action
increments the signer's own budget).  v2 may add a
`topUpActionBudgetFor` variant.

**v1.1 update:** the `depositWithFee` action (NEW v1.1) is
effectively a third-party top-up: the L1 caller pays the fee, the
budget is granted to a (potentially different) L2 `recipient`.
This is the *only* third-party top-up path in v1.1.

**v1.3 resolution: pre-authorised delegation.**  A new
`LocalPolicyClause` variant `allowTopUpFrom : List ActorId`
lets an actor whitelist specific delegate actors permitted to
credit their budget.  A new action variant
`Action.topUpActionBudgetFor(recipient, gasResource, gasAmount,
budgetIncrement, poolActor)` at frozen index 21 implements the
delegated top-up: the signer must be in the recipient's
`allowTopUpFrom` whitelist (verified at admission), and the
signer's own balance is debited for the gas-resource payment.

Implementation outline (full spec in new WU GP.3.4):
* New clause: `LocalPolicyClause.allowTopUpFrom : List ActorId`
  (extended in `Authority/LocalPolicy.lean`).
* New action variant at index 21:
  ```lean
  | topUpActionBudgetFor
      (recipient : ActorId) (gasResource : ResourceId)
      (gasAmount : Amount) (budgetIncrement : Nat)
      (poolActor : ActorId)
  ```
* The law at the kernel level: a balance transfer from signer to
  `poolActor`, identical in shape to `topUpActionBudget` but
  with the addition that the budget mutation at the admission
  layer targets `recipient`'s slot, not signer's.
* Admission-layer check: before applying the budget increment,
  verify `signer ∈ recipient.localPolicy.allowTopUpFrom`.
  Reject (NotAdmissible + reason
  "TopUpDelegationNotAuthorized") otherwise.

**Soundness analysis** (author):
* The delegated top-up requires the recipient to first declare
  the `allowTopUpFrom` clause via `declareLocalPolicy` (existing
  Action index 15).  Without prior declaration, the policy
  defaults to "no delegation", and the action fails admission.
  This satisfies "must the recipient consent" — consent is the
  prior signed `declareLocalPolicy` action.
* The signer cannot bypass the consent check by signing the
  topUpActionBudgetFor before the recipient has declared the
  policy.  Admission reads the current `LocalPolicy` state at
  apply time.
* The signer pays for the gas-resource debit, so a malicious
  delegate cannot drain the recipient's balance — only their own.
* The recipient could revoke delegation at any time via
  `revokeLocalPolicy` (index 16); the revocation takes effect
  from the next admitted SignedAction.

### OQ-GP-8 — Dynamic fee recommendation (v1.1)

Should the L1 contract expose a view function that recommends a
`chosenFeeBps` based on current pool balance and recent drain
rate?

**v1.1 resolution:** **out of scope for the L1 contract**; this
is a *UI / wallet* concern.  The L1 contract's job is to
deterministically split deposits and emit events; computing
recommended fees from off-chain pool-balance observation is a UX
feature that belongs in the wallet, indexer, or block explorer.
A `view function` would also tie the L1 contract to L2 state
(via cross-chain reads), which complicates the L1 immutability
discipline.

### OQ-GP-9 — `weiPerBudgetUnit` mutability (v1.1)

Should `weiPerBudgetUnit` be governance-mutable (e.g., via a DAO
vote) rather than constructor-immutable?

**v1.1 resolution:** **constructor-immutable**, consistent with
the Workstream-E discipline ("immutable after construction").
Adjusting the exchange rate is done by deploying a new
`KnomosisBridge` and migrating via `KnomosisMigration` (existing
Workstream-E.5 mechanism).  This is a heavier process than a DAO
vote but provides stronger guarantees: pool participants know
their previously-granted budgets cannot be devalued retroactively
by a governance action.  The `MIN_GRACE_WINDOW_BLOCKS` (per
Workstream H) gives users time to exit before the new rate
becomes effective.

### OQ-GP-10 — Refund-on-exit interaction with v1.1 (v1.1)

How does the v1.1 "user-chosen fee with budget grant" interact
with the deferred GP.9.1 refund-on-exit mechanism?

**v1.1 resolution (SUPERSEDED — kept for amendment history):**
refund-on-exit operates over `poolAmount` (the fee paid), not over
`budgetGrant` (the budget received).  A withdrawing user reclaims a
pro-rata portion of their `poolAmount` based on dwell time,
regardless of whether they spent the budget grant or not.  This was
chosen as the simpler design; tying refund to "unused budget
remaining" was thought to require tracking per-deposit budget
consumption (a `(depositId, remainingBudget)` linked-list per actor),
which would be significant state-bloat.

**Current resolution (refund the remaining action budget):** the
state-bloat objection above was mistaken.  The GP.1 budget ledger
(`EpochBudgetState`) tracks remaining budget **per actor as a single
counter** (`currentBudget`), NOT per deposit — there is no
linked-list and no per-deposit tracking.  Refund-on-exit therefore
operates over the claimant's **remaining, purchased action budget**:
the claimant retires `budgetUnits ≤ refundableBudget` units and is
paid `budgetUnits × weiPerBudgetUnit` gas out of `gasPoolActor`,
where `refundableBudget = currentBudget − (actionCost + freeTier)`
excludes the free-tier subsidy and the refund's own per-action cost.
This is exact (not a time-decay approximation) and strictly simpler:
a user who consumed the service has a smaller `currentBudget` and so
a smaller refund automatically.  The `budgetGrant` / `poolAmount`
relationship is reused only to bound the round trip — refunding the
budget a deposit granted pays back at most the fee
(`(poolAmount / rate) × rate ≤ poolAmount`, floor division), so a
deposit→refund cycle is never profitable.  Free-tier immunity (the
subsidy is never refundable), no double refund (the budget is
consumed atomically), and victim-balance safety (the refund is a
dedicated `Action.claimBudgetRefund` whose `poolActor` is pinned to
`gasPoolActor`, never a generic `transfer`) round out the soundness
argument.  See WU GP.9.1 for the full mechanism and the landed
Lean-side core (`Laws.claimBudgetRefund`, `Bridge.BudgetRefund`).

### OQ-GP-11 — Resource enumeration policy (v1.2)

How should v1.2's hard-coded "ResourceId 0 = ETH, ResourceId 1 =
BOLD" reservation interact with future resources (additional
stablecoins, restaked-ETH derivatives, project-specific tokens)?

**v1.2 resolution:** v1.2 commits exclusively to two resources.
Adding a third gas-pool resource (say USDC at ResourceId 2)
requires a new workstream and a new `KnomosisBridge` deployment via
`KnomosisMigration` handoff.  The compile-time pinning of
`BOLD_TOKEN_ADDRESS` is intentional: each new resource gets its
own constructor immutable, its own `EXPECTED_*_SYMBOL` constant,
and its own audit pass.  This prevents the "loose ERC-20
whitelist" failure mode where a misconfigured operator adds an
attacker-controlled token as a gas-pool resource.

Future flexibility: the `gasPoolPolicy` and per-resource
exchange rates are designed to scale to N resources without
structural changes (the policy adds two clauses per new
resource; the contract adds two immutables per new resource).
The scaling bottleneck is audit cost, not architecture.

### OQ-GP-12 — BOLD calibration drift handling (v1.2)

If ETH/USD moves significantly during the bridge's lifetime
(e.g., ETH appreciates from $3000 to $6000), the constructor-
fixed `weiPerBudgetUnitEth` becomes mis-calibrated relative to
`weiPerBudgetUnitBold`.  How should this be handled?

**v1.2 resolution (superseded):** Accept drift, widen
`maxFeeBps` to compensate; redeploy via `KnomosisMigration` for
structural drift.

**v1.3 resolution: embedded constant-product AMM for internal
ETH↔BOLD price discovery.**  An external L1 DEX path (v1.2's
proposed approach) leaves the bridge dependent on Uniswap v3's
price quotes — which is an unstated trust assumption on a
third-party contract, and exposes sequencer claims and
calibration-drift mitigation to MEV.  The v1.3 solution
incorporates an internal AMM directly into `KnomosisBridge`,
making ETH↔BOLD price discovery a first-class feature of the
bridge and surfacing the trust assumption explicitly as part of
Knomosis's own auditable codebase.

Design (full spec in new Phase GP.11):
* **AMM curve:** constant-product `R_eth × R_bold = k`
  (Uniswap v2 style).  Reasons: predictable, battle-tested,
  appropriate for ETH/BOLD (different asset classes,
  different volatility profiles).
* **Swap fee:** 0.30 % (`AMM_SWAP_FEE_BPS = 30`), compile-time
  constant matching the Uniswap v2 default.  Fee revenue
  accrues to the gas pool by staying in the reserves (the
  standard Uniswap v2 fee mechanism).
* **Swap access:** permissionless.  Anyone can swap any time;
  arbitrageurs maintain the peg between the bridge's internal
  price and external markets; MEV exposure is bounded by user-
  supplied slippage parameters.
* **LP structure:** gas pool itself is the sole LP.  No LP
  tokens, no external LPs.  Impermanent loss and fee revenue
  both accrue to the gas pool's L1 reserves and are reflected
  on L2 via new `Action.ammSwapExecuted` events.
* **MEV protection:** swap function takes `minAmountOut` and
  `deadline` parameters (standard Uniswap pattern).  No
  built-in commit-reveal or private-mempool integration;
  users wanting stronger protection use Cowswap-style intent
  systems off-bridge.

**Calibration-drift resolution:** the AMM provides continuous
price discovery within the bridge.  When ETH/USD moves, the
AMM's ETH/BOLD reserve ratio drifts toward the new market
ratio (driven by arbitrageurs).  The two `weiPerBudgetUnit`
exchange rates remain constructor-immutable, but the *effective*
USD-denominated budget cost adjusts as the AMM rebalances:
* If a user deposits BOLD when BOLD is rich relative to ETH
  (in the AMM), they get a larger budget grant per USD (good
  for users; bad for the pool — but this is precisely when
  the pool's BOLD reserves should be drawn down).
* If a user deposits ETH when ETH is rich, they get a larger
  budget grant per USD as well, but the pool's ETH reserves
  are then deeper.
* Arbitrageurs continuously bring the AMM's price back to
  market via swaps, capturing the spread; their swap fees
  accrue to the pool.

This mechanism replaces the v1.2 "accept drift, redeploy if
needed" posture with a "drift is self-correcting via AMM
dynamics" posture.  Redeploy via `KnomosisMigration` remains
available for tail cases (e.g., a stablecoin failure
permanently breaking BOLD's $1 anchor).

### OQ-GP-13 — BOLD depeg detection signal (v1.2 → v1.3 → v1.6)

The BOLD circuit breaker (GP.5.5) pauses BOLD deposits during
a depeg event.  What signal should trigger the circuit breaker?

> **v1.6 final resolution (what shipped):** Liquity V2's per-branch
> `TroveManager.shutdownTime()` — non-zero on any of the three
> pinned collateral branches (ETH / wstETH / rETH) closes the
> circuit.  This is the canonical on-chain branch-shutdown signal,
> a binary indicator that BOLD's backing on that branch has been
> wound down.  Strictly stronger than the v1.3 redemption-rate
> threshold: not threshold-prone, not subject to market-noise
> false positives, monotonic once set.  The v1.2 and v1.3
> resolutions below are PRESERVED HERE as plan history; the
> active design is documented in the GP.5.5 status block (above)
> and in `docs/gas_pool_runbook.md` §4.

**v1.2 resolution (superseded):** Operator manual decision based
on off-chain oracle (Chainlink, Pyth, in-house feed).  Operator
calls `closeBoldCircuit()` based on their reading of the
oracle.

**v1.3 resolution (superseded by v1.6): Liquity V2 redemption-rate as the canonical
depeg signal.**  Liquity V2's internal redemption mechanism is
the *implicit* price oracle for BOLD: when BOLD trades below
peg, arbitrageurs profit by redeeming BOLD against the lowest-
interest-rate troves (receiving the collateral asset).  High
redemption volume is therefore a direct on-chain measurement of
"BOLD is below peg right now."

Two implementation paths (both ship in v1.3):

**Path A — Operator-watched (default).**  The operator's
monitoring infrastructure subscribes to Liquity V2's redemption
events.  When redemption volume in a rolling window exceeds a
configured threshold (e.g., > 1 % of BOLD supply redeemed in 24
hours), the operator's circuit-breaker key calls
`closeBoldCircuit()`.  Reopens once redemption volume returns
to baseline for a configured period.

**Path B — On-chain auto-trigger (optional, opt-in per deployment).**
A new function `closeBoldCircuitIfRedeemingHeavily()` is
publicly callable by anyone.  It reads Liquity V2's
`BorrowerOperations` contract (or whichever Liquity V2 contract
exposes the redemption-rate accumulator), checks whether the
rate exceeds the threshold, and triggers the circuit close if
so.  This removes the operator's response-time dependency at
the cost of accepting a (limited) cross-contract dependency on
Liquity V2's internal accounting.

Path B is recommended for production deployments that want
auto-defence; Path A remains the fallback when operators want
manual review of edge cases.

**Soundness analysis:**
* Redemption-rate is a *necessary* signal (BOLD below peg ⇒
  arbitrageur incentive to redeem), but it's not *sufficient*
  in either direction.  A high redemption rate can occur for
  benign reasons (large trove unwinds, integration changes);
  a low redemption rate doesn't guarantee peg health if
  arbitrage liquidity is thin.  This is why both paths preserve
  operator override.
* The auto-trigger path adds a cross-contract dependency:
  `KnomosisBridge` reads Liquity V2's state.  This is allowed
  because Liquity V2 is an immutable contract (the redemption
  mechanism cannot be changed by Liquity governance once
  deployed).  However, if Liquity V2 ever ships an upgrade
  contract that supersedes the current implementation, the
  bridge's read becomes stale — operator must migrate to a
  redeployment via `KnomosisMigration` that reads from the new
  Liquity contract.

**Trade-offs vs v1.2's oracle approach:**
* Pro: no external oracle trust; manipulation-resistance
  (Liquity's redemption mechanism is already battle-tested
  against price manipulation).
* Pro: signal is direct and unambiguous (high redemption =
  BOLD below peg by construction of Liquity's mechanism).
* Pro: free to read (one extra L1 storage slot read per check;
  no oracle subscription fees).
* Con: cross-contract dependency on Liquity V2 internals.
* Con: signal is reactive (kicks in after redemptions have
  started), not predictive.  An oracle could in principle
  fire earlier on minor price deviation.  But early triggers
  also generate false positives; the redemption-rate's
  reactivity is arguably a *feature*, not a bug.

### OQ-GP-14 — AMM curve choice (v1.3)

What constant-product variant should the embedded AMM use?

**v1.3 resolution: Uniswap v2-style `x*y=k`.**  Predictable
behaviour, battle-tested (~5 years of production use on
Ethereum mainnet), simple to formalise in Lean, simple to audit
in Solidity.  Stable-swap (Curve) was rejected because it
assumes the two assets trade near 1:1, which ETH/BOLD does not
(ETH and BOLD have different volatility profiles and a 3000:1
price ratio).  Concentrated liquidity (Uniswap v3) was
rejected for being significantly more complex; the capital-
efficiency gain doesn't justify the audit burden for a
bridge-internal AMM.

### OQ-GP-15 — AMM swap fee rate (v1.3)

What swap fee rate should the AMM charge?

**v1.3 resolution: 0.30 % (30 bps), constant.**  Matches
Uniswap v2's default.  Historical empirical evidence: 0.30 %
covers IL for most ETH/stablecoin pairs and produces
meaningful net APR for LPs.  Tighter spreads (e.g., 0.05 %)
appropriate for high-volume stablecoin pairs but inappropriate
for ETH/BOLD's volatility profile.  Wider spreads (e.g.,
1.0 %) push arbitrageurs to external DEXes, defeating the
internal-price-discovery purpose.  Constant rather than
operator-mutable: minimises governance attack surface; the
fee is part of the bridge's economic invariant and shouldn't
be tunable post-deployment.

### OQ-GP-16 — AMM swap access (v1.3)

Who can call the AMM swap function?

**v1.3 resolution: permissionless.**  Anyone can swap any time;
the swap function is `external`, not gated.  Arbitrageurs are
expected to maintain the bridge's internal price against
external markets via continuous swaps.  MEV exposure is bounded
by the user-supplied `minAmountOut` slippage parameter and the
`deadline` parameter.  Restricted access (e.g., only deposit /
withdraw flows trigger swaps) would defeat the purpose by
eliminating arbitrage volume — which is *both* the source of
swap-fee revenue AND the mechanism that keeps the bridge's
internal price aligned with external markets.

### OQ-GP-17 — AMM LP structure (v1.3)

Who provides the AMM's liquidity, and how is liquidity
ownership represented?

**v1.3 resolution: gas pool is the sole LP; no LP tokens, no
external LPs.**  The gas pool's L1 reserves (the fraction
allocated via `ammSeedRatioBps`) ARE the AMM's reserves.
Impermanent loss accrues to the gas pool; swap-fee revenue
also accrues to the gas pool.  Net: the gas pool is the
sole LP economically and structurally.

This choice trades simplicity for capital efficiency: an
external-LP system (Uniswap v2-style LP tokens) would let
non-deployment parties contribute liquidity, growing the AMM's
depth.  But it would also (a) require LP-token accounting on L1,
(b) require LP-token positions to be redeemable for the
underlying assets, (c) introduce LP-vs-pool fee-revenue
allocation policy, and (d) materially expand the audit
surface.  For v1.3, simplicity wins.  Future v2 work
(`Workstream BAv2` or similar) could open external LP
contributions if the deployment grows large enough to need
deeper liquidity than the gas pool itself provides.

**Soundness consequence:** because the gas pool IS the LP, the
operator-set `ammSeedRatioBps` directly controls the trade-off
between "AMM depth" and "free pool reserves for sequencer
claims."  Higher seed ratio = deeper AMM, less free reserves;
lower seed ratio = more free reserves, less AMM depth.  The
operator runbook recommends starting at `ammSeedRatioBps =
3000` (30 %) and observing real-world behaviour before
adjusting via `KnomosisMigration`.

---

## Appendix A — Per-WU dependency graph

```
GP.0.1 (Plan §15E text)
   │
   ├──► GP.0.2 (Cross-refs)
   │
   └──► GP.0.3 (Index reservation)
           │
           ├──► GP.1.1 (ActorBudget types)
           │        │
           │        └──► GP.1.2 (normalise)
           │                 │
           │                 └──► GP.1.3 (consume)
           │                          │
           │                          └──► GP.1.4 (topUp)
           │                                   │
           │                                   └──► GP.1.5 (Map ops)
           │                                            │
           │                                            └──► GP.1.6 (Encoding)
           │                                                     │
           │                                                     ├──► GP.2.1 (depositWithFee)
           │                                                     │        │
           │                                                     │        └──► GP.2.3 (Action layer)
           │                                                     │                 │
           │                                                     │                 ├──► GP.3.3 (StepVM)
           │                                                     │                 │        │
           │                                                     │                 │        └──► GP.5.3 (Solidity StepVM)
           │                                                     │                 │
           │                                                     │                 └──► GP.3.1 (ExtendedState)
           │                                                     │                          │
           │                                                     │                          └──► GP.3.2 (Admission gate)
           │                                                     │                                   │
           │                                                     │                                   └──► GP.6.2 (knomosis-host)
           │                                                     │                                            │
           │                                                     │                                            ├──► GP.6.3 (event-subscribe)
           │                                                     │                                            │        │
           │                                                     │                                            │        └──► GP.6.4 (indexer)
           │                                                     │                                            │
           │                                                     │                                            ├──► GP.8.1 (Sequencer claim)
           │                                                     │                                            │
           │                                                     │                                            └──► GP.8.2 (Free-tier policy)
           │                                                     │
           │                                                     └──► GP.2.2 (topUpActionBudget)
           │                                                              │
           │                                                              └──► (joins GP.2.3 above)
           │
           └──► GP.4.1 (DepositRecord widening)
                    │
                    └──► GP.4.2 (Accounting eq)
                             │
                             └──► GP.5.1 (Solidity fee split)
                                      │
                                      ├──► GP.5.2 (MAX_FEE_BPS audit)
                                      │
                                      └──► GP.6.1 (knomosis-l1-ingest)

GP.7.1 (Reserve gasPoolActor)
   │
   └──► GP.7.2 (gasPoolPolicy)
            │
            └──► GP.7.3 (Drain bound)
                     │
                     └──► GP.7.4 (Genesis ratification)
                              │
                              └──► GP.8.3 (Runbook)

GP.8.1 + GP.8.2 + GP.8.3 ────► GP.10.x (Docs, audits, landing)

GP.10.1 ──► GP.10.2 ──► GP.10.3 ──► GP.10.4 ──► GP.10.5
```

Critical path: GP.0.3 → GP.1.{1..6} → GP.2.{1, 2, 3} → GP.3.1 →
GP.3.2 → GP.6.2.  Approximately 15 sequential WUs.  With ~2-week
review cycles per WU and assuming one reviewer-day of work per WU
on average, the critical path takes ~30 weeks at sequential
single-author pace; parallelizable to ~12 weeks with two
contributors and parallel side branches for the L1 (GP.4 + GP.5)
and pool-governance (GP.7) sub-paths.

---

## Appendix B — Attack tree

The attack tree enumerates concrete adversary actions and the
mitigations Workstream GP introduces.

| # | Adversary action | Pre-GP outcome | Post-GP outcome | Mitigation |
| - | ---------------- | -------------- | --------------- | ---------- |
| 1 | Sybil identities each spam N valid signed actions | Sequencer absorbs full cost; no kernel bound | Each identity consumes its budget; once exhausted, admission rejects pre-`step_impl` | Per-actor budget (GP.3.2) |
| 2 | Single identity spams at maximum admission rate | Limited only by sequencer admission policy | Limited to `freeTier × admission_rate / epochDuration` baseline + `topUp_rate × budgetPerTopUp` + (v1.1) `budgetGrant_per_deposit` | Budget + top-up cost + bridge-deposit grant (GP.3.2) |
| 3 | Attacker buys budget cheaply via tiny top-ups | n/a | Top-up rate is itself bounded by gas-resource balance + `MAX_TOPUP_BUDGET_PER_ACTION` cap | `MAX_TOPUP_BUDGET_PER_ACTION` (Status §5) |
| 3' | Attacker pays maximum bridge fee for huge budget grant (v1.1) | n/a | `MAX_BUDGET_PER_DEPOSIT = 10¹²` clamps the per-deposit grant; further grants require fresh L1 bridge transactions (each L1-gas-gated) | `MAX_BUDGET_PER_DEPOSIT` clamp (GP.5.2) + L1 gas cost per deposit |
| 3'' | Attacker pays high bridge fee in a no-op deposit to grief themselves (v1.1) | n/a | Self-griefing is not a security concern; the user's money goes to the pool, which is sequencer-drainable, so the sequencer profits and the user is hurt — typical UX footgun, not adversarial | UI warning + the `MAX_FEE_BPS_CAP = 5000` ceiling caps the absolute damage |
| 4 | Malicious sequencer drains pool | No kernel constraint | `gasPoolPolicy.capAmount` caps per-action drain; `pool_drain_bounded_by_action_count` provides per-trace bound | GP.7.{2,3} |
| 5 | Malicious sequencer routes pool funds elsewhere | n/a | `gasPoolPolicy.requireRecipientIn 0 [sequencerActor]` rejects any other recipient | GP.7.2 |
| 6 | Malicious sequencer mints into gas pool to inflate claims | n/a | Pool receives funds only from (a) bridge deposits (L1-gated), (b) user top-ups (kernel-conservation-preserving) | GP.4 + GP.7 |
| 7 | L1 deployer sets fee parameters to drain users (v1.1) | n/a | The deployer no longer chooses the per-deposit fee; the *user* does, bounded by deployer-immutable `[minFeeBps, maxFeeBps]` and the compile-time `MAX_FEE_BPS_CAP = 5000` | GP.5.2 |
| 7' | L1 deployer sets `weiPerBudgetUnit = 1` to grant huge budgets cheaply (v1.1) | n/a | `MAX_BUDGET_PER_DEPOSIT = 10¹²` clamps the max grant per deposit; total budget across deposits is bounded by `aggregate_pool_credit / weiPerBudgetUnit`, which the deployer's immutable choice can over-grant but the per-trace drain bound on the pool still applies | Mitigation incomplete: a deployer setting `weiPerBudgetUnit = 1` would offer unrealistically cheap budgets but does not break any kernel invariant — the resulting deployment is just economically uncalibrated.  The runbook (GP.8.3) warns operators.|
| 8 | Replay of `depositWithFee` event after re-org | Pre-GP `deposit` already had this protection | Extended to `depositWithFee` via the existing `BridgeAdmissibleWith.consumed` gate | Unchanged from pre-GP |
| 9 | Front-running / griefing top-ups | n/a | Top-ups are signed; signer's funds and budget; no third-party effect | Standard signature-based action discipline |
| 10 | Reorg during deposit causes double-credit | Pre-GP risk already mitigated by `consumed` gate | Same gate covers `depositWithFee` (same `DepositId` keying); the budget grant is also gated by the same gate, so a re-org-induced double-credit cannot double-grant budget | Unchanged + (v1.1) budget grant inherits the `consumed` discipline |
| 11 | DoS the L1 contract itself via spam deposits | Limited by L1 gas cost | Unchanged; v1.1 adds `msg.value == 0` reject to close the depositNonce-exhaustion variant | L1 gas economics + `ZeroDeposit` revert (GP.5.1) |
| 12 | Manipulate fee parameters via storage attack | n/a | All four fee-related fields (`minFeeBps`, `maxFeeBps`, `weiPerBudgetUnit`, `depositNonce`) — except `depositNonce` which is mutable — are `immutable`; storage attack would require bytecode tampering at deploy | Solidity immutable semantics |
| 13 | Free-tier abuse by registering many identities | n/a | Identity registration is L1-gated (~$5-20 per identity); each identity provides at most `freeTier` actions per epoch; net cost asymmetry remains, but mitigated by free-tier-config + identity-registration cost | Identity registration gate + Workstream SB (future) |
| 14 | User front-runs another user's deposit to force a fee choice (v1.1) | n/a | `chosenFeeBps` is bound to the `msg.sender`'s own transaction; cannot be set by another user.  Cross-transaction fee-choice front-running is structurally impossible | EVM transaction isolation |
| 15 | User chooses `chosenFeeBps = maxFeeBps` on every deposit to inflate their budget | n/a | Not adversarial — the user is paying real ETH for real budget.  Cost-to-attacker is proportional to attack capability.  The `MAX_BUDGET_PER_DEPOSIT` clamp caps the per-deposit damage; the L1 gas per deposit caps the deposit rate | Economic alignment: cost scales with attack capability |
| 16 | Attacker deploys a malicious "BOLD" token at a copycat address to trick a bridge deployment (v1.2) | n/a | Constructor-time check `_boldTokenAddress == BOLD_TOKEN_ADDRESS` (compile-time constant `0x6440f144b7e50d6a8439336510312d2f54beb01d`) reverts on any mismatch.  Defence-in-depth: constructor also calls `BOLD_TOKEN.symbol()` and reverts if not `"BOLD"`.  An attacker would need to either (a) deploy at the canonical address (impossible without front-running the canonical Liquity deployment, which already exists) or (b) compromise the canonical contract itself | Compile-time address pin + symbol cross-check (GP.5.1, GP.5.5) |
| 17 | BOLD depeg causes pool's USD value to drop sharply (v1.2) | n/a | Operator triggers `closeBoldCircuit()` (GP.5.5), halting new BOLD deposits until peg restored.  Existing BOLD reserves remain withdrawable.  The per-BOLD `boldTvlCap` limits the deployment's exposure.  Sequencer claims at the BOLD leg continue to drain via the `gasPoolPolicy.capAmount` bound | Operator circuit breaker + TVL cap (GP.5.5) |
| 18 | Liquity V2 governance attacks BOLD parameters or freezes the contract (v1.2) | n/a | Defence-in-depth via `boldTvlCap` (operator can set this conservatively low — e.g., 30% of global cap); existing pool funds remain L1-withdrawable as long as Liquity's `transfer` works.  If Liquity ever adds a transfer block-list, the bridge's withdrawals would fail loudly; operator triggers `closeBoldCircuit()` immediately and operates ETH-only.  Long-term: a future v3 amendment could add support for migrating from a frozen BOLD to a successor stablecoin | Operator response + TVL cap (GP.5.5); future workstream for stablecoin migration |
| 19 | Calibration drift between `weiPerBudgetUnitEth` and `weiPerBudgetUnitBold` due to ETH/USD price movement (v1.2 → v1.3) | n/a | v1.2: wide `maxFeeBps` allows manual compensation, redeploy if structural.  **v1.3: embedded AMM continuously rebalances reserves toward market ratio via arbitrageur swap activity; drift is self-correcting.**  Wide `maxFeeBps` retained as belt-and-braces | OQ-GP-12 resolution v1.3: embedded AMM (GP.11) |
| 20 | Flash-loan attack on the AMM to manipulate the internal price (v1.3) | n/a | The AMM price isn't consumed by any *external* contract reading it (no on-chain oracle dependency on `ammReserveEth / ammReserveBold`).  An attacker can manipulate the price temporarily but at a cost (k grows on every swap; round-tripping pays the 0.30% × 2 = 0.60% fee).  Manipulation is bounded by attacker capital × fee cost; no externality exploits this manipulation | AMM math: k-monotonicity (GP.11.3); no external oracle consumers of the AMM price |
| 21 | Sandwich attack on a user's AMM swap (v1.3) | n/a | User specifies `minAmountOut` and `deadline`; if attacker front-runs to move price unfavorably, user's tx reverts (no execution at worse-than-acceptable rate).  Attacker loses gas on the front-run + back-run sandwich without extracting value.  Standard MEV-protection pattern from Uniswap v2 | `minAmountOut` slippage parameter + `deadline` timestamp (GP.11.3); off-bridge: use Flashbots Protect or Cowswap intent system |
| 22 | Drain the AMM by repeated one-sided swaps (v1.3) | n/a | AMM curve property: as `R_in → ∞`, `R_out → 0` asymptotically but never reaches zero (`amountOut < R_out` strict inequality, proven via constant-product math).  The reserve being drained becomes prohibitively expensive at the margin; attacker pays exponentially more per output unit | Constant-product curve mathematics (GP.11.3); proof of `amountOut < reserveOut` |
| 23 | First-swap exploit: empty reserves allow zero-cost manipulation (v1.3) | n/a | If either reserve is 0, `ammSwap` reverts with `AmmEmpty` (GP.11.3 check `if (reserveIn == 0 \|\| reserveOut == 0)`).  No swap can execute against empty reserves; operator must seed both currencies via the normal deposit-side mechanism before swaps work | `AmmEmpty` revert in GP.11.3 |
| 24 | Impermanent loss drains the gas pool faster than fees accumulate (v1.3) | n/a | IL is bounded by ETH/BOLD relative-price movement.  Net APR for the gas pool = fee_revenue_APR - IL_rate.  Historical ETH/USD-stablecoin pairs have run ~2-8% net APR on Uniswap v2 over multi-year periods.  Below break-even, the gas pool's free-reserve fraction (1 - ammSeedRatioBps) continues to cover sequencer claims; the AMM portion becomes a balanced position rather than a profit center.  Not a soundness failure mode; economic calibration concern documented in the runbook | Operator can adjust `ammSeedRatioBps` at next deployment via `KnomosisMigration` |
| 25 | Liquity V2 branch shutdown for a benign reason (e.g., governance-decided wind-down without depeg) triggers BOLD circuit-breaker (v1.6) | n/a | Both circuit-breaker paths (manual GP.5.5 operator key, auto-trigger `closeBoldCircuitIfAnyLiquityBranchShutdown`) only halt new BOLD *deposits*.  Existing reserves remain withdrawable; sequencer claims continue.  A benign branch shutdown is unlikely (Liquity V2's `shutdownTime` is the protocol-internal "this branch is wound down" indicator) but if it occurs, the cost is paused BOLD deposits until the operator confirms the situation and calls `openBoldCircuit()` | Asymmetric circuit-breaker design: deposits halted, withdrawals continue (GP.5.5) |
| 26 | Delegated top-up reentrancy: malicious delegate signs back-to-back topUpActionBudgetFor actions to drain own balance into target's budget (v1.3) | n/a | The delegate is paying their *own* balance for the gas-resource debit; they cannot drain another actor's balance.  The recipient's budget grows but no one else loses funds.  Net: the delegate has spent their balance to give the recipient budget; this is exactly the intended semantics, not an attack | `topUpActionBudgetFor` debits the signer (delegate), not the recipient |

Items 1–7' are *novel* DoS-resistance properties introduced by
v1.0/v1.1 of Workstream GP.  Items 8–12 are *preserved* properties
from pre-existing bridge architecture.  Items 13–15 are *partial*
mitigations from v1.1; 13 is closed by future Workstream SB, 14
is closed by EVM semantics, 15 is closed by economic alignment.
Items 16–19 are the *new attack surface* introduced by v1.2's
BOLD support; all are bounded by operator-policy mechanisms
rather than kernel invariants (the kernel's job is consistent
accounting; operational stablecoin risk is the operator's
domain).

The v1.2 design adds operator-controlled defense-in-depth
(per-BOLD circuit breaker, per-BOLD TVL cap) to compensate for
the inherent risks of holding an external stablecoin as a gas-
pool reserve.  The choice to use BOLD (Liquity V2) over USDC
trades issuer-freeze risk for depeg-volatility risk; the
operator runbook recommends sizing `boldTvlCap` modestly until
operational confidence builds.

---

## Appendix C — Design iteration notes

The plan above is v1.5.  Iteration history:
  * v1.0 → derived from an initial sketch through three rounds
    of optimisation + one round of refinement (rounds 1-3 +
    refinement pass 1).
  * v1.1 → added one further optimisation round (the
    user-chosen fee mechanism with proportional budget grant)
    plus refinement pass 2 (rounds 4 + refinement pass 2).
  * v1.2 → added one further optimisation round (multi-resource
    pool with BOLD as the stablecoin denomination, leveraging
    the existing resource-parametric law) plus refinement pass
    3 (round 5 + refinement pass 3).
  * v1.3 → added one further optimisation round (embedded AMM
    + delegated topup + Liquity V2 redemption signal) plus
    refinement pass 4 (round 6 + refinement pass 4), driven by
    explicit user-decision answers to OQ-GP-1 through
    OQ-GP-17 (the original 13 OQs + 4 AMM-specific
    follow-ups).
  * v1.4 → audit-pass refinement (no new mechanisms).  Round 7
    findings (3 security fixes + 5 new WUs filling coverage
    gaps + complex-WU subdivision + Quick Reference tables) +
    refinement pass 5 (end-to-end best-practices audit).
  * v1.5 → deeper audit pass correcting bugs that v1.4 missed.
    Round 8 findings (6 fixes: gasPoolPolicy deny-list omission,
    bridge accounting equation AMM extension, missing
    bridgePolicy WU, missing `ammActive` modifier, `ammDisabled`
    deposit interaction, `Action.toTransition` signer-threading)
    + refinement pass 6 (cross-referencing every WU against
    actual code stubs to find hidden inconsistencies).

All thirteen rounds are recorded below.

**Optimisation round 1 — minimise kernel TCB churn.**
Initial sketch put budget enforcement inside `step_impl`, treating
budget as part of the kernel state.  This grew the TCB by ~150 LoC.
Optimised by *layering* budget enforcement in the SignedAction
admission pipeline (one level up from `step_impl`), so the kernel
remains unchanged.  Result: TCB delta = zero.

**Optimisation round 2 — minimise new state.**
Initial sketch had separate `budgetBalance`, `lastEpochSeen`,
`topUpHistory`, and `freeTierFlag` fields per actor.  Optimised to
two fields (`lastSeenEpoch`, `budgetBalance`) with the
`normalise`-on-read pattern handling free-tier replenishment and
top-up accumulation in a single number.  Result: state size halved;
encoding simpler; correctness proofs simpler.

**Optimisation round 3 — minimise new actions.**
Initial sketch had four new actions: `depositWithFee`,
`topUpActionBudget`, `advanceEpoch`, `claimGasReimbursement`.
Optimised by:
* `advanceEpoch` → eliminated via lazy `normalise`-on-read.
* `claimGasReimbursement` → folded into the existing `transfer`
  action (gasPoolActor → sequencerActor) constrained by
  `gasPoolPolicy`.
Result: two new actions instead of four; surface area halved;
proof obligations reduced.

**Refinement pass 1 — end-to-end soundness recheck (v1.0).**
Each Lean code block was re-verified mathematically (the
`depositWithFee` self-credit case, the `topUpActionBudget` self-
topup corner case, the `consume` truncated-subtraction safety, the
Solidity `userAmount = msg.value - fee` underflow safety).  The
`normalise_balance_lower_bound` lemma was re-stated correctly in
GP.1.2 with an explicit "the unified form is fine because `max …
≥ left`" check.  The `gasPoolPolicy`'s `denyTags`-is-a-deny-list
gotcha was flagged in-source.  The `OQ-GP-6` bridgeActor-exemption
was added after spotting that without it, bridge actions would also
hit the budget gate.  The `OQ-GP-4` L1-block-vs-wall-clock
question was resolved in favour of L1 block to preserve replay
determinism.

**Optimisation round 4 — user-chosen fee with budget grant (v1.1).**
v1.0's immutable, deployment-wide `feeBps` was replaced with a
per-deposit, user-chosen fee mechanism.  Design problem solved:
"super-users" cannot pre-purchase capacity with a single
high-fee deposit under v1.0; they have to either deposit at the
fixed rate and accept the standard skim or repeatedly invoke
`topUpActionBudget` post-deposit.  Both paths add friction;
neither lets a deployment offer a "premium tier" UX.

The v1.1 design adds three immutable constructor parameters
(`minFeeBps`, `maxFeeBps`, `weiPerBudgetUnit`) and one new
action-payload field (`budgetGrant`) carried by
`Action.depositWithFee`.  The L1 contract computes
`budgetGrant = min(MAX_BUDGET_PER_DEPOSIT, poolAmount /
weiPerBudgetUnit)` and emits it on `DepositWithFeeInitiated`;
the L2 admission layer applies the grant via the same
`EpochBudgetState.topUp` primitive used by
`topUpActionBudget`.

Three sub-optimisations within round 4:
  4a. **Persist `budgetGrant` in `DepositRecord`** rather than
      re-deriving from `poolAmount / weiPerBudgetUnit` at
      replay time.  Re-derivation would require L2 to know the
      L1 `weiPerBudgetUnit`, which is per-deployment immutable
      but would tangle the L2 state with L1 contract state.
      Persisting the grant decouples the two stacks cleanly
      and makes replay reproducible under deployment migration.
  4b. **Bridge-actor budget exemption** in admission, not at
      the `depositWithFee` law level.  Putting the exemption
      in admission (keyed on `signer == bridgeActor`) means
      no per-law special case is needed; the existing
      `bridgePolicy_*` family of theorems carries the
      "only bridgeActor can sign these actions" property
      forward unchanged.
  4c. **Clamp-not-revert at `MAX_BUDGET_PER_DEPOSIT`.**  If a
      deposit's `poolAmount / weiPerBudgetUnit` exceeds the
      cap, the budget grant is clamped to the cap and the
      deposit succeeds; reverting would create UX cliffs where
      a slightly-too-large deposit fails outright.  Clamping is
      consistent with the safer-for-user fee-rounding default
      established in v1.0 (floor-division residue goes to the
      user, not the pool).

**Refinement pass 2 — end-to-end soundness recheck (v1.1).**
Each new Lean code block was re-verified:
  * The `depositWithFee` `_budgetGrant` parameter is correctly
    handled by the admission layer (read off the action payload,
    applied at `recipient`'s slot).  The kernel `apply_impl`
    still takes the parameter but ignores it — the underscore
    prefix `_budgetGrant` is the correct Lean idiom for
    "carried for cross-stack equivalence, not consumed by this
    function."
  * The Solidity fee-split math was re-verified:
    `poolAmount ≤ v × maxFeeBps / 10000 ≤ v × 5000 / 10000 ≤
    v / 2` under `maxFeeBps ≤ MAX_FEE_BPS_CAP = 5000`,
    guaranteeing `userAmount = v - poolAmount ≥ v / 2` and the
    `unchecked` subtraction is safe.  Round-trip:
    `userAmount + poolAmount = v` exactly, with the
    `mod 10000` residue (≤ 9999 wei) accruing to the user.
  * The `budgetGrant` arithmetic was re-verified:
    `rawBudgetGrant = poolAmount / weiPerBudgetUnit ≤
    poolAmount ≤ v ≤ uint256.max` (since `weiPerBudgetUnit
    ≥ 1`), safely fits uint256.  The cast to `uint64` is gated
    by the explicit `> MAX_BUDGET_PER_DEPOSIT = 10¹²` check;
    since `10¹² < 2⁶³ − 1`, the cast is always safe.
  * The **zero-deposit guard** was added (a v1.0 oversight):
    a `msg.value == 0` deposit would otherwise consume a
    `depositNonce` slot at zero L1 gas marginal cost (after the
    base tx gas), enabling a low-cost L1 depositNonce-exhaustion
    DoS over time.
  * The `gasPoolActor`'s `LocalPolicy` was re-checked: it still
    enforces `denyTags [1..20]` (deny everything except
    `transfer`); the addition of `depositWithFee` and
    `topUpActionBudget` to the action set at indices 19 and 20
    is correctly covered by the existing `List.range 21 |>.
    filter (· ≠ 0)` formulation at the v1.2 cut-off.

  * **v1.5 amendment:** v1.3's introduction of action indices
    21 (`topUpActionBudgetFor`) and 22 (`ammSwap`) requires
    bumping the deny-list range from 21 to 23.  The v1.4 audit
    pass missed this gap; v1.5 closes it.  See WU GP.7.2.

The v1.1 plan was internally consistent and mathematically
sound for the single-resource case.  v1.2 builds on it
incrementally.

**Optimisation round 5 — multi-resource pool with BOLD as
stablecoin denomination (v1.2).**
v1.1's gas pool was ETH-only, exposing users to ETH/USD
volatility on the gas-pricing axis.  The v1.2 design extends
to a two-resource pool (`ResourceId 0` = ETH, `ResourceId 1` =
BOLD), allowing users to deposit either currency and receive a
budget grant calibrated for USD parity across the two paths.

Design problem solved: stable-USD gas pricing without
introducing an embedded AMM (which would add substantial
complexity, audit cost, and bug-surface area).  The "no AMM in
v1.2" decision was deliberate after weighing the four design
options in the v1.1-era discussion: external L1 DEXes
(Uniswap v3, Cowswap) handle the relatively rare ETH↔BOLD
swap when the sequencer needs to convert for L1 publishing.

Four sub-optimisations within round 5:
  5a. **Leverage existing resource-parametricity.**  v1.0's
      `Laws/DepositWithFee.lean` has always taken a
      `r : ResourceId` parameter; v1.2 just exercises this
      parameter at `r = 1` instead of restricting to `r = 0`.
      Kernel-side theorem deltas are minimal — every existing
      theorem extends to `ResourceId 1` by parameter
      substitution.  No new law, no kernel TCB delta.
  5b. **Compile-time BOLD address pin.**  Rather than making
      the BOLD address a constructor argument and trusting
      the deployer, hardcode it as a compile-time constant
      (`0x6440f144b7e50d6a8439336510312d2f54beb01d`) and have
      the constructor verify the supplied address matches.
      Defence-in-depth: also call `symbol()` and verify
      `"BOLD"`.  Prevents the most likely failure mode (a
      mis-configured deployment pointing at an attacker
      token).
  5c. **Per-resource circuit breakers + TVL caps.**  The BOLD
      leg gets its own circuit breaker (`boldCircuitClosed`)
      and TVL cap (`boldTvlCap`), separate from the global
      ones.  Allows a deployment to halt new BOLD deposits
      during a depeg event while keeping ETH deposits flowing,
      and to bound BOLD exposure independently of ETH.
  5d. **Per-resource `gasPoolPolicy` clauses.**  Rather than
      replicate the entire policy for each resource, extend
      v1.1's policy with two additional clauses
      (`requireRecipientIn 1`, `capAmount 1`).  Policy
      structure remains flat; locality of resource-keyed
      clauses (each clause only fires when the action's
      resource matches) makes this composable.

**Refinement pass 3 — end-to-end soundness recheck (v1.2).**
Each new code block was re-verified:
  * **Calibration parity.**  At ETH = $3 000 / BOLD = $1, with
    `weiPerBudgetUnitEth = 10¹²` and `weiPerBudgetUnitBold =
    3 × 10¹⁵`, the per-USD budget grant is `≈ 333 units/USD`
    on both legs.  Verified algebraically:
    `(F × 10¹⁵ / 3) / 10¹² = F × 10³ / 3 ≈ 333.33 × F` for
    ETH; `(F × 10¹⁸) / (3 × 10¹⁵) = F × 10³ / 3 ≈ 333.33 × F`
    for BOLD.  Floor-division residues are bounded (a few
    units at most) and consistent in direction.
  * **BOLD ERC-20 conformance defence-in-depth.**  The
    `transferFrom` + `balanceOf` delta check in
    `depositBoldWithFee` would fail loudly if BOLD ever
    changes semantics (e.g., adds fee-on-transfer in a future
    Liquity V2 upgrade).  Safe under `unchecked` because
    `balAfter ≥ balBefore` after a successful `transferFrom`.
  * **Circuit-breaker isolation.**  `boldCircuitClosed`
    affects ONLY `depositBoldWithFee`.  The global
    `circuitOpen` (existing) affects all deposits.  Per-leg
    independence verified: if global open + BOLD closed, ETH
    deposits continue.
  * **Per-resource TVL cap composition.**  `boldTvlCap` is
    constructor-bounded by the global `tvlCap`, so the BOLD
    cap is strictly tighter.  Verified that the BOLD check
    fires before the global check in `_registerDepositWithFee`.
  * **`gasPoolPolicy` locality.**  Verified that
    `requireRecipientIn 0` and `requireRecipientIn 1` operate
    independently — a transfer at resource 0 is unaffected by
    the resource-1 clauses (vacuous match), and vice versa.
    This is the formal property
    `gasPoolPolicy_eth_bold_independent`.
  * **Pool drain bound per resource.**  Verified that the
    inductive accounting argument in
    `pool_drain_bounded_by_action_count_per_resource` is
    sound: an action at resource `r` consumes at most
    `maxDrainPerAction r` from the pool's resource-`r` slot
    and zero from the other slot (by `LocalTo [r]`).  Per-leg
    drain bounds compose without interference.
  * **Calibration drift handling.**  OQ-GP-12 added with
    explicit resolution: accept drift, redeploy if needed.
    Wide `maxFeeBps = 5000` gives users 50% slack to
    compensate for short-term drift; long-term drift demands
    a redeploy via `KnomosisMigration`.
  * **Stablecoin selection rationale.**  Documented the
    BOLD-vs-USDC trade-off (issuer-freeze risk vs depeg-
    volatility risk); Liquity V2's track record (inherited
    from LUSD's multi-year peg stability) justifies the
    choice for a permissionless rollup architecture.

The v1.2 plan was consistent and mathematically sound for the
single-asset-class-pair pool case without internal price discovery.
v1.3 builds on it.

**Optimisation round 6 — embedded AMM, delegated topup, Liquity
redemption signal (v1.3).**
v1.2's external-DEX path for sequencer claims and calibration-
drift mitigation introduced an unstated trust assumption on
Uniswap v3 and exposed sequencer reimbursements to MEV.  v1.3
incorporates an internal constant-product AMM directly into
`KnomosisBridge`, making ETH↔BOLD price discovery a first-class
bridge feature.  Additionally, v1.3 adds pre-authorised
delegated budget top-ups (per OQ-GP-7) and replaces v1.2's
off-chain oracle for the BOLD depeg signal with Liquity V2's
own redemption-rate (per OQ-GP-13).

Five sub-optimisations within round 6:
  6a. **Constant-product AMM math.**  Use Uniswap v2-style
      `R_eth × R_bold = k` invariant.  Predictable, battle-
      tested, easy to formalise.  Fee revenue (0.30 %) stays
      in the reserves (Uniswap v2 mechanism) rather than
      being separately accumulated — simplifies the bookkeeping
      and lets k monotonically grow as the pool benefits from
      every swap.
  6b. **Gas pool is the sole LP.**  No LP tokens, no external
      LPs.  Simplifies the contract; concentrates AMM
      economics in the gas pool.  Trade-off: less capital
      efficiency vs Uniswap v2 which can attract external LPs;
      acceptable for v1.3 (revisit in future workstream).
  6c. **Operator-set `ammSeedRatioBps`.**  Constructor-
      immutable fraction of every pool deposit that flows to
      AMM liquidity vs free pool reserves.  Bounded by
      `MAX_AMM_SEED_RATIO_BPS = 8000` (80 %) compile-time cap.
      Lets the operator tune the trade-off between "AMM depth"
      and "free reserves for sequencer claims" at deploy time.
  6d. **`ammSwap` law's non-conservation status.**  The new
      `Action.ammSwap` law is neither `IsConservative` nor
      `IsMonotonic` at every resource (trading one resource
      for another is fundamentally not conservative *within*
      either single resource).  Kernel handles this via type-
      class non-existence: attempting to construct a
      `ConservativeLawSet` containing `ammSwap` simply fails
      to elaborate.  No new typeclass needed; the existing
      classification system catches this correctly.
  6e. **Liquity-V2-redemption auto-trigger as opt-in.**  v1.3
      ships BOTH the v1.2 operator-manual path AND a new
      `closeBoldCircuitIfRedeemingHeavily()` permissionless
      auto-trigger.  Deployments choose at construction via
      `enableLiquityAutoCircuitTrigger` flag.  Reads from
      Liquity V2's `BorrowerOperations` contract; threshold
      `BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS = 500` (5 %
      redemption rate).

**Refinement pass 4 — end-to-end soundness recheck (v1.3).**
Each new code block was re-verified:

  * **AMM k-monotonicity.**  Verified algebraically:
    `(R_in + amountIn) × (R_out - amountOut) ≥ R_in × R_out`
    holds whenever `AMM_SWAP_FEE_BPS ≥ 0` and `amountIn ≥ 0`.
    Strict inequality when `AMM_SWAP_FEE_BPS > 0` AND
    `amountIn > 0`.  Pool's reserve-value grows over time.
  * **AMM no-drain-to-zero.**  Verified algebraically:
    `amountOut < R_out` follows from
    `amountInWithFee < R_in × 10000 + amountInWithFee`, which
    holds whenever `R_in > 0`.  The reserve being drained
    never reaches zero; the curve is hyperbolic.
  * **AMM seeding consistency.**  `userAmount + freePoolAmount
    + ammSeedAmount = msg.value` exactly for ETH deposits;
    `freePoolAmount + ammSeedAmount = poolAmount` exactly for
    the split breakdown.  No funds minted from nothing.
  * **AMM slippage protection.**  `amountOut < minAmountOut`
    reverts; user can set `minAmountOut = 0` to disable.
  * **AMM deadline protection.**  `block.timestamp > deadline`
    reverts; standard Uniswap pattern.
  * **AMM reentrancy.**  `nonReentrant` modifier; CEI pattern
    (Checks, Effects, Interactions).  Both ETH `call` and BOLD
    `transfer` happen after state updates.
  * **`Action.ammSwap` truncated-subtraction safety.**  The
    `getBalance s toResource ammReserveActor ≥ amountOut`
    precondition ensures the Nat subtraction in step 2 is
    truncation-safe.
  * **Delegated topup consent semantics.**  The recipient
    must declare `LocalPolicyClause.allowTopUpFrom [delegate]`
    via a prior `declareLocalPolicy` action.  Without prior
    declaration, the delegated topup fails admission.  The
    delegate cannot bypass consent.
  * **Liquity auto-trigger idempotency.**  Calling
    `closeBoldCircuitIfRedeemingHeavily` twice is safe; the
    second call returns without state change (idempotent).
  * **Cross-contract dependency on Liquity V2.**  Address pin
    `LIQUITY_V2_BORROWER_OPS` is compile-time-immutable.
    Future Liquity V2 upgrade contracts require a
    `KnomosisMigration` handoff to a new bridge that reads from
    the new address.  Documented in operator runbook.
  * **`ammReserveActor` policy correctness.**  The policy is
    declared on `ammReserveActor` but the actual gating
    happens via `bridgePolicy` on `bridgeActor` (the signer).
    Documented in the source code as a defence-in-depth
    measure that's structurally unreachable in normal
    operation.

The v1.3 plan was complete in terms of mechanism scope.  v1.4
focuses on hardening, structural improvements, and coverage of
gaps that v1.3 left implicit.

**Optimisation round 7 — audit-pass refinement (v1.4).**
A structured audit pass over the v1.3 plan identified three
security issues and several coverage gaps; v1.4 addresses each.

Three security fixes:
  7a. **Delegated topup default-deny.**  v1.3's
      `Action.topUpActionBudgetFor` specification was
      ambiguous about what happens when the recipient has NO
      `allowTopUpFrom` clause.  The intent was default-deny;
      the spec read default-allow.  v1.4 introduces explicit
      `positivelyGatedActionOk` admission logic that requires
      the recipient's policy to contain *some* `allowTopUpFrom`
      clause AND the signer to be in its list.  Closes
      identity-tagging / state-bloat / policy-bypass attacks.
  7b. **receiptHash specification.**  v1.3 emitted
      `receiptHash` from `_registerDepositWithFee` with the
      hash computation marked as `...` placeholder.  An L2
      ingestor that doesn't verify the hash correctly could
      be tricked by an event with modified fields.  v1.4
      specifies the hash precisely: `keccak256(abi.encode(
      sender, resourceId, token, userAmount, freePoolAmount,
      ammSeedAmount, budgetGrant, depositNonce))`.  Every
      emitted field is covered.
  7c. **Liquity V2 read hardening.**  v1.3's
      `closeBoldCircuitIfRedeemingHeavily` made an unguarded
      external call to Liquity V2.  If Liquity V2's interface
      changes in a hypothetical future re-deployment, the call
      could propagate opaque errors.  v1.4 wraps the call in
      try/catch and reverts with `LiquityV2ReadFailed`,
      giving the operator a clear signal to switch to manual
      mode.

Five new WUs filling v1.3 coverage gaps:
  7d. **GP.11.8 (state-root commitment integration).**  v1.3's
      AMM state was added to `KnomosisBridge` but the state-root
      preimage was not updated to commit it.  Without
      commitment, the fault-proof game cannot adjudicate
      disputes that turn on AMM state.  v1.4 extends the
      preimage to include `ammReserveEth`, `ammReserveBold`,
      `boldCircuitClosed`, `boldTvlCap`,
      `boldTotalLockedValue`.
  7e. **GP.11.9 (gas-cost benchmarks).**  Forge gas-snapshot
      benchmarks for every new L1 operation; baseline numbers
      committed; CI gate on regressions > 5 %.
  7f. **GP.11.10 (AMM disaster recovery).**  Operator-triggered
      one-way `emergencyDisableAmm()` function with strict
      multi-sig access control; new `DisasterRecovery` role.
      Specifies the recovery decision tree.
  7g. **GP.8.4 (operator runbook v1.3 expansion).**  Major
      expansion covering multi-resource deployment, AMM
      operational guidance, Liquity-trigger procedures, AMM
      disaster recovery, gas-cost projections, delegated topup
      patterns, and monitoring + alerting checklist.
  7h. **GP.10.6 (build-system + audit-binary updates).**
      Explicit WU for the audit binaries (`count_sorries`,
      `tcb_audit`, `naming_audit`, etc.) to ensure CI is
      actually checking the new code.  Build-tag bump from
      `"knomosis-step-vm-coherence"` to `"knomosis-gas-pool-amm"`.

Complex-WU subdivision:
  7i. **Six complex WUs subdivided** into ~30 granular sub-WUs:
      GP.3.{1,2,3,4} (4 → 21 sub-WUs); GP.5.{1,2,3,4,5} (5 →
      26 sub-WUs); GP.11.{1,2,3,4,5,6,7} (7 → ~20 sub-WUs).
      Most sub-WUs are 2-4 hours; longest is 6 hours.  Enables
      parallel implementation by 2-3 contributors on disjoint
      file partitions.

Structural improvement:
  7j. **Quick Reference section** at top of document
      consolidates canonical values (reserved ActorIds, frozen
      Action / Event indices, immutable constructor parameters,
      compile-time constants).  Single source of truth;
      eliminates document-grep for these values.

**Refinement pass 5 — end-to-end best-practices audit (v1.4).**
Verified end-to-end:

  * **No new mechanism added.**  v1.4 is strictly a
    refactoring + hardening pass.  Mechanism scope is
    identical to v1.3.
  * **TCB delta still zero.**  No v1.4 work touches
    `Kernel.lean` or `RBMapLemmas.lean`.
  * **Theorem count stable at ~81.**  No new theorems; v1.4
    refines existing theorems (default-deny semantics,
    receiptHash coverage) without adding new ones.
  * **No new axioms or opaques.**  v1.4 changes preserve the
    canonical `propext` / `Classical.choice` / `Quot.sound`
    axiom set.
  * **Cross-references validated.**  Dependency graph
    Appendix A still acyclic; every cross-WU reference
    resolves to a real WU.
  * **Quick Reference table cross-checked** against every
    occurrence in the document.  Action indices, ActorIds,
    constants all consistent.
  * **OQ resolutions cross-checked** against their references
    in body text.  OQ-GP-7's default-deny resolution
    integrated; OQ-GP-12's AMM mechanism integrated; OQ-GP-13's
    Liquity signal integrated.
  * **Attack tree coverage validated.**  Items 16-26 reference
    real WUs in the engineering plan.  Each mitigation cites
    its source.

The v1.4 plan ALMOST achieved consistency, but a deeper v1.5
audit pass revealed six v1.3-era bugs that v1.4's audit missed.

**Optimisation round 8 — deeper audit pass (v1.5).**

The v1.4 audit pass focused on the most visible issues (the
three security fixes documented as 7a, 7b, 7c).  A subsequent
deeper read of the document against the actual code stubs
identified six additional issues that v1.4 didn't catch:

  8a. **gasPoolPolicy deny-list missed v1.3 indices.**  The
      `List.range 21 |>.filter (· ≠ 0)` formulation in WU
      GP.7.2 was correct at v1.2 (which had 21 action indices,
      0..20).  v1.3 added indices 21 (`topUpActionBudgetFor`)
      and 22 (`ammSwap`) but the deny-list range was not
      bumped from 21 to 23.  Consequence: gasPoolActor could
      in principle sign these actions, violating the
      gas-pool's "only-transfer" outflow discipline.
      v1.5 fixes: bump to `List.range 23`.
  8b. **Bridge accounting equation didn't cover AMM swap
      flows.**  v1.3 introduced ammReserveActor and AMM swaps
      that move funds between resources within the bridge.
      The v1.2 accounting equation was preserved verbatim but
      doesn't account for swap-driven changes to L1 escrow.
      v1.5 fixes: add the strong-conservation property
      `bridgeEscrowBalance(r) = Σ getBalance s r a over all
      actors a`, with new theorems
      `bridge_strong_conservation_under_ammSwap`,
      `bridge_strong_conservation_under_depositWithFee`, and
      `bridge_strong_conservation_inductive`.
  8c. **bridgePolicy extension was implicit.**  v1.0 – v1.4
      assumed `bridgeActor` could sign `depositWithFee` (v1.0)
      and `ammSwap` (v1.3) but never specified the extension
      to `bridgePolicy` as a discrete WU.  Without it,
      admission would reject these actions via the existing
      `bridgePolicy_*` family of theorems.  v1.5 fixes: new
      WU GP.7.0 explicitly amends `bridgePolicy`.
  8d. **`ammActive` modifier missing from `ammSwap`
      signature.**  v1.4's WU GP.11.10 specified an
      `ammActive` modifier that should be applied to
      `ammSwap` but GP.11.3.b's code stub didn't include
      it.  Consequence: after a disaster-recovery
      `emergencyDisableAmm()` call, `ammSwap` would still
      work because the modifier wasn't gating it.  v1.5
      fixes: add `ammActive` to the `ammSwap` function
      declaration.
  8e. **`ammDisabled` interaction with deposit seeding
      undefined.**  v1.4 disabled `ammSwap` via the
      `ammDisabled` flag but didn't specify what happens to
      deposit-time AMM seeding (GP.11.2's
      `ammSeedAmount = poolAmount × ammSeedRatioBps / 10000`).
      Consequence: deposits would continue seeding a disabled
      AMM, accumulating reserves that can't participate in
      swaps.  v1.5 fixes: when `ammDisabled`, route all
      poolAmount to free pool reserves (skip AMM seed).
  8f. **`Action.toTransition` signer-threading not
      specified.**  The admission layer constructs a Transition
      from an Action payload, but for actions whose laws
      depend on the signer (existing `transfer`'s sender, v1.0
      `topUpActionBudget`'s `a`, v1.3 `topUpActionBudgetFor`'s
      `signer`), the toTransition function must thread the
      signer from `SignedAction.signer`.  v1.0 – v1.4
      implicitly assumed this but didn't specify.  v1.5
      fixes: explicit clarification in WU GP.3.2's admission
      code stub showing `Action.toTransition sa.action
      sa.signer` and per-action mapping.

**Refinement pass 6 — cross-stub consistency audit (v1.5).**

The v1.4 audit pass focused on standalone correctness of each
WU's code stub.  v1.5's refinement pass cross-referenced each
code stub against:

  * Other stubs that mention the same Solidity function /
    Lean definition.
  * The Quick Reference tables.
  * The Theorem catalogue.
  * The Attack tree.
  * The OQ resolutions.

This caught the six issues above (each of which had a
"reference" elsewhere that was inconsistent with the stub).
For example: GP.11.10 said "`ammActive` modifier applied to
ammSwap", but GP.11.3's code stub didn't show it.  The
cross-reference made the gap visible.

Verified end-to-end:
  * **Consistency between sections:** every code stub
    cross-checked against the Quick Reference and Theorem
    catalogue.  Six previously-undetected inconsistencies
    found and fixed.
  * **No new mechanism added.**  Same headline mechanism set
    as v1.3 and v1.4.
  * **TCB delta still zero.**
  * **Theorem count grows by 3** (the new
    `bridge_strong_conservation_*` family): ~81 → ~84.
  * **No new axioms or opaques.**
  * **All cross-references between WUs validated.**

The v1.5 plan is now consistent, mathematically sound, and
contributor-tractable: **multi-resource gas pool (ETH + BOLD)
with user-chosen-fee deposits, embedded constant-product AMM
for ETH↔BOLD price discovery, per-actor budget DoS resistance,
pre-authorised delegated budget topups, and Liquity V2
redemption-trigger circuit breaker**.  Total scope: ~84
theorems, 56+ work units across 11 phases, ~485 hours of
focused engineering work spread across Lean kernel, Solidity
L1 contracts, and Rust runtime adaptors.

**Audit-pass discipline lessons.**  v1.4 → v1.5 illustrates a
key audit-pass principle: a *single-pass* audit (reading top
to bottom) often misses *cross-stub inconsistencies* (where
two parts of the document reference each other but disagree
on the spec).  Catching these requires either (a) a second
pass focused specifically on cross-references, or (b)
mechanical tools (grep for shared terms, then verify
consistency).  v1.5 used method (a); future audit passes
should institutionalise method (b) via lint-like checks on
the planning document itself.

The complete plan covers the design from the highest level
(motivation: closing the DoS-funding circularity gap and giving
users stable USD-denominated gas pricing) down to the lowest
level (per-line Solidity / Lean math sanity checks).  Every
mechanism has a kernel theorem, every L1 operation has a
cross-stack equivalence corpus entry, every economic claim is
either provable or explicitly listed as an operational trust
assumption with documented mitigation.

---

*End of Workstream GP plan.*

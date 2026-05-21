<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Unified Gas Pool, Per-Actor Budgets, and DoS Resistance — Workstream Plan (Workstream GP)

**Document version:** v1.2 (revised from v1.1; multi-resource
gas pool with native ETH + BOLD stablecoin support).

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

**Calibration discipline.**  An operator setting
`weiPerBudgetUnitEth` and `weiPerBudgetUnitBold` should aim for
**USD parity** between the two paths so a user paying $X of fee
gets the same number of budget units regardless of currency.
Set the BOLD rate to:

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

**Re-calibration policy.**  Because both exchange rates are
constructor-immutable, the operator must redeploy via
`CanonMigration` to adjust them.  In practice, ETH/USD drifts
sharply over months; if the deployer fixes the rates at ETH =
$3 000 and ETH moves to $6 000, the ETH-path becomes effectively
half-price relative to BOLD.  Mitigation: target parity at
deploy time, accept drift, redeploy every 12–24 months.
Alternative: pick a wide tolerance via the `chosenFeeBps` range
(e.g., allow `maxFeeBps = 2000` = 20%, so users can compensate
by choosing a higher fee).

  See WU GP.5.4 for the per-resource calibration guidance and
  the operator-runbook recommendations.

The architectural payoff is that **DoS resistance and sequencer
operating-cost funding become the same problem**, not two separate
problems with two separate parameter spaces.  Every admitted action
consumes budget; budget is replenished by funds that ultimately came
from bridge deposits; the sequencer's L1 publishing cost is paid out
of the same pool that the DoS budget came from.  The pool's solvency
is a single economic invariant rather than two coupled ones.

This workstream is **strictly weaker in trust assumptions than the
existing system** in one direction (sequencer cannot drain the pool
beyond the kernel-enforced `capAmount` policy) and **strictly stronger
in DoS resistance** (per-actor budget is a kernel invariant, not a
sequencer-policy hope).

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
    `CanonMigration` handoff);
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
    constructors are preserved and unchanged.  Existing deployments
    that do not opt into GP keep behaving exactly as today — the
    `EpochBudgetState` field defaults to empty, and an empty budget
    state is treated as "unlimited" by the legacy admission policy.
    Opt-in is per-deployment via a new `BudgetPolicy` configuration
    field; legacy deployments set it to `BudgetPolicy.unlimited`.
  * **Frozen indices reserved by this workstream:**
    * `Action.depositWithFee` at index 19
    * `Action.topUpActionBudget` at index 20
    * `Event.depositWithFeeCredited` at index 16
    * `Event.actionBudgetTopUp` at index 17
    * `Event.gasPoolClaim` at index 18
  * **Solidity-side scope:** one amended contract (`CanonBridge.sol`)
    with two parallel entry points (ETH + BOLD); five immutable
    constructor parameters (`minFeeBps`, `maxFeeBps`,
    `weiPerBudgetUnitEth`, `weiPerBudgetUnitBold`,
    `boldTokenAddress`); four compile-time constants
    (`MAX_FEE_BPS_CAP = 5000`, `MIN_WEI_PER_BUDGET_UNIT = 1`,
    `MAX_BUDGET_PER_DEPOSIT = 1_000_000_000_000`,
    `EXPECTED_BOLD_SYMBOL = "BOLD"`); two new payable entry
    points (`depositETHWithFee` taking `chosenFeeBps`,
    `depositBoldWithFee` taking `chosenFeeBps` + `amount`); one
    new event (`DepositWithFeeInitiated`) with `resourceId` field
    distinguishing ETH (0) from BOLD (1).  No new contracts.
  * **Rust-side scope:** four crates touched —
    `canon-l1-ingest` (decode new event, encode new Action variants),
    `canon-host` (admission policy with budget gate),
    `canon-event-subscribe` (new event variants on the wire),
    `canon-storage` / `canon-indexer` (epoch budget view, if a
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
    grow by ~120 tests across `canon-l1-ingest`, `canon-host`,
    `canon-event-subscribe`.  The Solidity side should grow by ~30
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
     GP.5.3 `CanonStepVM` extension for the two new Action
     variants; GP.5.4 (v1.2) parallel `depositBoldWithFee` entry
     point with BOLD ERC-20 integration and BOLD-leg exchange
     rate; GP.5.5 (v1.2) BOLD-specific safety hardening (per-
     currency circuit breaker, per-BOLD TVL cap,
     operator-triggered depeg pause).  Five immutable constructor
     arguments (`minFeeBps`, `maxFeeBps`, `weiPerBudgetUnitEth`,
     `weiPerBudgetUnitBold`, `boldTokenAddress`).  Four compile-
     time caps (`MAX_FEE_BPS_CAP`, `MIN_WEI_PER_BUDGET_UNIT`,
     `MAX_BUDGET_PER_DEPOSIT`, `EXPECTED_BOLD_SYMBOL`).
  7. **GP.6 — Rust runtime.**  `canon-l1-ingest` decode of the new
     event (with `resourceId` field distinguishing ETH vs BOLD);
     `canon-host` admission gate; `canon-event-subscribe` new
     event variants; cross-stack fixtures (ETH leg + BOLD leg).
  8. **GP.7 — Pool actor governance via LocalPolicy.**  Reservation
     of `ActorId 1` as `gasPoolActor`; declaration of the canonical
     `gasPoolPolicy` with `denyTags` + `requireRecipientIn` +
     `capAmount` clauses; theorems bounding pool outflow.
  9. **GP.8 — Sequencer integration.**  `canon-host` and operator
     runbook; free-tier configuration; sequencer-reward-claim
     mechanism.
 10. **GP.10 — Documentation, audits, landing.**  Final
     Genesis-Plan amendment; README / CLAUDE.md updates;
     `docs/abi.md` extensions; migration runbook; full audit pass.
 11. **GP.9 (optional) — Improvements.**  Refund-on-exit;
     yield-bearing pool via Lido / Rocket Pool; tiered fee; dual
     pool for user rewards; stake-bonded identity registration.

The minimum-viable-product (MVP) is GP.0 – GP.8 + GP.10.  GP.9 is a
v2 polish that can land separately.

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
| Per-deposit fee bounded                        | `MIN_FEE_BPS ≤ maxFeeBps ≤ MAX_FEE_BPS_CAP = 5000` (immutable on L1 `CanonBridge` constructor) |
| Budget-grant bounded (both resources)          | `MAX_BUDGET_PER_DEPOSIT = 10¹²` (compile-time constant, applies to both ETH and BOLD paths) |
| ETH-leg exchange rate sane                     | `weiPerBudgetUnitEth ≥ 1` (immutable on L1 `CanonBridge` constructor)     |
| BOLD-leg exchange rate sane                    | `weiPerBudgetUnitBold ≥ 1` (immutable on L1 `CanonBridge` constructor)    |
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

        The L1-side `CanonBridge` contract computes
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

#### WU GP.3.1: `BudgetPolicy` configuration field on `ExtendedState`

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
      | unlimited
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
    * `ExtendedState.genesis_has_unlimited_budget_policy` (a
      design-policy lemma: the default for genesis is
      `unlimited`, so pre-GP deployments migrate transparently).
  * **Tests.**  15 cases including genesis defaults, policy
    switching, encode/decode round-trip.
  * **Acceptance criteria.**  One reviewer; `lake exe count_sorries`
    green; `lake exe naming_audit` green.
  * **Dependencies.**  GP.1.5, GP.1.6.
  * **Estimated effort.**  ~5 hours.

#### WU GP.3.2: `Authority/SignedAction.lean` admission gate

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
      let kernel' := step_impl es.kernel (Action.toTransition sa.action)
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

#### WU GP.3.3: `kernelOnlyApply` extension

  * **Goal.**  Update `LegalKernel/FaultProof/StepVMCoherence.lean`'s
    `kernelOnlyApply` exhaustive match to handle the two new
    constructors at the L1 step VM level.
  * **File:** `LegalKernel/FaultProof/StepVMCoherence.lean`.
  * **Deliverables.**
    * Two new exhaustive arms in `kernelOnlyApply` matching
      `depositWithFee` and `topUpActionBudget`.
    * Updated `stepVMHash_<variant>_kind` for variants 19, 20 (two
      new `rfl` proofs).
    * Updated `step_vm_dispatch_well_typed`.
    * Updated `crosscheck-step-vm` fixture corpus header counters.
  * **Theorems.**
    * `stepVMHash_depositWithFee_kind`
    * `stepVMHash_topUpActionBudget_kind`
    * `recomputeCommitment_coherent_with_kernelOnlyApply` (extended
      proof — adds two new constructor arms).
  * **Tests.**  ~20 new cases in `faultproof-stepvm-coherence` for
    the two new variants.
  * **Acceptance criteria.**  Two reviewers (touches StepVM
    coherence, which is fault-proof-adjacent); full cross-stack
    fixture corpus regenerated + Solidity-side step VM extended
    (WU GP.5.3 picks up the Solidity side).
  * **Dependencies.**  GP.2.3.
  * **Estimated effort.**  ~10 hours.

---

### Phase GP.4 — Bridge accounting amendment

#### WU GP.4.1: Widen `DepositRecord` with `poolAmount`

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
       If a deployment migrates to a new `CanonBridge` with
       different `weiPerBudgetUnitEth` or `weiPerBudgetUnitBold`
       (via `CanonMigration`), the pre-migration deposit records
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
    * `totalUserDeposited_plus_pool_eq_legacy_totalDeposited` for
      `Action.deposit` (legacy) actions (which set `poolAmount = 0`).
  * **Theorems.**
    * `bridge_accounting_equation_balanced` (the equation holds
      after any single bridge action, modulo the L1-side escrow
      change).
    * `pool_balance_eq_totalPoolDeposited_minus_payouts`: the L2
      `gasPoolActor` balance equals
      `Σ poolAmount in consumed records - Σ pool outflows to
      sequencer`.  This is the **pool solvency** invariant — a
      lower bound on pool balance given known outflows.
  * **Tests.**  ~20 cases covering deposits, mixed legacy /
    GP deposits, withdrawals, and pool drains.
  * **Acceptance criteria.**  One reviewer; full Lean test suite
    green.
  * **Dependencies.**  GP.4.1.
  * **Estimated effort.**  ~6 hours.

---

### Phase GP.5 — Solidity L1 contract amendment

#### WU GP.5.1: `CanonBridge.depositETHWithFee` user-chosen fee split

  * **Goal.**  Amend `CanonBridge` with a new pair of payable
    entry points — `depositETHWithFee(uint16 chosenFeeBps)` and
    `depositERC20WithFee(uint64 resourceId, IERC20 token,
    uint256 amount, uint16 chosenFeeBps)` — that let the user
    choose the fee at deposit time within the
    `[minFeeBps, maxFeeBps]` constructor-fixed range.  The
    pool-credit amount is then converted to a budget grant at
    the constructor-fixed `weiPerBudgetUnit` exchange rate,
    clamped at `MAX_BUDGET_PER_DEPOSIT`.
  * **File:** `solidity/src/contracts/CanonBridge.sol`.
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
    /// Bumping requires a CanonMigration handoff.
    uint64 public immutable weiPerBudgetUnitEth;

    /// @notice Immutable BOLD-leg exchange rate: how many wei of
    /// BOLD pool credit produces one unit of action budget.
    /// (BOLD is 18-decimal; the rate is per BOLD-wei.)  Bumping
    /// requires a CanonMigration handoff.
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

#### WU GP.5.2: Constructor-cap constants — rationale and audit gate

  * **Goal.**  Document the three compile-time constants
    (`MAX_FEE_BPS_CAP`, `MIN_WEI_PER_BUDGET_UNIT`,
    `MAX_BUDGET_PER_DEPOSIT`) and add an audit binary that fails
    if any of them is changed without a §13.6 amendment.
  * **Files:**
    * `solidity/src/contracts/CanonBridge.sol` (constants + long
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

#### WU GP.5.3: `CanonStepVM` extension for new variants

  * **Goal.**  Extend the Solidity step VM to execute the two new
    Action variants (depositWithFee = 19, topUpActionBudget = 20)
    byte-equivalently to the Lean kernel.
  * **Files:**
    * `solidity/src/contracts/CanonStepVM.sol`.
    * `solidity/test/CrossCheck/StepVMNewVariants.t.sol` (new).
  * **Deliverables.**  Two new step functions + the dispatcher
    extension.  Cross-stack fixture corpus extended (Lean side
    in `LegalKernel/Test/Bridge/CrossCheck/StepVMFixtures.lean`).
  * **Theorems** (Lean side): GP.3.3 covers the byte-equivalence
    side.
  * **Tests.**  ~30 forge tests + ~30 Lean cross-check entries.
  * **Acceptance criteria.**  Two reviewers; forge + Lean
    cross-check both green.
  * **Dependencies.**  GP.3.3, GP.5.1.
  * **Estimated effort.**  ~14 hours.

#### WU GP.5.4: `CanonBridge.depositBoldWithFee` BOLD entry point (v1.2)

  * **Goal.**  Add the BOLD-currency parallel entry point to
    `CanonBridge`, byte-equivalently to the ETH path but
    operating on the BOLD ERC-20 token via `transferFrom` /
    `transfer`.  The user picks `chosenFeeBps` within the same
    `[minFeeBps, maxFeeBps]` range as the ETH path; the pool
    credit accumulates at `ResourceId 1` instead of
    `ResourceId 0`; the budget grant uses
    `weiPerBudgetUnitBold` as the exchange rate.
  * **File:** `solidity/src/contracts/CanonBridge.sol`
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

  * **Goal.**  Add three BOLD-specific defence-in-depth
    mechanisms not present for the ETH path: a per-currency
    circuit breaker, a TVL cap specific to BOLD, and an
    operator-triggered depeg-detection pause.
  * **File:** `solidity/src/contracts/CanonBridge.sol`
    (further extension); operator-runbook documentation.
  * **Deliverables.**

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
    /// when a depeg or other incident is detected.
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

    /// @notice Operator-set: bump the per-BOLD TVL cap.
    /// Bounded above by the global TVL cap to prevent
    /// exceeding the deployment's overall reserve commitment.
    function setBoldTvlCap(uint256 newCap) external onlyAdmin {
        if (newCap > tvlCap) revert BoldTvlCapExceedsGlobal();
        boldTvlCap = newCap;
        emit BoldTvlCapUpdated(newCap);
    }
    ```

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

#### WU GP.6.1: `canon-l1-ingest` event decode

  * **Goal.**  Decode `DepositWithFeeInitiated` events from
    both `depositETHWithFee` and `depositBoldWithFee` (the
    `resourceId` field distinguishes the two; `0` = ETH,
    `1` = BOLD) and translate to `Action.depositWithFee`
    SignedActions byte-equivalently to Lean.
  * **Files:**
    * `runtime/canon-l1-ingest/src/events.rs` (add the new event
      signature + decoder, including the `uint64 budgetGrant`
      field at the canonical position and the `uint64
      resourceId` field that drives the per-resource branch).
    * `runtime/canon-l1-ingest/src/encoding.rs` (encode the new
      Action variants — `depositWithFee` with 7 fields including
      `budgetGrant`; `topUpActionBudget` with 4 fields — both
      byte-equivalent to the Lean CBE encoder).  The encoder is
      resource-parametric (matches the Lean side); resource = 0
      and resource = 1 produce structurally-identical Action
      bytes with only the `r` field differing.
    * `runtime/canon-l1-ingest/src/lib.rs` (wire the new event
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

#### WU GP.6.2: `canon-host` admission gate

  * **Goal.**  Add the per-actor budget admission gate to the
    canon-host CommandKernel / MockKernel.
  * **File:** `runtime/canon-host/src/kernel.rs` and
    `runtime/canon-host/src/budget.rs` (new module).
  * **Deliverables.**
    * Rust mirror of `ActorBudget` / `EpochBudgetState` (byte-
      equivalent CBE encoding to the Lean side).
    * `Budget` field on `MockKernel` for testing.
    * `CommandKernel` extension: pass `--budget-policy bounded
      --free-tier N --epoch-duration-seconds D` through to the
      `canon` binary.
    * New verdict variant on the wire: optional reason string
      `"InsufficientBudget"` (folded under existing
      `NotAdmissible` verdict per the wire-format-stability
      decision; see §10 OQ-GP-3).
  * **Tests.**  ~30 cases.
  * **Acceptance criteria.**  One reviewer; `cargo test` green.
  * **Dependencies.**  GP.6.1, GP.3.2.
  * **Estimated effort.**  ~14 hours.

#### WU GP.6.3: `canon-event-subscribe` new event variants

  * **Goal.**  Stream the three new event variants
    (`depositWithFeeCredited`, `actionBudgetTopUp`, `gasPoolClaim`)
    to subscribers.
  * **File:** `runtime/canon-event-subscribe/src/lib.rs` etc.
  * **Deliverables.**  Updated event-type registry; wire-format
    extension (additive; new event tags 16/17/18 emit at the
    existing 9-byte framing — no protocol-version bump needed
    per the existing event-subscribe additive-extension policy).
  * **Tests.**  ~15 cases.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.6.1.
  * **Estimated effort.**  ~6 hours.

#### WU GP.6.4: `canon-storage` / `canon-indexer` budget view

  * **Goal.**  Provide an optional per-actor budget view in the
    indexer so a deployment UI can show "you have N actions
    remaining this epoch."
  * **File:** `runtime/canon-indexer/src/budget_view.rs` (new).
  * **Deliverables.**  Three new SQLite tables (`actor_budgets`,
    `pool_balances_eth`, `pool_balances_bold`) + their migration
    + dispatch from the new event variants.  Per-resource pool
    balances are tracked separately so a deployment UI can show
    both legs independently.
  * **Tests.**  ~25 cases (+5 vs v1.1 for the BOLD pool-balance
    view).
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.6.3.
  * **Estimated effort.**  ~12 hours (v1.1 estimated 10; +2 for
    BOLD-leg table + tests).

#### WU GP.6.5: BOLD-specific cross-stack fixture corpus (v1.2)

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

#### WU GP.7.1: `gasPoolActor` reservation

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
          [ .denyTags (List.range 21 |>.filter (· ≠ 0)),
            .requireRecipientIn 0 [sequencerActor],
            .capAmount 0 maxDrainPerActionEth,
            .requireRecipientIn 1 [sequencerActor],
            .capAmount 1 maxDrainPerActionBold
          ] }
    ```

    *Author's mathematical check:*  `List.range 21` produces
    `[0, 1, 2, ..., 20]`.  Filtering out `0` produces
    `[1, 2, ..., 20]` — every Action tag *except* `transfer`.
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
    runs end-to-end via `canon` binary, including a BOLD
    deposit + L2 budget grant + sequencer BOLD-pool claim.
  * **Dependencies.**  GP.7.3.
  * **Estimated effort.**  ~8 hours (v1.0 estimated 6; +2 for
    BOLD-leg integration test coverage).

#### WU GP.7.5: BOLD-leg pool-slot ratification + drain bound (v1.2)

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

#### WU GP.8.1: Sequencer-claim mechanism (v1, honour-system)

  * **Goal.**  Document and implement the sequencer's claim flow
    in canon-host.
  * **Files:**
    * `runtime/canon-host/src/sequencer_claim.rs` (new).
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
    in `canon-host` startup, with documented operational guidance.
  * **File:** `runtime/canon-host/src/main.rs` and
    `runtime/canon-host/README.md`.
  * **Deliverables.**  Two CLI flags.  Runbook section explaining
    how to set them based on (a) deposit volume, (b) sequencer's
    L1 budget, (c) acceptable user-facing latency.
  * **Tests.**  ~5 cases.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.6.2.
  * **Estimated effort.**  ~3 hours.

#### WU GP.8.3: Operator runbook

  * **Goal.**  A standalone operator runbook for deploying and
    running a GP-enabled Canon deployment.
  * **File:** `docs/gas_pool_runbook.md` (new).
  * **Deliverables.**  Sections:
    * Deployment checklist (`minFeeBps`, `maxFeeBps`,
      `weiPerBudgetUnit`, `freeTier`, `epochDuration`,
      `gasPoolActor LocalPolicy` parameters).
    * Calibration guidance for `weiPerBudgetUnit`: typical range
      `[10⁹, 10¹⁵]`; choose so that one budget unit costs
      ~~$0.001–$0.01 in equivalent ETH at deployment time
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

---

### Phase GP.9 — Optional improvements

These are explicitly *deferred* from v1 but planned in enough
detail that they can be picked up as v2 work without re-litigating
the design.

#### WU GP.9.1: Refund-on-exit

Track `depositTime : Nat` on each `DepositRecord`.  On `withdraw`,
allow an optional `claimRefund` companion action that credits the
user with `originalFee × max(0, 1 - (now - depositTime) / T)` for
amortisation window `T`.  Conservation: the refund is a
`gasPoolActor → user` transfer, fully provable.  Bounded above by
the original fee — the user cannot reclaim more than they paid in.

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

`CanonIdentityRegistry.registerECDSA` requires a slashable deposit
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
      `kernelBuildTag` is bumped to `"canon-unified-gas-pool"`
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

  * **Goal.**  Concrete migration steps for a legacy Canon
    deployment to opt into Workstream GP.
  * **File:** `docs/gas_pool_migration_guide.md` (new).
  * **Acceptance criteria.**  One reviewer; an existing test
    deployment migrated end-to-end as proof of correctness.
  * **Dependencies.**  GP.8.3.
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
| `admission_consumes_budget_on_success`            | `Authority/SignedAction.lean`         | new    |
| `admission_rejected_when_budget_zero`             | `Authority/SignedAction.lean`         | new    |
| `topUpActionBudget_net_budget_change`             | `Authority/SignedAction.lean`         | new    |
| `depositWithFee_grants_budget`                    | `Authority/SignedAction.lean`         | new (v1.1) |
| `depositWithFee_budget_locality`                  | `Authority/SignedAction.lean`         | new (v1.1) |
| `bridgeActor_budget_exempt`                       | `Authority/SignedAction.lean`         | new (v1.1) |
| `admission_legacy_compat`                         | `Authority/SignedAction.lean`         | new    |
| `admission_locality_in_budget`                    | `Authority/SignedAction.lean`         | new    |
| `replenishment_via_epoch_advance`                 | `Authority/SignedAction.lean`         | new    |
| `nonce_uniqueness_preserved`                      | `Authority/SignedAction.lean`         | upd.   |
| `replay_impossible_preserved`                     | `Authority/SignedAction.lean`         | upd.   |
| `stepVMHash_depositWithFee_kind`                  | `FaultProof/StepVMCoherence.lean`     | new    |
| `stepVMHash_topUpActionBudget_kind`               | `FaultProof/StepVMCoherence.lean`     | new    |

### Bridge accounting theorems (GP.4)

| Theorem                                           | File                                  | Status |
| ------------------------------------------------- | ------------------------------------- | ------ |
| `DepositRecord.encode_injective`                  | `Encoding/Bridge.lean`                | upd.   |
| `BridgeState.encodeConsumed_injective`            | `Encoding/BridgeInjective.lean`       | upd.   |
| `totalUserDeposited_step_eq`                      | `Bridge/Accounting.lean`              | new    |
| `totalPoolDeposited_step_eq`                      | `Bridge/Accounting.lean`              | new    |
| `bridge_accounting_equation_balanced`             | `Bridge/Accounting.lean`              | new    |
| `pool_balance_eq_totalPoolDeposited_minus_payouts` | `Bridge/Accounting.lean`             | new    |

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

**Total new theorems: ~64** (+3 v1.0→v1.1 for the bridge-
deposit budget-grant trio; +6 v1.1→v1.2 for the multi-resource
extension: `per_resource_pool_independence`,
`gasPoolPolicy_requires_sequencer_recipient_bold`,
`gasPoolPolicy_caps_per_action_bold`,
`gasPoolPolicy_eth_bold_independent`,
`pool_drain_bounded_by_action_count_per_resource`,
`pool_balance_eth_leg_independent_of_bold_actions`).  All in
non-TCB files; none touches `Kernel.lean` or `RBMapLemmas.lean`.
All proofs depend only on `propext`, `Classical.choice`,
`Quot.sound` (the canonical three).

---

## Cross-stack equivalence requirements

The cross-stack fixture corpus is extended in three places:

| Corpus                                                     | New entries     | What it pins                                        |
| ---------------------------------------------------------- | --------------- | --------------------------------------------------- |
| `runtime/tests/cross-stack/l1_ingest_fee_split.cxsf` (new) | 50              | L1 `DepositWithFeeInitiated` → L2 `Action.depositWithFee` byte-equivalence |
| `solidity/test/CrossCheck/fixtures/step_vm_new_variants.json` (new) | 30 | Solidity `executeStep(19/20, …)` ↔ Lean `kernelOnlyApply` byte-equivalence |
| `runtime/canon-host/tests/budget_admission.rs` (new)       | 30              | Rust admission gate ↔ Lean admission gate verdict equivalence |

The Lean fixture generators live alongside the existing SVC.5
generators in `LegalKernel/Test/Bridge/CrossCheck/` and follow the
same `Encodable` discipline.

---

## Migration plan

A legacy Canon deployment (pre-GP) becomes a GP-enabled deployment via:

1. **Stop the sequencer cleanly** (drain in-flight signed actions).
2. **Take a final snapshot** under the legacy `BudgetPolicy.unlimited`
   semantics.
3. **Deploy the new `CanonBridge` contract** on L1 with chosen
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
   `CanonMigration` handoff.
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
   in canon).

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

Should the canon-host wire format add a new top-level verdict for
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

**v1 resolution:** **no** (the `topUpActionBudget` action increments
the signer's own budget).  v2 may add a `topUpActionBudgetFor`
variant for third-party top-ups; the design space includes "must
the recipient consent" questions that are out of scope.

**v1.1 update:** the `depositWithFee` action (NEW v1.1) is
effectively a third-party top-up: the L1 caller pays the fee, the
budget is granted to a (potentially different) L2 `recipient`.
This is the *only* third-party top-up path in v1.1; it inherits
L1-gas-gated cost, so the "must the recipient consent" question
is resolved by "the recipient *implicitly* consented by sharing
their L2 address with the L1 caller."  A pure-L2 third-party
top-up is still out of scope; v2 work.

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
`CanonBridge` and migrating via `CanonMigration` (existing
Workstream-E.5 mechanism).  This is a heavier process than a DAO
vote but provides stronger guarantees: pool participants know
their previously-granted budgets cannot be devalued retroactively
by a governance action.  The `MIN_GRACE_WINDOW_BLOCKS` (per
Workstream H) gives users time to exit before the new rate
becomes effective.

### OQ-GP-10 — Refund-on-exit interaction with v1.1 (v1.1)

How does the v1.1 "user-chosen fee with budget grant" interact
with the deferred GP.9.1 refund-on-exit mechanism?

**v1.1 resolution:** refund-on-exit operates over `poolAmount`
(the fee paid), not over `budgetGrant` (the budget received).
A withdrawing user reclaims a pro-rata portion of their
`poolAmount` based on dwell time, regardless of whether they
spent the budget grant or not.  This is the simpler design;
tying refund to "unused budget remaining" would require tracking
per-deposit budget consumption (linked-list of
`(depositId, remainingBudget)` per actor), which is significant
state-bloat.  The simple "refund based on poolAmount + time"
formulation is sufficient: super-users who paid high fees and
used their budgets get less refund per unit time (they consumed
the service); super-users who paid high fees and *didn't* use
their budgets also get less refund (their fee was the price for
optionality, not for actual consumption).  This is consistent
with prepaid-service economics elsewhere (gym memberships,
cloud-compute reservations).

### OQ-GP-11 — Resource enumeration policy (v1.2)

How should v1.2's hard-coded "ResourceId 0 = ETH, ResourceId 1 =
BOLD" reservation interact with future resources (additional
stablecoins, restaked-ETH derivatives, project-specific tokens)?

**v1.2 resolution:** v1.2 commits exclusively to two resources.
Adding a third gas-pool resource (say USDC at ResourceId 2)
requires a new workstream and a new `CanonBridge` deployment via
`CanonMigration` handoff.  The compile-time pinning of
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

**v1.2 resolution:** **Accept drift; redeploy if needed.**  Both
exchange rates are constructor-immutable per the Workstream-E
discipline.  In practice:
* Short-term drift (months) is absorbed by the
  user-`chosenFeeBps` range: a user can compensate for a 2×
  ETH appreciation by halving their `chosenFeeBps` on the ETH
  leg.  The deployment's `maxFeeBps` should be wide enough
  to allow this (e.g., 5000 ≈ 50%) for resilience.
* Long-term drift (years) is handled by redeploying the
  bridge with re-calibrated parameters via `CanonMigration`.
  This is heavy but matches the existing migration discipline
  for other immutable parameters.
* Alternative: a future v2 amendment could introduce a
  governance-mutable exchange rate (with a multi-day grace
  window before any change activates).  Out of scope for v1.2.

### OQ-GP-13 — BOLD circuit-breaker oracle dependency (v1.2)

The BOLD circuit breaker (GP.5.5) is operator-triggered, but
the operator's trigger condition references an "off-chain
oracle feed" for BOLD/USD price.  How is this oracle chosen
and trusted?

**v1.2 resolution:** **Operator-side responsibility, not
kernel-side.**  The off-chain oracle is part of the operator's
monitoring infrastructure (Chainlink price feed, multi-source
aggregator like Pyth, or in-house feed).  The L1 contract does
NOT trust the oracle directly — there is no on-chain oracle
read.  Instead, the operator's circuit-breaker key (a
multi-sig or similar) calls `closeBoldCircuit()` /
`openBoldCircuit()` based on the operator's reading of the
oracle.

This puts the oracle trust assumption squarely on the operator
rather than the kernel.  Trade-off: the circuit breaker may be
slow (operator response time matters) but is robust against
on-chain oracle manipulation.  Future v2 work could add an
on-chain oracle integration with manipulation-resistant
mechanisms (TWAP from a deep-liquidity pool), but the trade-off
is added complexity for a relatively rare event (BOLD has
never persistently depegged in Liquity v1 LUSD's multi-year
history).

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
           │                                                     │                                   └──► GP.6.2 (canon-host)
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
                                      └──► GP.6.1 (canon-l1-ingest)

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
| 19 | Calibration drift between `weiPerBudgetUnitEth` and `weiPerBudgetUnitBold` due to ETH/USD price movement (v1.2) | n/a | Mitigation: wide `maxFeeBps` (≤ 5000) allows users to compensate by choosing different fees; long-term redeploy via `CanonMigration` if drift becomes structural.  Not a kernel-soundness issue; the kernel proves consistency for whatever values the deployment supplies | OQ-GP-12 resolution: accept drift, redeploy if needed |

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

The plan above is v1.2.  Iteration history:
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

All seven rounds are recorded below.

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
    filter (· ≠ 0)` formulation.

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
    a redeploy via `CanonMigration`.
  * **Stablecoin selection rationale.**  Documented the
    BOLD-vs-USDC trade-off (issuer-freeze risk vs depeg-
    volatility risk); Liquity V2's track record (inherited
    from LUSD's multi-year peg stability) justifies the
    choice for a permissionless rollup architecture.

The v1.2 plan is now consistent, mathematically sound, and
minimal in scope while addressing the full motivating problem:
**stable-USD-denominated gas pricing for L2 users without the
audit-cost and complexity overhead of an embedded AMM**.  The
deferred `Workstream BA` (embedded AMM) remains available as
future work once TVL and volume justify the additional
infrastructure.

---

*End of Workstream GP plan.*

# Knomosis Gas-Pool Migration Guide (Workstream GP)

**Status:** GP.10.4.  How a legacy (pre-GP) Knomosis deployment adopts
the unified gas pool / per-actor budgets / AMM.  Pairs with
`docs/gas_pool_runbook.md` (day-to-day operations) and `abi.md` §10.2
(config + claim wire formats).

> A pre-GP log is **not** silently compatible with a GP-enabled binary —
> by design.  The reserved-actor reservation and the config sidecars
> turn every incompatibility into a *loud, early* failure rather than a
> post-state-hash mismatch.  This guide is the procedure for making the
> two compatible.

---

## 1. What Workstream GP changes

| Surface | Pre-GP | Post-GP |
|---------|--------|---------|
| **Reserved `ActorId`s** | only `bridgeActor = 0` | `+ gasPoolActor = 1`, `sequencerActor = 2`, `ammReserveActor = 3`; first *user* actor is now **4** (`AddressBook.empty.nextActorId = 4`) |
| **`Action` indices** | 0–18 | `+ 19` depositWithFee, `20` topUpActionBudget, `21` topUpActionBudgetFor, `22` claimBudgetRefund, `24` reclaimAmmReserves, `25` reserveSwap (all frozen; 23 is the retired L1-AMM mirror's permanent hole) |
| **Budgets** | none | bounded per-actor per-epoch budget (deny-by-default genesis `.bounded 0 1 0`) |
| **Gas pool** | none | `gasPoolPolicy` governs `gasPoolActor` outflow (capped `transfer` to `sequencerActor` only) |
| **Bridge state** | `consumed`/`pending` | `+` per-deposit `(userAmount, poolAmount, budgetGrant)` split, `+` 3 BOLD mirror fields, `+` `ammDisabled` |

The action-index and reserved-actor sets are **frozen** (pinned by
`addressBook_empty_nextActorId` and the `Action`/`Event` tag regression
tests); they will not move under you.

## 2. Pre-migration audit

1. **Enumerate your user `ActorId`s.**  Any user actor assigned an id in
   the reserved range **`{1, 2, 3}`** must be remapped (§3).  Fresh
   deployments bootstrapped on a current build never hit this — the
   adaptor issues the first user actor `4`.
2. **Inventory deposits.**  Legacy `Action.deposit` records carry
   `userAmount := amount`, `poolAmount = 0`, `budgetGrant = 0` — they
   stay valid; only *new* `depositWithFee` deposits carry a split.
3. **Decide which GP features you are enabling** (budgets / gas pool /
   refund-on-exit / AMM).  Each is opt-in via flags; you can adopt a
   subset.  The AMM + its 3-of-N disaster-recovery multisig
   (`docs/gas_pool_runbook.md` §10) are independent.

## 3. Step 1 — Remap reserved-range user actors

The safety net: the `knomosis-l1-ingest` state-file replay **rejects a
persisted user `ActorId` in `{1,2,3}` loudly** rather than silently
violating the reservation (`INITIAL_NEXT_ACTOR_ID = 4`,
`AMM_RESERVE_ACTOR_ID = 3`).  So a forgotten remap fails closed at
upgrade, not at a fund-moving action.

Procedure (per affected user actor `a ∈ {1,2,3}`):

1. Choose a fresh id `a' ≥ 4` (the next free user id).
2. Re-issue `a`'s identity under `a'` (a `bridgeActor`-signed
   `registerIdentity a' pk`) and migrate `a`'s balances/nonce to `a'`
   in your state before the upgrade.
3. Re-point any off-chain references (address book, indexer views) from
   `a` to `a'`.

After remapping, slots `1`/`2`/`3` belong exclusively to the gas pool,
sequencer, and AMM reserve.

## 4. Step 2 — Wire the GP genesis policies

The reserved actors are inert without their genesis governance.  Supply
the per-leg drain caps; the `knomosis` binary then (a) declares
`gasPoolPolicy` for `gasPoolActor` in the genesis `localPolicies` and
(b) intersects `gasPoolAuthorityPolicy` into the deployment policy (both
halves of the GP.7.4 contract — `abi.md` §10.2.4):

```bash
knomosis ... --gas-pool-eth-cap <ETH_CAP> --gas-pool-bold-cap <BOLD_CAP>
```

Because the genesis `localPolicies` declaration is in every entry's
post-state hash, the caps are **fixed for the life of the log** and the
`<LOG>.gaspoolcfg` sidecar pins them (a forgotten/changed cap on restart
fails with a clear `gas-pool-config error`).

## 5. Step 3 — Configure budgets and (optional) refund-on-exit

GP runs in **bounded-budget** mode; the deny-by-default genesis
(`freeTier = 0`) rejects every action.  A live deployment must set:

  * `freeTier ≥ 1` and `currentEpoch ≥ 1` (per-actor per-epoch headroom);
  * `weiPerBudgetUnit{Eth,Bold} ≥ 1` (budget→gas exchange rate);
  * for refund-on-exit (GP.9.1): `--wei-per-budget-unit-{eth,bold}`
    (the `<LOG>.refundratecfg` sidecar pins these; `abi.md` §10.2.5).

Size these per `docs/economic_incentive_analysis.md` (IC‑4…IC‑6 for the
stake/budget envelope).  All three configs (budget / gas-pool /
refund-rate) are sidecar-pinned and cross-checked before every replay.

## 6. Step 4 — Provision the reserved actors

  * **`gasPoolActor` (1)** — register a key + track its nonce + give it
    `freeTier ≥ 1`, or sequencer reimbursement claims fail closed
    (`docs/gas_pool_runbook.md` §11; the claim itself is `abi.md`
    §10.2.6).
  * **`sequencerActor` (2)** — the sole authorised recipient of pool
    outflow; no special provisioning beyond being the claim target.
  * **`ammReserveActor` (3)** — the L2 pool's reserve key; funded by
    the deposit fee-split's seed leg when the AMM is enabled
    (`ammSeedRatioBps > 0`); otherwise inert.

## 7. Step 5 — Verify the migration

1. **Hash binding (F‑1):** `knomosis hash-check` must exit `0` on the
   production binary (a non-production fallback hash is unsafe for the
   state commitment — `docs/audits/20-…` F‑1).
2. **Config sidecars:** bootstrap the migrated log once; confirm the
   `.budgetcfg` / `.gaspoolcfg` / `.refundratecfg` sidecars are written
   and that a restart with the same flags cross-checks clean.
3. **Replay round-trip:** `knomosis-replay <LOG>` must reproduce the
   final state hash (the canonical audit check).
4. **End-to-end proof:** run `knomosis gas-pool-demo` (the GP.7.4 worked
   deployment) as a reference; then exercise a real deposit → claim →
   replay cycle on a *copy* of the migrated state before going live.

## 8. Rollback & safety

The migration is **fail-closed at every step**: the reserved-range
rejection (§3), the genesis-policy post-state hash (§4), and the three
config sidecars (§5) each turn a mistake into a loud early error.  Keep
the pre-migration log + state immutable until the migrated deployment
has passed §7 on a copy; the original remains replayable by a pre-GP
binary for audit.

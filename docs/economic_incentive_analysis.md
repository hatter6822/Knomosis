# Knomosis — Economic / Incentive Analysis

**Date:** 2026-06-14
**Status:** Workstream P2 deliverable; companion to
`docs/audits/20-production-security-review-and-external-audit-scope.md`
(§4.5 / F-4).  Living document.

> **Scope.**  Knomosis's *safety* properties are mechanised theorems
> (determinism, no-silent-illegality, supply/bridge conservation,
> fault-proof convergence + honest-challenger settlement, etc.).  This
> document analyses the **incentives** those mechanisms create: *given*
> the safety proofs, is **honest behaviour the equilibrium** — i.e. is
> it profitable for honest parties and griefing-resistant against
> dishonest ones?  Mechanism parameters (bonds, stakes, caps, fees) are
> **deployment-immutable constructor values**, so this is a *parametric*
> analysis: it states the conditions a deployment must satisfy for
> incentive-compatibility, not invented numbers.  All mechanism facts
> verified against source on 2026-06-14.

---

## 1. Why safety proofs are not incentive proofs

`honest_challenger_wins_at_termination` proves that an honest challenger
*can always win* against an invalid state root, and
`bisection_converges_after_enough_rounds` bounds the game length.  That
guarantees **safety conditional on someone honest playing**.  It does
**not** establish that anyone *will* play, that playing is profitable,
or that the cost of *defending against frivolous play* is bounded below
the attacker's cost of mounting it.  Those are economic questions, and
they determine whether the safety guarantee is *live* in practice.

## 2. The fault-proof game

**Mechanism (verified — `KnomosisFaultProofGame.sol`).** A challenger
posts `MIN_CHALLENGE_BOND` (immutable) to dispute a state-root claim;
the game bisects with a per-round `BISECTION_RESPONSE_TIMEOUT` and a
`MIN_BISECTION_STEP_INTERVAL_BLOCKS` anti-DoS floor; on resolution the
loser's bond is slashed, with **5 % redistributed to `treasury`** (the
OQ8 resolution) and the remainder to the winner.

**Incentive conditions a deployment must satisfy.**

- **(IC-1) Honest challenging is +EV.**  Let `R` = the winner's share of
  the slashed bond, `G_c` = the challenger's expected L1 gas to play the
  (bounded, `⌈log₂ N⌉`-round) game, `B` = `MIN_CHALLENGE_BOND`.  An
  honest challenger is willing iff `R − G_c ≥ 0` and the at-risk capital
  `B` is recoverable on a win.  Because the honest party *always* wins
  (safety theorem), the win probability is 1, so the binding condition
  is simply `R ≥ G_c`: **the slashed-bond reward must exceed the L1 cost
  of playing.**  Deployments must size `MIN_CHALLENGE_BOND` (and hence
  `R`) against worst-case L1 gas at the target `N` (log-depth) and gas
  price.
- **(IC-2) Frivolous challenging is −EV (griefing deterrence).**  A
  dishonest challenger loses `B` and pays `G_c`; the defender pays `G_d`
  to respond.  Griefing is deterred for the *protocol* iff the attacker
  cannot profit (`B > 0` and the attacker forfeits it) and is bounded
  for the *defender* iff `B`'s slashed share to the defender ≥ `G_d`.
  The `MIN_BISECTION_STEP_INTERVAL_BLOCKS` floor caps the response
  *rate*, bounding the defender's burst cost.
- **(IC-3) Liveness / censorship assumption.**  The whole game presumes
  at least one honest, funded, *watching* party (the
  `knomosis-faultproof-observer` daemon is the reference implementation).
  If no honest party watches within `BISECTION_RESPONSE_TIMEOUT`, an
  invalid root finalises.  This is the standard optimistic-rollup
  watchtower assumption and **must be operationally guaranteed** (run ≥1
  independent observer; see `docs/testnet_readiness.md`).

**Residual economic risk.**  Capital-cost / opportunity-cost of locked
bonds during long disputes; correlated-censorship of the L1 itself
(out of scope — inherited from L1); the 5 % treasury skim must not make
honest challenging −EV at small `R` (re-check IC-1 *after* the skim).

## 3. The dispute pipeline (off-chain adjudication)

**Mechanism (verified — `Disputes/Staking.lean`).** `StakingPolicy`
requires `stakeAmount` (min stake) at `stakeResource` to file; stakes
escrow at `escrowActor` while open and are **forfeited to
`treasuryActor` on rejected / inconclusive verdicts**.  Staking is
disablable (`stakeAmount = 0`).

**Incentive conditions.**

- **(IC-4) Honest filing is +EV** iff the value of a correct verdict to
  the filer (reward, or harm-averted) ≥ `stakeAmount` × P(inconclusive)
  + filing cost.  A deployment that sets `stakeAmount` too high
  suppresses honest filing (chilling); too low invites spam.
- **(IC-5) False filing is deterred** iff `stakeAmount` (forfeited) ≥
  the attacker's expected gain from a spurious dispute + the
  adjudicator's processing cost.

**Recommendation.**  `stakeAmount` is the single most sensitivity-prone
parameter (it gates *both* spam-resistance and honest-access).
Deployments should calibrate it to the *resource's* value, and revisit
it as price moves (it is immutable per deployment — a migration is
required to change it).

## 4. The gas pool & sequencer reimbursement

**Mechanism (verified — `GasPoolPolicy.lean`, GP.7.3).** Pool outflow is
capped per action (`maxDrainPerAction{Eth,Bold}`) to `sequencerActor`
only, and `pool_drain_bounded_by_action_count` proves the leg-`r`
balance falls by ≤ `n × legCap` across `n` admitted claims.  The v1
reimbursement is **honour-system**: `amount` is *not* proven to equal
real L1 gas spent (§2.9 of the GP.8 plan).

**Incentive analysis.**

- The **absolute loss is bounded** (per action by the cap, per trace by
  GP.7.3) regardless of operator honesty — this is the load-bearing
  protection and it is *proven*.
- A fully-malicious sequencer can claim up-to-cap every epoch
  irrespective of real spend; this is accepted because (i) the cap
  bounds it, (ii) the sequencer is *already* trusted for liveness (it
  can censor/stall regardless), and (iii) the dispute pipeline can
  challenge sustained over-claims.  **The reimbursement adds no new
  trust beyond the liveness trust already placed in the sequencer.**
- **(IC-6)** A deployment should size `maxDrainPerAction` and the claim
  frequency (`gasPoolActor`'s per-epoch budget) so that the *honest*
  reimbursement clears but the *worst-case* over-claim is an acceptable
  loss for the epoch.  The v2 path (GP.8.5, receipt-verified) removes
  the honour-system gap and should be prioritised before the pool holds
  significant value.

## 5. The AMM & disaster recovery

- **No extraction beyond fees.**  The L2 AMM is constant-product; the
  reserve actor's balances move *only* via `ammSwap` while live
  (`ammReservePolicy`, GP.11.6) — there is no path for an operator to
  withdraw reserves except the fee accrual and the post-disaster sweep.
- **The kill switch is a circuit breaker, not an extraction vector.**
  `ammDisabled` (committed to the state root) is set only by the
  **3-of-N** `KnomosisAmmDisasterRecoveryMultisig` (constructor-enforced
  `MIN_DISABLE_THRESHOLD = 3`); only *after* it fires can
  `reclaimAmmReserves` sweep reserves, and only to the canonical
  reserved actors.  Incentive: a single compromised signer cannot
  trigger recovery; the 7-day group-expiry bounds a stale-quorum attack.
  Deployments must choose `N` and the signer set so collusion of 3 is
  costlier than the reserve value.
- **BOLD circuit breaker + TVL cap** bound the protocol's exposure to a
  single bridged asset; the **user picks the fee** (`MIN_FEE_BPS ≤ fee ≤
  MAX_FEE_BPS`), so the *deployer* cannot extract via a high default and
  a malicious *user* paying a high fee only gifts the sequencer.

## 6. Cross-cutting economic risks & recommendations

| # | Risk | Status / recommendation |
|---|------|--------------------------|
| E-1 | **Parameter sizing is a deployment responsibility, not a proof.** Bonds, stakes, caps, fees are immutable constructor values; incentive-compatibility (IC-1…IC-6) depends entirely on choosing them correctly. | The IC-conditions above are the parameterisation guide; the **calibration harness is shipped** — `scripts/economic_simulation.py` turns IC-1…IC-6 into a swept numeric envelope (min incentive-compatible bond per depth × gas price, anti-spam stake floor, v1-vs-v2 pool over-payment). |
| E-2 | **Single-sequencer trust** for liveness + the honour-system reimbursement. | Inherent to the v1 design; the fault-proof game bounds *safety* loss; decentralised sequencing (multi-sequencer, OQ-H-2) and v2 receipt-verified claims (GP.8.5) are the de-trusting path. |
| E-3 | **Watchtower liveness** (IC-3) — safety degrades to "honest party must watch in time". | Operationally guarantee ≥1 independent observer; monitor `BISECTION_RESPONSE_TIMEOUT` headroom. |
| E-4 | **MEV / ordering.**  The sequencer orders L2 actions; the fair-queuing scheduler (FQ/GP.8 Track A) bounds *burst-starvation*, not value-extractive reordering. | Out of scope for the safety proofs; analyse per-deployment; document the ordering policy. |
| E-5 | **No formal mechanism-design proof.**  IC-1…IC-6 are argued, not mechanised. | **Quantified** by `scripts/economic_simulation.py`: a deterministic simulation of the fault-proof game + dispute staking + gas pool, with a sensitivity sweep over (bond, trace-depth, gas-price) and `--assert` invariant checks (a green run confirms IC-1/IC-2/IC-5/IC-6 hold across the grid).  Not a *mechanised* proof (it is a numeric model, not a Lean theorem), but it removes the "invented numbers" gap E-1 warned of and is CI-runnable. |

**Bottom line.**  The *safety* economics are sound and proven-bounded
(loss is capped regardless of adversary behaviour).  The *liveness*
economics reduce to standard optimistic-rollup assumptions (a funded,
watching honest party) plus correct deployment-time parameter sizing.
The two concrete pre-value priorities are now both addressed: **(a)** the
deployment parameter envelope encoding IC-1…IC-6 is quantified by
`scripts/economic_simulation.py` (run it against your target gas price /
trace depth to size bonds, stakes, and caps), and **(b)** the v2
receipt-verified reimbursement (GP.8.5, `LegalKernel.Bridge.ReceiptVerifiedClaim`)
is shipped — prioritise *enabling* it before the gas pool holds material
value.

## 7. Quantitative companion

`scripts/economic_simulation.py` is the numeric counterpart to this
document.  It models the three mechanisms above, sweeps the
deployment-immutable parameters, and prints markdown tables (min
incentive-compatible bond per trace-depth × gas-price; the anti-spam
stake floor; the v1-honour-system vs v2-receipt-verified pool
over-payment).  Run with no arguments to also `--assert` that IC-1 /
IC-2 / IC-5 / IC-6 hold across the swept grid (non-zero exit on any
violation).  A representative result: at 50 gwei and a depth-2²⁰ trace,
the min incentive-compatible challenge bond is ≈ 0.115 ETH; the v2 gate
removes up to ~90 % of the v1 worst-case pool over-payment when the
sequencer's real L1 spend is a small fraction of the per-action cap.

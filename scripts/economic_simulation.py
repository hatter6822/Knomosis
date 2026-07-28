#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See:
#   https://github.com/hatter6822/Knomosis/blob/main/LICENSE
"""
Knomosis economic / incentive simulation (Workstream P2).

Turns the *qualitative* incentive conditions IC-1 … IC-6 of
`docs/economic_incentive_analysis.md` into a *quantitative* harness:
it models the fault-proof game, the dispute-staking pipeline, and the
gas-pool reimbursement numerically, sweeps the deployment-immutable
parameters (challenge bond, gas price, trace depth, stake, drain cap),
and prints the incentive-compatible envelope as markdown tables.

This is the "calibration tool / simulation harness" E-1 asks for and
the "agent-based simulation + sensitivity analysis over (bond, timeout,
gas-price)" E-5 lists as the follow-up to the qualitative analysis.

It is ALSO a check: `--assert` (the default) verifies the headline
incentive invariants hold across the swept grid and exits non-zero if
any is violated --- so a green run is a quantitative confirmation that
the analysis's claims are internally consistent.  No numbers here are
"the" deployment parameters (those are immutable per deployment); the
output is the *envelope* a deployment must sit inside.

Pure stdlib; deterministic; no external dependencies.

Usage:
  scripts/economic_simulation.py            # print report + assert invariants
  scripts/economic_simulation.py --no-assert  # report only (never fails)

Exit codes:
  0  report printed and (unless --no-assert) every IC invariant held
  1  an IC invariant was violated in the swept grid
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass

# --------------------------------------------------------------------------
# Cost model constants (order-of-magnitude EVM gas figures; the ENVELOPE,
# not a deployment's exact calibration).  A deployment recomputes these
# from its own contracts' gas snapshot (`solidity/.../BenchmarkGas*`).
# --------------------------------------------------------------------------

GAS_OPEN_CHALLENGE = 150_000   # post bond + open the game
GAS_BISECT_ROUND = 80_000      # one bisection step (per round, per party)
GAS_SINGLE_STEP_VERIFY = 350_000  # terminal single-step / SMT cell verify
TREASURY_SKIM = 0.05           # OQ8: 5% of the slashed bond -> treasury
WINNER_SHARE = 1.0 - TREASURY_SKIM  # the winner's share of the slashed bond

ETH_USD = 3_000.0              # reference; sweeps are gas-price driven
GWEI = 1e-9                    # 1 gwei in ETH


def usd(eth: float) -> float:
    return eth * ETH_USD


def gas_cost_eth(gas: int, gas_price_gwei: float) -> float:
    """Convert a gas amount at a gas price (gwei) to ETH."""
    return gas * gas_price_gwei * GWEI


# --------------------------------------------------------------------------
# Fault-proof game (IC-1 honest +EV, IC-2 griefing deterrence, IC-3 liveness)
# --------------------------------------------------------------------------

@dataclass
class GameOutcome:
    rounds: int
    challenger_gas: int
    defender_gas: int
    challenger_cost_eth: float
    defender_cost_eth: float
    reward_eth: float          # winner's share of the slashed bond
    honest_net_eth: float      # honest challenger net on a (certain) win
    frivolous_net_eth: float   # dishonest challenger net on a (certain) loss
    defender_net_eth: float    # honest defender's net vs a frivolous challenge
    ic1_ok: bool               # honest challenging is +EV (R >= G_c)
    ic2_attacker_ok: bool      # frivolous challenging is -EV for the attacker
    ic2_defender_ok: bool      # defender's recovered share covers its gas


def simulate_game(trace_steps: int, bond_eth: float, gas_price_gwei: float) -> GameOutcome:
    """Model one fault-proof game to resolution.

    The honest party ALWAYS wins (safety theorem
    `honest_challenger_wins_at_termination`), so win probability is 1
    and the binding economic conditions are the deterministic
    cost/reward comparisons below.
    """
    rounds = max(1, math.ceil(math.log2(max(2, trace_steps))))
    # Challenger: open + one bisection move per round + the terminal verify.
    challenger_gas = GAS_OPEN_CHALLENGE + rounds * GAS_BISECT_ROUND + GAS_SINGLE_STEP_VERIFY
    # Defender: one bisection response per round.
    defender_gas = rounds * GAS_BISECT_ROUND

    challenger_cost = gas_cost_eth(challenger_gas, gas_price_gwei)
    defender_cost = gas_cost_eth(defender_gas, gas_price_gwei)
    reward = WINNER_SHARE * bond_eth

    # Honest challenger wins: bond returned, plus the winner's share of the
    # loser's slashed bond, minus the gas played.
    honest_net = reward - challenger_cost
    # Dishonest (frivolous) challenger loses: forfeits its whole bond and
    # still pays its gas.
    frivolous_net = -(bond_eth + challenger_cost)
    # Honest defender beating a frivolous challenger: collects the winner's
    # share of the forfeited bond, minus its own response gas.
    defender_net = reward - defender_cost

    return GameOutcome(
        rounds=rounds,
        challenger_gas=challenger_gas,
        defender_gas=defender_gas,
        challenger_cost_eth=challenger_cost,
        defender_cost_eth=defender_cost,
        reward_eth=reward,
        honest_net_eth=honest_net,
        frivolous_net_eth=frivolous_net,
        defender_net_eth=defender_net,
        ic1_ok=honest_net >= 0.0,
        ic2_attacker_ok=frivolous_net < 0.0,
        ic2_defender_ok=defender_net >= 0.0,
    )


def min_incentive_compatible_bond(
    trace_steps: int, gas_price_gwei: float, step_eth: float = 0.005
) -> float:
    """Smallest bond (rounded up to `step_eth`) making the game IC-1 AND
    IC-2-defender compatible at this depth + gas price."""
    bond = step_eth
    # Cap the search so a pathological config terminates loudly.
    while bond <= 100.0:
        out = simulate_game(trace_steps, bond, gas_price_gwei)
        if out.ic1_ok and out.ic2_defender_ok and out.ic2_attacker_ok:
            return bond
        bond += step_eth
    return float("inf")


# --------------------------------------------------------------------------
# Dispute staking (IC-4 honest filing +EV, IC-5 false filing deterred)
# --------------------------------------------------------------------------

def min_anti_spam_stake(
    attacker_gain_eth: float, adjudicator_cost_eth: float, p_inconclusive: float
) -> float:
    """IC-5: the stake forfeited on a rejected/inconclusive verdict must
    exceed the attacker's expected spurious gain plus the adjudicator's
    processing cost, discounted by the probability the attack reaches an
    inconclusive (stake-forfeiting) verdict."""
    if p_inconclusive <= 0.0:
        return float("inf")
    return (attacker_gain_eth + adjudicator_cost_eth) / p_inconclusive


# --------------------------------------------------------------------------
# Gas pool reimbursement (IC-6: v1 honour-system vs v2 receipt-verified)
# --------------------------------------------------------------------------

@dataclass
class PoolOutcome:
    v1_worst_per_epoch_eth: float    # max over-claim: cap on every claim
    v2_worst_per_epoch_eth: float    # min(cap, real spend) on every claim
    v1_worst_over_horizon_eth: float
    v2_worst_over_horizon_eth: float
    v2_savings_eth: float
    v2_le_v1: bool                   # the proven strengthening, numerically


def simulate_pool(
    cap_eth: float,
    claims_per_epoch: int,
    epochs: int,
    real_spend_fraction: float,
) -> PoolOutcome:
    """v1 worst case: a malicious sequencer claims the FULL cap on every
    claim regardless of real spend.  v2 worst case: the receipt gate caps
    each claim at `min(cap, real_spend)`, so the over-claim is removed ---
    `receiptVerifiedClaim_capped_and_backed` bounds it by the wei actually
    paid (here modelled as `real_spend_fraction * cap`)."""
    real_spend = min(cap_eth, real_spend_fraction * cap_eth)
    v1_epoch = cap_eth * claims_per_epoch
    v2_epoch = real_spend * claims_per_epoch
    v1_horizon = v1_epoch * epochs
    v2_horizon = v2_epoch * epochs
    return PoolOutcome(
        v1_worst_per_epoch_eth=v1_epoch,
        v2_worst_per_epoch_eth=v2_epoch,
        v1_worst_over_horizon_eth=v1_horizon,
        v2_worst_over_horizon_eth=v2_horizon,
        v2_savings_eth=v1_horizon - v2_horizon,
        v2_le_v1=v2_horizon <= v1_horizon,
    )


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

# Acceptability ceilings and margins.  These are the INDEPENDENT
# yardsticks the invariant checks measure against — deliberately not
# derived from the model, so a green run reports that the model's
# outputs land inside an operator-acceptable envelope rather than
# merely that the model agrees with itself.
MAX_DEPLOYABLE_BOND_ETH = 5.0      # a bond above this is not postable in practice
MIN_DETERRENCE_FRACTION = 0.25     # a frivolous challenger must lose >= 25% of its bond
MAX_DEPLOYABLE_STAKE_ETH = 50.0    # a dispute stake above this closes the pipeline
MIN_STAKE_MULTIPLE = 1.5           # the stake must exceed the attacker gain by 1.5x

GAS_PRICES = [5.0, 20.0, 50.0, 100.0]      # gwei
TRACE_DEPTHS = [256, 4_096, 65_536, 1_048_576]
BONDS = [0.01, 0.05, 0.1, 0.5, 1.0]        # ETH


def fmt_eth(x: float) -> str:
    return f"{x:.4f}"


def section_fault_proof() -> bool:
    ok = True
    print("## 2. Fault-proof game (IC-1 / IC-2 / IC-3)\n")
    print("**Challenger L1 gas cost vs the winner's reward share "
          f"(WINNER_SHARE = {WINNER_SHARE:.2f}, after the {int(TREASURY_SKIM*100)}% "
          "treasury skim).**\n")
    print("Min incentive-compatible bond `B` (ETH) such that IC-1 "
          "(`R ≥ G_c`), IC-2-attacker (`frivolous < 0`), and IC-2-defender "
          "(`0.95·B ≥ G_d`) ALL hold:\n")
    header = "| trace steps N | rounds | " + " | ".join(f"{g:g} gwei" for g in GAS_PRICES) + " |"
    print(header)
    print("|" + "---|" * (2 + len(GAS_PRICES)))
    for n in TRACE_DEPTHS:
        rounds = max(1, math.ceil(math.log2(n)))
        cells = []
        for gp in GAS_PRICES:
            b = min_incentive_compatible_bond(n, gp)
            cells.append(f"{b:.3f} (${usd(b):,.0f})")
        print(f"| {n:,} | {rounds} | " + " | ".join(cells) + " |")
    print()

    # Worked example + IC assertions at a representative operating point.
    print("**Worked example** — N = 65 536 (16 rounds), B = 0.1 ETH:\n")
    print("| gas price | challenger G_c | reward R (0.95·B) | honest net | "
          "frivolous net | defender net |")
    print("|---|---|---|---|---|---|")
    for gp in GAS_PRICES:
        out = simulate_game(65_536, 0.1, gp)
        print(f"| {gp:g} gwei | {fmt_eth(out.challenger_cost_eth)} | "
              f"{fmt_eth(out.reward_eth)} | {fmt_eth(out.honest_net_eth)} | "
              f"{fmt_eth(out.frivolous_net_eth)} | {fmt_eth(out.defender_net_eth)} |")
    print()

    # Invariants over the WHOLE grid.
    #
    # These are deliberately NOT re-derivations of the search's own exit
    # condition.  `min_incentive_compatible_bond` returns the first bond
    # at which `ic1_ok and ic2_defender_ok and ic2_attacker_ok` holds, so
    # re-simulating at that bond and asserting `ic2_attacker_ok` — which
    # is what this block used to do — is true by construction and would
    # stay green under any model, including a broken one.  Each check
    # below can fail for a real reason.
    prev_bond_by_depth: dict[int, float] = {}
    for n in TRACE_DEPTHS:
        for gp in GAS_PRICES:
            b = min_incentive_compatible_bond(n, gp)
            if not math.isfinite(b):
                print(f"  !! IC VIOLATION: no IC-compatible bond at N={n}, {gp} gwei")
                ok = False
                continue

            # (1) DEPLOYABILITY CEILING.  An IC-compatible bond that no
            # operator would post is not a usable parameter.  A bond
            # above this is a modelling result worth failing on, not a
            # success.
            if b > MAX_DEPLOYABLE_BOND_ETH:
                print(f"  !! BOND UNDEPLOYABLE: {b:.3f} ETH > "
                      f"{MAX_DEPLOYABLE_BOND_ETH} ETH ceiling at N={n}, {gp} gwei")
                ok = False

            out = simulate_game(n, b, gp)

            # (2) DETERRENCE HEADROOM.  `ic2_attacker_ok` only asks that
            # the frivolous attacker's net be non-positive.  A margin of
            # a few wei is not a deterrent; require the loss to be a
            # meaningful fraction of the bond the attacker posted.
            required_loss = MIN_DETERRENCE_FRACTION * b
            if -out.frivolous_net_eth < required_loss:
                print(f"  !! DETERRENCE TOO THIN: frivolous net "
                      f"{out.frivolous_net_eth:+.4f} ETH, needed a loss of at "
                      f"least {required_loss:.4f} ETH at N={n}, {gp} gwei")
                ok = False

            # (3) HONEST-PARTY MARGIN.  The honest challenger must not
            # merely beat the attacker, it must come out ahead in
            # absolute terms — otherwise nobody challenges and the game
            # is never played.
            if out.honest_net_eth <= 0.0:
                print(f"  !! HONEST CHALLENGE NOT PROFITABLE: "
                      f"{out.honest_net_eth:+.4f} ETH at N={n}, {gp} gwei")
                ok = False

            # (4) MONOTONICITY IN GAS PRICE.  Gas is the challenger's
            # cost, so the bond required to keep the game IC-compatible
            # must not DECREASE as gas gets more expensive.  A violation
            # means the cost model is inverted somewhere — a genuine bug
            # signal that no pass/fail re-derivation would surface.
            prev = prev_bond_by_depth.get(n)
            if prev is not None and b < prev - 1e-12:
                print(f"  !! NON-MONOTONE IN GAS: bond fell from {prev:.3f} to "
                      f"{b:.3f} ETH at N={n} when gas rose to {gp} gwei")
                ok = False
            prev_bond_by_depth[n] = b

    print(f"_IC-1/IC-2 invariants over the {len(TRACE_DEPTHS)}×{len(GAS_PRICES)} "
          f"grid: {'HELD' if ok else 'VIOLATED'}._\n")
    print(f"_Checked: deployability (bond ≤ {MAX_DEPLOYABLE_BOND_ETH} ETH), "
          f"deterrence headroom (≥ {MIN_DETERRENCE_FRACTION:.0%} of bond), "
          f"honest-party profitability, and monotonicity in gas price._\n")
    return ok


def section_staking() -> bool:
    ok = True
    print("## 3. Dispute staking (IC-4 / IC-5)\n")
    print("Min anti-spam `stakeAmount` (ETH) = "
          "`(attacker_gain + adjudicator_cost) / P(inconclusive)`:\n")
    print("| attacker gain | adjudicator cost | P(inconclusive) | min stake |")
    print("|---|---|---|---|")
    scenarios = [
        (0.05, 0.01, 0.10),
        (0.5, 0.02, 0.10),
        (0.5, 0.02, 0.50),
        (2.0, 0.05, 0.25),
    ]
    for gain, adj, p in scenarios:
        s = min_anti_spam_stake(gain, adj, p)
        print(f"| {gain:g} ETH | {adj:g} ETH | {p:.2f} | {s:.3f} ETH (${usd(s):,.0f}) |")
        # `min_anti_spam_stake` returns `(gain + adj) / p` with
        # `0 < p <= 1` and `adj > 0`, so `s > gain` is arithmetically
        # forced — asserting it checked nothing.  These do:
        if not math.isfinite(s):
            print("  !! IC-5 VIOLATION: no finite anti-spam stake")
            ok = False
            continue
        # (1) DETERRENCE MULTIPLE.  Exceeding the gain by an epsilon is
        # not a deterrent under any uncertainty in the gain estimate.
        if s < MIN_STAKE_MULTIPLE * gain:
            print(f"  !! IC-5 TOO THIN: stake {s:.3f} ETH is under "
                  f"{MIN_STAKE_MULTIPLE}x the {gain:g} ETH attacker gain")
            ok = False
        # (2) USABILITY CEILING.  A stake nobody can post closes the
        # dispute pipeline to honest challengers, which is a liveness
        # failure dressed as a security parameter.
        if s > MAX_DEPLOYABLE_STAKE_ETH:
            print(f"  !! IC-5 UNDEPLOYABLE: stake {s:.3f} ETH exceeds the "
                  f"{MAX_DEPLOYABLE_STAKE_ETH} ETH usability ceiling")
            ok = False
    print()
    print("_Note: `stakeAmount = 0` disables staking (open filing); the "
          "table is the floor for a value-bearing deployment._\n")
    print(f"_IC-5 invariant (stake > attacker gain): "
          f"{'HELD' if ok else 'VIOLATED'}._\n")
    return ok


def section_gas_pool() -> bool:
    ok = True
    print("## 4. Gas-pool reimbursement (IC-6: v1 honour-system vs v2 receipt-verified)\n")
    print("Worst-case pool over-payment over a 30-epoch horizon, 4 claims/epoch, "
          "ETH-leg cap = 0.2 ETH, by the sequencer's real-spend fraction of the cap:\n")
    print("| real spend / cap | v1 worst (cap every claim) | v2 worst (min(cap,spend)) | "
          "v2 saving | v2 ≤ v1 |")
    print("|---|---|---|---|---|")
    for frac in [1.0, 0.75, 0.5, 0.25, 0.1]:
        po = simulate_pool(cap_eth=0.2, claims_per_epoch=4, epochs=30, real_spend_fraction=frac)
        print(f"| {frac:.0%} | {fmt_eth(po.v1_worst_over_horizon_eth)} ETH | "
              f"{fmt_eth(po.v2_worst_over_horizon_eth)} ETH | "
              f"{fmt_eth(po.v2_savings_eth)} ETH | {'yes' if po.v2_le_v1 else 'NO'} |")
        if not po.v2_le_v1:
            print("  !! IC-6 VIOLATION: v2 worst case exceeds v1")
            ok = False
    print()
    print("The v1 worst case is the *proven* per-trace drain bound "
          "(`pool_drain_bounded_by_action_count`: ≤ n·cap).  The v2 column is "
          "`receiptVerifiedClaim_capped_and_backed` made numeric: each claim is "
          "additionally bounded by the real L1 wei cost, so the honour-system "
          "gap (the difference between the two columns) is removed.\n")
    print(f"_IC-6 invariant (v2 ≤ v1 worst case, for every spend fraction): "
          f"{'HELD' if ok else 'VIOLATED'}._\n")
    return ok


def main() -> int:
    do_assert = "--no-assert" not in sys.argv[1:]
    print("# Knomosis — Quantitative Economic Simulation\n")
    print("> Generated by `scripts/economic_simulation.py`.  Companion to "
          "`docs/economic_incentive_analysis.md` (turns IC-1…IC-6 into "
          "numbers + a swept envelope).  Figures are order-of-magnitude "
          "ENVELOPES, not a deployment's exact immutable parameters.\n")
    print(f"Cost model: open={GAS_OPEN_CHALLENGE:,} gas, "
          f"bisect/round={GAS_BISECT_ROUND:,} gas, "
          f"single-step verify={GAS_SINGLE_STEP_VERIFY:,} gas, "
          f"ETH=${ETH_USD:,.0f}, treasury skim={int(TREASURY_SKIM*100)}%.\n")

    results = [section_fault_proof(), section_staking(), section_gas_pool()]
    all_ok = all(results)

    print("## Summary\n")
    print(f"- IC-1/IC-2 (fault-proof game): {'PASS' if results[0] else 'FAIL'}")
    print(f"- IC-5 (dispute staking floor): {'PASS' if results[1] else 'FAIL'}")
    print(f"- IC-6 (gas-pool v2 ≤ v1):      {'PASS' if results[2] else 'FAIL'}")
    print()

    if do_assert and not all_ok:
        print("ECONOMIC SIMULATION: at least one IC invariant was VIOLATED.",
              file=sys.stderr)
        return 1
    print("Economic simulation complete"
          + ("; all IC invariants held." if all_ok else " (--no-assert)."))
    return 0


if __name__ == "__main__":
    sys.exit(main())

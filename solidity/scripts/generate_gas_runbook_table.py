#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
"""Workstream GP.11.9 — generate the runbook gas-economics table.

Derives the operator-facing baseline table in
``docs/gas_pool_runbook.md`` §9.2 mechanically from the committed gas
baseline (``solidity/test/BenchmarkGasV1_3.gas-baseline.json``), and
rewrites the region between the BEGIN/END markers in place.  This is the
same derived-artifact discipline as ``scripts/regenerate_codemaps.py``:
the numbers in the documentation can never drift from the measured
baseline, because

* ``make snapshot-gas`` regenerates the baseline AND this table together,
* ``make snapshot-gas-check`` (the CI gate) runs ``--check``, which fails
  if the committed runbook section differs from what the committed
  baseline generates.

Per-row model (all inputs measured, none hand-maintained)::

    est. user tx  =  execution gas            (vm.snapshotGasLastCall)
                   + 21 000                    (intrinsic transaction cost)
                   + calldata gas              (<name>.calldata_gas entry —
                                                exact EIP-2028 byte cost of
                                                the canonical calldata)
    usd           =  est. user tx x 30 gwei x $3 000/ETH

The row list below is the single place a new benchmark gets its
operator-facing label; the script FAILS if the baseline and the row list
ever disagree (an entry without a label, or a label without an entry), so
adding a benchmark without documenting it cannot pass CI.

``--selftest`` proves the generate / check / drift behaviours on
synthetic fixtures in a temporary directory.

Pure Python 3 stdlib; no third-party imports.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

PROG = "generate_gas_runbook_table"

SOLIDITY_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SOLIDITY_ROOT.parent

DEFAULT_BASELINE = SOLIDITY_ROOT / "test/BenchmarkGasV1_3.gas-baseline.json"
DEFAULT_RUNBOOK = REPO_ROOT / "docs/gas_pool_runbook.md"

BEGIN_MARKER = (
    "<!-- BEGIN GP.11.9 GENERATED BASELINE TABLE "
    "(regenerate: cd solidity && make snapshot-gas) -->"
)
END_MARKER = "<!-- END GP.11.9 GENERATED BASELINE TABLE -->"

# The $-cost reference model.  21 000 is the EIP-2 intrinsic transaction
# cost; the price points are the runbook's worked-example references.
INTRINSIC_TX_GAS = 21_000
REF_GAS_PRICE_GWEI = 30
REF_ETH_USD = 3_000

# Ordered (baseline entry, operator-facing label) rows.  Wired/unwired and
# exact/infinite variants sit adjacent so their deltas read directly off
# the table.
ROWS: list[tuple[str, str]] = [
    ("depositETH_reference", "`depositETH` (v1.0 reference, first deposit)"),
    ("depositETHWithFee_firstDeposit", "`depositETHWithFee` (first deposit)"),
    ("depositETHWithFee_repeatDeposit", "`depositETHWithFee` (repeat deposit)"),
    (
        "depositETHWithFee_repeat_migrationWired",
        "`depositETHWithFee` (repeat, migration-wired bridge)",
    ),
    ("depositBoldWithFee_firstDeposit", "`depositBoldWithFee` (first deposit)"),
    ("depositBoldWithFee_repeatDeposit", "`depositBoldWithFee` (repeat deposit)"),
    ("boldApprove_fresh", "BOLD `approve` (prerequisite, fresh allowance)"),
    (
        "ammSwap_ethToBold_firstBoldRecipient",
        "`ammSwap` ETH→BOLD (first-ever BOLD recipient)",
    ),
    ("ammSwap_ethToBold_repeatRecipient", "`ammSwap` ETH→BOLD (repeat recipient)"),
    (
        "ammSwap_ethToBold_repeat_migrationWired",
        "`ammSwap` ETH→BOLD (repeat, migration-wired bridge)",
    ),
    ("ammSwap_boldToEth_exactApproval", "`ammSwap` BOLD→ETH (exact approval)"),
    ("ammSwap_boldToEth_infiniteApproval", "`ammSwap` BOLD→ETH (infinite approval)"),
    ("withdrawWithProof_eth", "`withdrawWithProof` ETH (canonical 64-sibling proof)"),
    ("withdrawWithProof_bold", "`withdrawWithProof` BOLD (canonical 64-sibling proof)"),
    ("closeBoldCircuit", "`closeBoldCircuit`"),
    ("openBoldCircuit", "`openBoldCircuit`"),
    ("setBoldTvlCap", "`setBoldTvlCap`"),
    ("emergencyDisableAmm", "`emergencyDisableAmm`"),
    ("autoTriggerClose_firstBranch", "Auto-trigger close (first branch, ETH, in shutdown)"),
    ("autoTriggerClose_lastBranch", "Auto-trigger close (last branch, rETH, in shutdown)"),
    ("autoTriggerProbe_noShutdown", "Auto-trigger probe (no shutdown — reverts)"),
]


def load_baseline(path: Path) -> dict[str, int]:
    """Load the baseline JSON ({name: "gas-as-string"})."""
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError:
        raise SystemExit(f"{PROG}: FAIL — baseline not found: {path}")
    except json.JSONDecodeError as e:
        raise SystemExit(f"{PROG}: FAIL — {path} is not valid JSON: {e}")
    return {k: int(v) for k, v in raw.items()}


def validate_rows(baseline: dict[str, int]) -> None:
    """The row list and the baseline must describe the same benchmark set."""
    row_keys = {k for k, _ in ROWS}
    expected = row_keys | {f"{k}.calldata_gas" for k in row_keys}
    missing = sorted(expected - set(baseline))
    extra = sorted(set(baseline) - expected)
    problems = []
    if missing:
        problems.append(f"baseline is missing entries for labelled rows: {missing}")
    if extra:
        problems.append(
            f"baseline has entries with no labelled row (add them to ROWS in "
            f"{Path(__file__).name}): {extra}"
        )
    if problems:
        raise SystemExit(f"{PROG}: FAIL — " + "; ".join(problems))


def fmt_gas(v: int) -> str:
    """Thousands-separated with thin spaces, runbook style: 47 857."""
    return f"{v:,}".replace(",", " ")


def render_table(baseline: dict[str, int]) -> str:
    """Render the generated runbook region (markers excluded)."""
    lines = [
        "*This table is generated from the committed baseline "
        "`solidity/test/BenchmarkGasV1_3.gas-baseline.json` by "
        "`solidity/scripts/generate_gas_runbook_table.py`; edit neither by "
        "hand.  Model: est. user tx = execution + "
        f"{fmt_gas(INTRINSIC_TX_GAS)} intrinsic + calldata; $ at "
        f"{REF_GAS_PRICE_GWEI} gwei and ${fmt_gas(REF_ETH_USD)}/ETH.*",
        "",
        "| Operation (scenario) | Execution (gas) | Calldata (gas) "
        "| Est. user tx | $ @ 30 gwei, $3k/ETH |",
        "|---|---:|---:|---:|---:|",
    ]
    for key, label in ROWS:
        execution = baseline[key]
        calldata = baseline[f"{key}.calldata_gas"]
        est = execution + INTRINSIC_TX_GAS + calldata
        usd = est * REF_GAS_PRICE_GWEI * REF_ETH_USD * 1e-9
        lines.append(
            f"| {label} | {fmt_gas(execution)} | {fmt_gas(calldata)} "
            f"| ~{round(est / 1000)}k | ~${usd:.1f} |"
        )
    return "\n".join(lines)


def splice(runbook_text: str, generated: str, runbook_path: Path) -> str:
    """Replace the region between the markers with ``generated``."""
    if runbook_text.count(BEGIN_MARKER) != 1 or runbook_text.count(END_MARKER) != 1:
        raise SystemExit(
            f"{PROG}: FAIL — {runbook_path} must contain exactly one "
            f"BEGIN/END marker pair:\n  {BEGIN_MARKER}\n  {END_MARKER}"
        )
    head, rest = runbook_text.split(BEGIN_MARKER, 1)
    _, tail = rest.split(END_MARKER, 1)
    return head + BEGIN_MARKER + "\n" + generated + "\n" + END_MARKER + tail


def run(baseline_path: Path, runbook_path: Path, check: bool) -> int:
    baseline = load_baseline(baseline_path)
    validate_rows(baseline)
    generated = render_table(baseline)
    current = runbook_path.read_text()
    updated = splice(current, generated, runbook_path)
    if check:
        if updated != current:
            print(
                f"{PROG}: FAIL — the generated table in {runbook_path} is out "
                f"of sync with {baseline_path}; run `make snapshot-gas` (or "
                f"`python3 scripts/{Path(__file__).name}`) and commit the result"
            )
            return 1
        print(f"{PROG}: PASS — runbook table in sync with the baseline ({len(ROWS)} rows)")
        return 0
    if updated == current:
        print(f"{PROG}: runbook table already up to date ({len(ROWS)} rows)")
    else:
        runbook_path.write_text(updated)
        print(f"{PROG}: rewrote the generated table in {runbook_path} ({len(ROWS)} rows)")
    return 0


def run_selftest() -> int:
    """Prove generate / check / drift / validation behaviours."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        baseline_path = tmp / "baseline.json"
        runbook_path = tmp / "runbook.md"

        synthetic = {}
        for i, (key, _) in enumerate(ROWS):
            synthetic[key] = str(10_000 + i * 1_000)
            synthetic[f"{key}.calldata_gas"] = str(100 + i)
        baseline_path.write_text(json.dumps(synthetic))
        runbook_path.write_text(
            "prefix\n" + BEGIN_MARKER + "\nstale\n" + END_MARKER + "\nsuffix\n"
        )

        checks: list[tuple[str, bool]] = []

        # 1. --check on a stale runbook fails.
        checks.append(("stale runbook fails --check", run(baseline_path, runbook_path, True) == 1))
        # 2. Generation rewrites the region; prose preserved.
        run(baseline_path, runbook_path, False)
        text = runbook_path.read_text()
        checks.append(("generation keeps surrounding prose", text.startswith("prefix\n") and text.endswith("suffix\n")))
        checks.append(("generation emits every row", all(lbl in text for _, lbl in ROWS)))
        # 3. --check now passes, and regeneration is idempotent.
        checks.append(("fresh runbook passes --check", run(baseline_path, runbook_path, True) == 0))
        run(baseline_path, runbook_path, False)
        checks.append(("regeneration is idempotent", runbook_path.read_text() == text))
        # 4. Hand-editing the generated region fails --check.
        runbook_path.write_text(text.replace("~$", "~$9", 1))
        checks.append(("hand-edited table fails --check", run(baseline_path, runbook_path, True) == 1))
        # 5. A baseline entry without a label fails validation.
        bad = dict(synthetic)
        bad["mystery_op"] = "1"
        baseline_path.write_text(json.dumps(bad))
        try:
            run(baseline_path, runbook_path, True)
            checks.append(("unlabelled baseline entry rejected", False))
        except SystemExit:
            checks.append(("unlabelled baseline entry rejected", True))
        # 6. A labelled row missing from the baseline fails validation.
        bad2 = dict(synthetic)
        del bad2[ROWS[0][0]]
        baseline_path.write_text(json.dumps(bad2))
        try:
            run(baseline_path, runbook_path, True)
            checks.append(("missing labelled row rejected", False))
        except SystemExit:
            checks.append(("missing labelled row rejected", True))

    failed = [desc for desc, ok in checks if not ok]
    for desc, ok in checks:
        print(f"{PROG}: selftest {'ok ' if ok else 'BAD'} — {desc}")
    if failed:
        print(f"{PROG}: selftest FAILED — {failed}")
        return 1
    print(f"{PROG}: selftest PASS — {len(checks)}/{len(checks)} behaviours verified")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=DEFAULT_BASELINE,
        help="committed baseline JSON (default: %(default)s)",
    )
    parser.add_argument(
        "--runbook",
        type=Path,
        default=DEFAULT_RUNBOOK,
        help="runbook to patch (default: %(default)s)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the runbook table matches the baseline; change nothing",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run the generator's behavioural self-test and exit",
    )
    args = parser.parse_args()
    if args.selftest:
        return run_selftest()
    return run(args.baseline, args.runbook, args.check)


if __name__ == "__main__":
    sys.exit(main())

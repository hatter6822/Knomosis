#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
"""Workstream GP.11.9 — the gas-benchmark regression gate.

Compares a freshly-recorded gas snapshot (``snapshots/BenchmarkGasV1_3.json``,
written by the ``vm.snapshotGasLastCall`` / ``vm.snapshotValue`` cheatcodes
during ``forge test --match-contract BenchmarkGasV1_3``) against the
committed baseline (``test/BenchmarkGasV1_3.gas-baseline.json``).

Gate semantics (per the GP.11.9 plan: ">5 % increase fails CI"):

* **FAIL** if any entry's fresh value INCREASES by more than
  ``--max-increase-pct`` (default 5) over the baseline.  The gate is
  deliberately ONE-SIDED, exactly as specified.
* **FAIL** if the benchmark sets drift: an entry present in the baseline
  but absent from the fresh run (a benchmark was deleted or renamed
  without regenerating), or present in the fresh run but absent from the
  baseline (a benchmark was added without regenerating).  Either way the
  committed baseline no longer describes the committed suite — run
  ``make snapshot-gas``.
* **WARN** (exit 0) if any entry DECREASES by more than
  ``--warn-decrease-pct`` (default 5): the committed baseline (and the
  runbook table derived from it) now overstates the cost.  Ratchet the
  improvement in with ``make snapshot-gas`` — the warning keeps the
  documented numbers honest without letting an unrelated PR be blocked by
  somebody else's improvement.

The companion ``<name>.calldata_gas`` entries are gated identically: they
only move when a function signature or canonical argument encoding
changes, which is exactly the kind of drift a reviewer should see.

``--selftest`` proves the gate's behaviour on synthetic fixtures (accept
identical, accept small drift, reject large increase, warn-only on large
decrease, reject missing entry, reject stale entry), so the tripwire
cannot be silently disabled by a later edit — the same discipline as
``audit_compile_time_caps_selftest.sh``.

Pure Python 3 stdlib; no third-party imports.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROG = "check_gas_baseline"


def load_snapshot(path: Path) -> dict[str, int]:
    """Load a forge gas-snapshot JSON file ({name: "gas-as-string"})."""
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError:
        raise SystemExit(
            f"{PROG}: FAIL — snapshot file not found: {path}\n"
            f"{PROG}: (generate it with `make snapshot-gas`, or run the "
            f"benchmark suite first)"
        )
    except json.JSONDecodeError as e:
        raise SystemExit(f"{PROG}: FAIL — {path} is not valid JSON: {e}")
    if not isinstance(raw, dict):
        raise SystemExit(f"{PROG}: FAIL — {path} is not a JSON object")
    out: dict[str, int] = {}
    for k, v in raw.items():
        try:
            out[k] = int(v)
        except (TypeError, ValueError):
            raise SystemExit(
                f"{PROG}: FAIL — entry {k!r} in {path} has non-integer value {v!r}"
            )
    return out


def compare(
    baseline: dict[str, int],
    fresh: dict[str, int],
    max_increase_pct: float,
    warn_decrease_pct: float,
) -> tuple[list[str], list[str], list[str]]:
    """Compare ``fresh`` against ``baseline``.

    Returns ``(report_lines, failures, warnings)``.  ``failures`` non-empty
    means the gate must exit 1.
    """
    report: list[str] = []
    failures: list[str] = []
    warnings: list[str] = []

    stale = sorted(set(baseline) - set(fresh))
    novel = sorted(set(fresh) - set(baseline))
    for name in stale:
        failures.append(
            f"{name}: present in the baseline but not produced by the fresh "
            f"run — the benchmark was removed or renamed; regenerate the "
            f"baseline (`make snapshot-gas`)"
        )
    for name in novel:
        failures.append(
            f"{name}: produced by the fresh run but missing from the "
            f"baseline — a new benchmark; regenerate the baseline "
            f"(`make snapshot-gas`)"
        )

    width = max((len(n) for n in baseline), default=4)
    for name in sorted(set(baseline) & set(fresh)):
        old, new = baseline[name], fresh[name]
        delta = new - old
        if old == 0:
            pct = 0.0 if new == 0 else float("inf")
        else:
            pct = 100.0 * delta / old
        status = "ok"
        if pct > max_increase_pct:
            status = "FAIL"
            failures.append(
                f"{name}: {old} -> {new} (+{pct:.2f}%) exceeds the "
                f"{max_increase_pct:g}% regression budget"
            )
        elif pct < -warn_decrease_pct:
            status = "warn"
            warnings.append(
                f"{name}: {old} -> {new} ({pct:.2f}%) — improvement beyond "
                f"{warn_decrease_pct:g}%; ratchet it into the baseline "
                f"(`make snapshot-gas`) so the documented numbers stay honest"
            )
        report.append(
            f"  {name:<{width}}  {old:>9} -> {new:>9}  {delta:>+8}  {pct:>+8.2f}%  {status}"
        )
    return report, failures, warnings


def run_check(args: argparse.Namespace) -> int:
    baseline = load_snapshot(Path(args.baseline))
    fresh = load_snapshot(Path(args.fresh))
    report, failures, warnings = compare(
        baseline, fresh, args.max_increase_pct, args.warn_decrease_pct
    )
    print(f"{PROG}: comparing fresh {args.fresh} against baseline {args.baseline}")
    for line in report:
        print(line)
    for w in warnings:
        print(f"{PROG}: WARN — {w}")
    if failures:
        for f in failures:
            print(f"{PROG}: FAIL — {f}")
        print(
            f"{PROG}: FAIL — {len(failures)} violation(s); the GP.11.9 gate "
            f"blocks gas regressions > {args.max_increase_pct:g}% and "
            f"benchmark-set drift."
        )
        return 1
    print(
        f"{PROG}: PASS — {len(baseline)} entries within the "
        f"{args.max_increase_pct:g}% regression budget"
        + (f" ({len(warnings)} ratchet warning(s))" if warnings else "")
    )
    return 0


def run_selftest() -> int:
    """Prove every gate behaviour on synthetic fixtures."""
    base = {"op_a": 100_000, "op_a.calldata_gas": 500, "op_b": 10_000}

    cases: list[tuple[str, dict[str, int], bool, bool]] = [
        # (description, fresh, expect_fail, expect_warn)
        ("identical snapshot accepted", dict(base), False, False),
        (
            "increase within budget accepted (+4.9%)",
            {**base, "op_a": 104_900},
            False,
            False,
        ),
        (
            "increase beyond budget rejected (+5.1%)",
            {**base, "op_a": 105_100},
            True,
            False,
        ),
        (
            "small-entry increase beyond budget rejected (+6%)",
            {**base, "op_b": 10_600},
            True,
            False,
        ),
        (
            "decrease beyond budget warns but passes (-10%)",
            {**base, "op_a": 90_000},
            False,
            True,
        ),
        (
            "calldata drift beyond budget rejected",
            {**base, "op_a.calldata_gas": 600},
            True,
            False,
        ),
        (
            "missing entry rejected (benchmark deleted)",
            {k: v for k, v in base.items() if k != "op_b"},
            True,
            False,
        ),
        (
            "stale-free novel entry rejected (benchmark added)",
            {**base, "op_c": 1},
            True,
            False,
        ),
    ]

    passed = 0
    for desc, fresh, expect_fail, expect_warn in cases:
        _, failures, warnings = compare(base, fresh, 5.0, 5.0)
        ok = (bool(failures) == expect_fail) and (bool(warnings) == expect_warn)
        print(f"{PROG}: selftest {'ok ' if ok else 'BAD'} — {desc}")
        if not ok:
            print(
                f"{PROG}: selftest FAILED [{desc}]\n"
                f"  expected fail={expect_fail} warn={expect_warn}\n"
                f"  got      fail={bool(failures)} warn={bool(warnings)}\n"
                f"  failures={failures}\n  warnings={warnings}"
            )
            return 1
        passed += 1
    print(f"{PROG}: selftest PASS — {passed}/{len(cases)} behaviours verified")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--baseline",
        default="test/BenchmarkGasV1_3.gas-baseline.json",
        help="committed baseline JSON (default: %(default)s)",
    )
    parser.add_argument(
        "--fresh",
        default="snapshots/BenchmarkGasV1_3.json",
        help="freshly-recorded snapshot JSON (default: %(default)s)",
    )
    parser.add_argument(
        "--max-increase-pct",
        type=float,
        default=5.0,
        help="fail on increases beyond this percentage (default: %(default)s)",
    )
    parser.add_argument(
        "--warn-decrease-pct",
        type=float,
        default=5.0,
        help="warn on decreases beyond this percentage (default: %(default)s)",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run the gate's behavioural self-test and exit",
    )
    args = parser.parse_args()
    if args.selftest:
        return run_selftest()
    return run_check(args)


if __name__ == "__main__":
    sys.exit(main())

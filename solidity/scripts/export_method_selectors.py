#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
"""Export compiled Solidity method selectors as a cross-stack fixture.

The Rust fault-proof observer builds calldata by hand and therefore
carries its own table of `(signature -> 4-byte selector)` pairs.  That
table used to be pinned only by a test that re-derived the expected
selector from the *same signature string* the code under test returns,
so it could not fail: a signature typo changed both sides together, and
the observer shipped calldata the contract could not dispatch — every
honest terminate reverting through the fallback.

This script emits the selectors from the *compiled artifacts*, which is
the only source that reflects what is actually deployed.  The Rust test
`method_selectors_pinned_against_solidity_abi` loads the result, so a
signature change on the contract side breaks the Rust build.

Usage (from the repository root, after `cd solidity && forge build`):

    python3 solidity/scripts/export_method_selectors.py            # write
    python3 solidity/scripts/export_method_selectors.py --check    # verify

`--check` is the CI mode: it exits non-zero if the committed fixture
does not match the compiled artifacts.
"""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ARTIFACT_DIR = REPO_ROOT / "solidity" / "out"
FIXTURE = REPO_ROOT / "runtime" / "tests" / "cross-stack" / "method_selectors.json"

IDENTIFIER = "knomosis-faultproof-observer/method-selectors/v1"

NOTE = (
    "Generated from the compiled Solidity artifacts by "
    "`solidity/scripts/export_method_selectors.py`.  The Rust observer's "
    "`MethodSelector` table is asserted against this file, so a signature "
    "change on the contract side breaks the Rust build instead of silently "
    "producing calldata the contract cannot dispatch."
)

# Contracts whose selectors the Rust side encodes calldata for.
CONTRACTS = ["KnomosisFaultProofGame"]


def collect() -> collections.OrderedDict:
    """Read `methodIdentifiers` out of each contract's build artifact."""
    contracts: collections.OrderedDict = collections.OrderedDict()
    for name in CONTRACTS:
        path = ARTIFACT_DIR / f"{name}.sol" / f"{name}.json"
        if not path.exists():
            sys.exit(
                f"missing build artifact {path}\n"
                f"run `cd solidity && forge build` first"
            )
        artifact = json.loads(path.read_text())
        identifiers = artifact.get("methodIdentifiers")
        if not identifiers:
            sys.exit(f"{path} has no methodIdentifiers section")
        contracts[name] = collections.OrderedDict(sorted(identifiers.items()))
    return contracts


def render(contracts: collections.OrderedDict) -> str:
    blob = collections.OrderedDict(
        [("identifier", IDENTIFIER), ("note", NOTE), ("contracts", contracts)]
    )
    return json.dumps(blob, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed fixture matches the compiled artifacts",
    )
    args = parser.parse_args()

    rendered = render(collect())

    if args.check:
        if not FIXTURE.exists():
            print(f"FAIL: {FIXTURE} does not exist", file=sys.stderr)
            return 1
        if FIXTURE.read_text() != rendered:
            print(
                f"FAIL: {FIXTURE} is stale.\n"
                f"      Re-run: python3 solidity/scripts/export_method_selectors.py",
                file=sys.stderr,
            )
            return 1
        print(f"OK: {FIXTURE} matches the compiled artifacts")
        return 0

    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(rendered)
    total = sum(len(v) for v in json.loads(rendered)["contracts"].values())
    print(f"wrote {total} selectors to {FIXTURE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

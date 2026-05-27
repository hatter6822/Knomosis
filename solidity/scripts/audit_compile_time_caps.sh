#!/usr/bin/env bash
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

#
# Workstream GP.5.2 — compile-time-cap audit gate.
#
# The three fee-split caps in `KnomosisBridge.sol` are constitutional
# limits on EVERY deployment (unified-gas-pool plan §GP.5.2):
#
#   MAX_FEE_BPS_CAP         = 5000              (uint16; 50% max fee)
#   MIN_WEI_PER_BUDGET_UNIT = 1                 (uint64; rules out /0)
#   MAX_BUDGET_PER_DEPOSIT  = 1_000_000_000_000 (uint64; 10^12 cap)
#
# Changing any of these values is a Genesis-Plan §13.6 amendment and
# triggers the two-reviewer rule.  This gate is the fast tripwire that
# fails loudly if a value drifts in source WITHOUT that process — a
# source-level complement to the compiled-contract pin in
# `test/BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned`.  The two
# layers are deliberately independent: this one catches an edit to the
# literal before `solc` ever runs (and catches a reformat that keeps
# the contract compiling), while the forge test catches the compiled
# value through the public getter.
#
# It is pure `grep`/`sed` (no `solc`/`forge` dependency), so it runs in
# well under a second and never blocks on a toolchain install.
#
# Usage:
#   scripts/audit_compile_time_caps.sh [path/to/KnomosisBridge.sol]
#
# The optional argument overrides the audited file; it defaults to the
# canonical location relative to this script, and is the seam used by
# the tamper-detection checks documented in the unified-gas-pool plan.
#
# Exit codes:
#   0  every cap carries its canonical value
#   1  a cap is missing, duplicated, or carries a non-canonical value
#   2  usage / environment error (audited file not found)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="${1:-${SCRIPT_DIR}/../src/contracts/KnomosisBridge.sol}"

if [[ ! -f "${CONTRACT}" ]]; then
    echo "audit_compile_time_caps: error: contract file not found: ${CONTRACT}" >&2
    exit 2
fi

# Canonical (name | solidity-type | decimal value) triples for the
# three constitutional caps declared in KnomosisBridge.sol — the
# authoritative on-chain source of these values.  This gate audits that
# contract only; it does not parse the derived mirrors of the same
# constants, which are pinned by their own layers:
#   * the Solidity test reference `test/utils/FeeSplitMath.sol` is held
#     equal to the contract getter by
#     `test/BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned`;
#   * the Lean cross-stack reference is held equal by the
#     `deposit_fee_split.json` equivalence corpus.
# Changing a value below therefore means changing it in the contract —
# a Genesis-Plan §13.6 amendment + the two-reviewer rule.
CAPS=(
    "MAX_FEE_BPS_CAP|uint16|5000"
    "MIN_WEI_PER_BUDGET_UNIT|uint64|1"
    "MAX_BUDGET_PER_DEPOSIT|uint64|1000000000000"
)

failures=0
fail() {
    echo "audit_compile_time_caps: FAIL: $*" >&2
    failures=$((failures + 1))
}

for spec in "${CAPS[@]}"; do
    IFS='|' read -r name want_type want_value <<<"${spec}"

    # A canonical declaration looks like:
    #   uint16 public constant MAX_FEE_BPS_CAP = 5000;
    # Requiring the `constant` keyword immediately before the name
    # distinguishes the declaration from every read-only USE of the
    # same identifier elsewhere in the contract (the clamp comparison,
    # the assignment in the clamp branch, the NatSpec).  The value is
    # constrained to a pure decimal literal (a leading digit followed
    # by digits / `_` separators) terminated by `;`, so a hex / scientific
    # reformat fails closed rather than slipping past unread.
    decl_re="(uint8|uint16|uint32|uint64|uint128|uint256)[[:space:]]+public[[:space:]]+constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*[0-9][0-9_]*[[:space:]]*;"

    hits="$(grep -nE "${decl_re}" "${CONTRACT}" || true)"
    if [[ -z "${hits}" ]]; then
        fail "${name}: no canonical \`public constant ${name} = …;\` declaration found"
        continue
    fi

    count="$(printf '%s\n' "${hits}" | wc -l | tr -d '[:space:]')"
    if [[ "${count}" != "1" ]]; then
        fail "${name}: expected exactly 1 declaration, found ${count}:"
        printf '%s\n' "${hits}" | sed 's/^/           /' >&2
        continue
    fi

    line="${hits}"  # e.g. "166:    uint16 public constant MAX_FEE_BPS_CAP = 5000;"

    # Extract the declared type (first `uintN` token after the grep
    # line-number prefix) and the assigned literal.  The value pattern
    # is re-anchored on `constant <name> =` rather than a bare `.*=`, so
    # it reads the value of THIS named constant exactly — independent of
    # any trailing comment or statement on the line that also contains
    # `=`.  Underscores are then stripped so an unchanged value reformat
    # (e.g. `1_000_000_000_000` vs `1000000000000`) compares equal.
    got_type="$(printf '%s\n' "${line}" | sed -E 's/^[0-9]+:[[:space:]]*(uint[0-9]+).*/\1/')"
    got_value="$(printf '%s\n' "${line}" | sed -E "s/.*constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*([0-9][0-9_]*)[[:space:]]*;.*/\1/")"
    got_value="${got_value//_/}"

    if [[ "${got_type}" != "${want_type}" ]]; then
        fail "${name}: type is \`${got_type}\`, expected \`${want_type}\`  (${line#*:})"
        continue
    fi
    if [[ "${got_value}" != "${want_value}" ]]; then
        fail "${name}: value is ${got_value}, expected ${want_value}  (${line#*:})"
        continue
    fi

    echo "audit_compile_time_caps: ok: ${name} = ${want_value} (${want_type})"
done

if (( failures > 0 )); then
    {
        echo "audit_compile_time_caps: ${failures} cap check(s) FAILED — see above."
        echo "  Changing a constitutional fee-split cap requires a Genesis-Plan"
        echo "  §13.6 amendment and the two-reviewer rule.  If this change is"
        echo "  intentional, update this gate's CAPS table in the same PR."
    } >&2
    exit 1
fi

echo "audit_compile_time_caps: all 3 constitutional fee-split caps verified."

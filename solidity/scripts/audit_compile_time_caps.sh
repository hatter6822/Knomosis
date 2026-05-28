#!/usr/bin/env bash
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

#
# Workstream GP.5.2 — compile-time-cap audit gate (+ GP.5.4 BOLD pins).
#
# The three fee-split caps in `KnomosisBridge.sol` are constitutional
# limits on EVERY deployment (unified-gas-pool plan §GP.5.2):
#
#   MAX_FEE_BPS_CAP         = 5000              (uint16; 50% max fee)
#   MIN_WEI_PER_BUDGET_UNIT = 1                 (uint64; rules out /0)
#   MAX_BUDGET_PER_DEPOSIT  = 1_000_000_000_000 (uint64; 10^12 cap)
#
# Workstream GP.5.5 adds a fourth uintN cap (checked by the CAPS loop):
#
#   BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS = 500 (uint256; 5% Liquity-V2
#                          redemption-rate depeg auto-trigger threshold)
#
# Workstream GP.5.4 adds two constitutional BOLD pins, checked with
# kind-specific patterns (the CAPS loop below matches only uintN /
# decimal literals):
#
#   BOLD_TOKEN_ADDRESS   = 0x6440f144b7e50D6a8439336510312d2F54beB01D
#                          (address; canonical Liquity V2 BOLD token)
#   EXPECTED_BOLD_SYMBOL = "BOLD"  (string; constructor symbol check)
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
# It is pure `grep`/`sed`/`awk` (no `solc`/`forge` dependency), so it
# runs in well under a second and never blocks on a toolchain install.
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

# Strip Solidity comments BEFORE matching.  A canonical-looking
# declaration line sitting inside a `//` or (multi-line) `/* … */`
# comment must NOT satisfy the audit while the REAL declaration drifts
# — e.g. to a constant expression like `5001 + 0` that the strict
# literal regex below rejects.  Without this pass the gate reads the
# commented value and reports success exactly when a cap changed: a
# false pass, the one failure mode a constitutional tripwire must never
# have.  The awk pass removes line and block comments while emitting one
# line per input line, so `grep -n` line numbers still match the source.
# It does not special-case comment markers inside string literals; the
# audited declarations contain none, so that is sound here.
strip_solidity_comments() {
    awk '
        BEGIN { inblock = 0 }
        {
            line = $0; out = ""; i = 1; n = length(line)
            while (i <= n) {
                two = substr(line, i, 2)
                if (inblock) {
                    if (two == "*/") { inblock = 0; i += 2 } else { i += 1 }
                } else if (two == "/*") {
                    inblock = 1; i += 2
                } else if (two == "//") {
                    break
                } else {
                    out = out substr(line, i, 1); i += 1
                }
            }
            print out
        }
    ' "$1"
}

STRIPPED="$(mktemp)"
trap 'rm -f "${STRIPPED}"' EXIT
strip_solidity_comments "${CONTRACT}" >"${STRIPPED}"

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
    "BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS|uint256|500"
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
    # / constant-expression form fails closed rather than slipping past
    # unread.  Matching runs over the comment-stripped view, so a
    # commented copy of the declaration cannot mask a drifted real one.
    decl_re="(uint8|uint16|uint32|uint64|uint128|uint256)[[:space:]]+public[[:space:]]+constant[[:space:]]+${name}[[:space:]]*=[[:space:]]*[0-9][0-9_]*[[:space:]]*;"

    hits="$(grep -nE "${decl_re}" "${STRIPPED}" || true)"
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

# ------------------------------------------------------------------
# BOLD constitutional pins (Workstream GP.5.4) — address + string.
# Checked with kind-specific patterns because the CAPS loop above
# matches only uintN / decimal literals.  Both run over the
# comment-stripped view, so a commented copy cannot mask a drift.
# ------------------------------------------------------------------

# BOLD_TOKEN_ADDRESS — `address public constant ... = 0x<40 hex>;`.
# Compared case-insensitively: the source uses the EIP-55 mixed-case
# checksum form of these same 20 bytes, so the canonical comparison
# value is held lowercase and both sides are lowercased.
bold_addr_want="0x6440f144b7e50d6a8439336510312d2f54beb01d"
bold_addr_re="address[[:space:]]+public[[:space:]]+constant[[:space:]]+BOLD_TOKEN_ADDRESS[[:space:]]*=[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*;"
hits="$(grep -nE "${bold_addr_re}" "${STRIPPED}" || true)"
if [[ -z "${hits}" ]]; then
    fail "BOLD_TOKEN_ADDRESS: no canonical \`address public constant BOLD_TOKEN_ADDRESS = 0x…;\` declaration found"
elif [[ "$(printf '%s\n' "${hits}" | wc -l | tr -d '[:space:]')" != "1" ]]; then
    fail "BOLD_TOKEN_ADDRESS: expected exactly 1 declaration, found $(printf '%s\n' "${hits}" | wc -l | tr -d '[:space:]')"
else
    got_addr="$(printf '%s\n' "${hits}" \
        | sed -E 's/.*=[[:space:]]*(0x[0-9a-fA-F]{40})[[:space:]]*;.*/\1/' | tr 'A-F' 'a-f')"
    if [[ "${got_addr}" != "${bold_addr_want}" ]]; then
        fail "BOLD_TOKEN_ADDRESS: value is ${got_addr}, expected ${bold_addr_want} (case-insensitive)"
    else
        echo "audit_compile_time_caps: ok: BOLD_TOKEN_ADDRESS = ${bold_addr_want} (address)"
    fi
fi

# EXPECTED_BOLD_SYMBOL — `string public constant ... = "…";`.
bold_sym_want="BOLD"
bold_sym_re="string[[:space:]]+public[[:space:]]+constant[[:space:]]+EXPECTED_BOLD_SYMBOL[[:space:]]*=[[:space:]]*\"[^\"]*\"[[:space:]]*;"
hits="$(grep -nE "${bold_sym_re}" "${STRIPPED}" || true)"
if [[ -z "${hits}" ]]; then
    fail "EXPECTED_BOLD_SYMBOL: no canonical \`string public constant EXPECTED_BOLD_SYMBOL = \"…\";\` declaration found"
elif [[ "$(printf '%s\n' "${hits}" | wc -l | tr -d '[:space:]')" != "1" ]]; then
    fail "EXPECTED_BOLD_SYMBOL: expected exactly 1 declaration, found $(printf '%s\n' "${hits}" | wc -l | tr -d '[:space:]')"
else
    got_sym="$(printf '%s\n' "${hits}" | sed -E 's/.*=[[:space:]]*"([^"]*)"[[:space:]]*;.*/\1/')"
    if [[ "${got_sym}" != "${bold_sym_want}" ]]; then
        fail "EXPECTED_BOLD_SYMBOL: value is \"${got_sym}\", expected \"${bold_sym_want}\""
    else
        echo "audit_compile_time_caps: ok: EXPECTED_BOLD_SYMBOL = \"${bold_sym_want}\" (string)"
    fi
fi

if (( failures > 0 )); then
    {
        echo "audit_compile_time_caps: ${failures} cap check(s) FAILED — see above."
        echo "  Changing a constitutional fee-split cap requires a Genesis-Plan"
        echo "  §13.6 amendment and the two-reviewer rule.  If this change is"
        echo "  intentional, update this gate's CAPS table in the same PR."
    } >&2
    exit 1
fi

echo "audit_compile_time_caps: all 4 compile-time caps + 2 BOLD pins verified."

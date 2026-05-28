#!/usr/bin/env bash
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

#
# Self-test for `audit_compile_time_caps.sh` (Workstream GP.5.2).
#
# A constitutional governance gate is only useful if its tripwire
# actually trips.  The danger this guards against is a future edit that
# silently disables the gate (a regex that always matches, a value
# check that never fires) — which would let a cap drift through
# unreviewed.  This harness proves, reproducibly, that the gate:
#
#   * ACCEPTS the canonical `KnomosisBridge.sol` (exit 0),
#   * REJECTS every drift class — value change, type change, a missing
#     or duplicated declaration (exit 1),
#   * TOLERATES a value-preserving reformat (underscores; an extra
#     statement on the declaration line) (exit 0),
#   * reports a missing audited file as an environment error (exit 2).
#
# Tamper patterns are derived from the live source (append-a-digit for
# value drift, strip underscores for the reformat, etc.) rather than
# hard-coding today's values, so this harness keeps working across a
# legitimate §13.6 cap amendment without edits.
#
# Pure bash + grep/sed; no solc/forge dependency.  Exit 0 iff every
# expectation holds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/audit_compile_time_caps.sh"
SRC="${SCRIPT_DIR}/../src/contracts/KnomosisBridge.sol"

if [[ ! -x "${GATE}" ]]; then
    echo "selftest: error: gate not executable: ${GATE}" >&2
    exit 2
fi
if [[ ! -f "${SRC}" ]]; then
    echo "selftest: error: contract not found: ${SRC}" >&2
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

passed=0
failed=0

# expect <want-exit> <description> <file-arg...>
expect() {
    local want="$1" desc="$2"
    shift 2
    local got=0
    "${GATE}" "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" == "${want}" ]]; then
        echo "selftest: ok: ${desc} (exit ${got})"
        passed=$((passed + 1))
    else
        echo "selftest: FAIL: ${desc} — expected exit ${want}, got ${got}" >&2
        failed=$((failed + 1))
    fi
}

# Per-cap declaration grep (value-agnostic), reused by several tampers.
# GP.5.5 adds BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS (the fourth uintN cap),
# so every per-cap tamper class (value / type / missing / duplicate) now
# also exercises it.
caps=(
    MAX_FEE_BPS_CAP
    MIN_WEI_PER_BUDGET_UNIT
    MAX_BUDGET_PER_DEPOSIT
    BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS
)

# --- ACCEPT: the real source, unmodified. ---
expect 0 "canonical source accepted" "${SRC}"

# --- REJECT: value drift on each cap (append a digit; works for any
#     current value, including the underscore-grouped 10^12). ---
for cap in "${caps[@]}"; do
    out="${TMP}/drift_${cap}.sol"
    sed -E "s/(constant ${cap} = [0-9_]+)(;)/\10\2/" "${SRC}" >"${out}"
    expect 1 "value drift on ${cap} rejected" "${out}"
done

# --- REJECT: type change on each cap.  Replace the declared width
#     (the `uintN` immediately before ` public constant <cap>`) with
#     `uint32` — a width that is in the gate's accepted set yet differs
#     from every current cap (uint16 / uint64), so this exercises the
#     type-MISMATCH path, not the missing-declaration path.  Anchoring
#     on ` public constant <cap> =` (no `\b`) keeps this portable across
#     GNU and BSD sed.  (If a cap is ever amended to uint32 this becomes
#     a no-op and its case fails loudly, prompting a self-test update.)
for cap in "${caps[@]}"; do
    out="${TMP}/type_${cap}.sol"
    sed -E "s/uint[0-9]+([[:space:]]+public[[:space:]]+constant[[:space:]]+${cap}[[:space:]]*=)/uint32\1/" \
        "${SRC}" >"${out}"
    expect 1 "type change on ${cap} rejected" "${out}"
done

# --- REJECT: a missing declaration (drop the line, value-agnostic). ---
for cap in "${caps[@]}"; do
    out="${TMP}/missing_${cap}.sol"
    grep -vE "constant ${cap}[[:space:]]*=" "${SRC}" >"${out}"
    expect 1 "missing ${cap} rejected" "${out}"
done

# --- REJECT: a duplicated declaration (auto-print + p => two copies). ---
for cap in "${caps[@]}"; do
    out="${TMP}/dup_${cap}.sol"
    sed -E "/[[:space:]]constant ${cap}[[:space:]]*=[[:space:]]*[0-9][0-9_]*[[:space:]]*;/p" \
        "${SRC}" >"${out}"
    expect 1 "duplicated ${cap} rejected" "${out}"
done

# --- REJECT: a canonical-looking declaration hidden in a comment must
#     not mask a drifted real one.  The real declaration is rewritten to
#     a constant EXPRESSION (which the strict literal regex rejects) and
#     an unchanged canonical copy is left in a comment.  Without
#     comment-stripping the gate would read the comment's value and pass
#     — the false-pass class the PR-91 audit reviewer found.  Both the
#     multi-line `/* */` and the `//` forms are covered. ---
real_decl="$(grep -E 'uint[0-9]+ public constant MAX_FEE_BPS_CAP = [0-9_]+;' "${SRC}")"
expr_decl="$(printf '%s\n' "${real_decl}" | sed -E 's/=[[:space:]]*([0-9_]+)[[:space:]]*;/= \1 + 0;/')"

mask_block="${TMP}/mask_block.sol"
awk -v real="${real_decl}" -v expr="${expr_decl}" '
    $0 == real && !done { print "    /*"; print real; print "    */"; print expr; done = 1; next }
    { print }
' "${SRC}" >"${mask_block}"
expect 1 "block-comment-masked declaration rejected" "${mask_block}"

mask_line="${TMP}/mask_line.sol"
awk -v real="${real_decl}" -v expr="${expr_decl}" '
    $0 == real && !done { print "    // " real; print expr; done = 1; next }
    { print }
' "${SRC}" >"${mask_line}"
expect 1 "line-comment-masked declaration rejected" "${mask_line}"

# --- TOLERATE: a value-preserving underscore reformat on the 10^12
#     cap (the only one written with separators).  Strip underscores
#     from the NUMERIC LITERAL only — never the identifier, which also
#     contains underscores.  The literal is read from the live source
#     so this survives a value amendment.  (Stripping `_` line-wide
#     would mangle MAX_BUDGET_PER_DEPOSIT -> MAXBUDGETPERDEPOSIT and the
#     gate would correctly reject it as a missing declaration.) ---
reformat="${TMP}/reformat.sol"
budget_lit="$(grep -E 'constant MAX_BUDGET_PER_DEPOSIT[[:space:]]*=' "${SRC}" \
    | sed -E 's/.*=[[:space:]]*([0-9_]+)[[:space:]]*;.*/\1/')"
budget_stripped="${budget_lit//_/}"
sed -E "/constant MAX_BUDGET_PER_DEPOSIT/ s/=[[:space:]]*${budget_lit}[[:space:]]*;/= ${budget_stripped};/" \
    "${SRC}" >"${reformat}"
expect 0 "underscore reformat tolerated" "${reformat}"

# --- TOLERATE: an extra statement on the declaration line (proves the
#     value is read by name, not as "the last number on the line"). ---
trailer="${TMP}/trailer.sol"
sed -E "s/(constant MAX_FEE_BPS_CAP = [0-9_]+;)/\1 uint256 zz = 1234;/" "${SRC}" >"${trailer}"
expect 0 "trailing statement on decl line tolerated (exact-by-name read)" "${trailer}"

# ------------------------------------------------------------------
# BOLD constitutional pins (Workstream GP.5.4) — address + string.
# Tampers are derived from the live source so they survive a §13.6
# amendment of either pin.
# ------------------------------------------------------------------

bold_addr_lit="$(grep -E 'constant BOLD_TOKEN_ADDRESS[[:space:]]*=' "${SRC}" \
    | sed -E 's/.*=[[:space:]]*(0x[0-9a-fA-F]{40})[[:space:]]*;.*/\1/')"
bold_sym_lit="$(grep -E 'constant EXPECTED_BOLD_SYMBOL[[:space:]]*=' "${SRC}" \
    | sed -E 's/.*=[[:space:]]*"([^"]*)"[[:space:]]*;.*/\1/')"

# --- REJECT: address value drift (flip the last hex digit to a
#     guaranteed-different value; the address has no regex metachars). ---
addr_last="${bold_addr_lit: -1}"
if [[ "${addr_last}" == "0" ]]; then addr_newlast="1"; else addr_newlast="0"; fi
bold_addr_drift="${bold_addr_lit%?}${addr_newlast}"
addr_drift="${TMP}/addr_drift.sol"
sed "s/${bold_addr_lit}/${bold_addr_drift}/" "${SRC}" >"${addr_drift}"
expect 1 "BOLD_TOKEN_ADDRESS value drift rejected" "${addr_drift}"

# --- REJECT: missing BOLD_TOKEN_ADDRESS declaration. ---
addr_missing="${TMP}/addr_missing.sol"
grep -vE "constant BOLD_TOKEN_ADDRESS[[:space:]]*=" "${SRC}" >"${addr_missing}"
expect 1 "missing BOLD_TOKEN_ADDRESS rejected" "${addr_missing}"

# --- TOLERATE: a value-preserving case fold of the address (the gate
#     compares case-insensitively; the source uses the EIP-55 form). ---
bold_addr_lc="$(printf '%s' "${bold_addr_lit}" | tr 'A-F' 'a-f')"
addr_lc="${TMP}/addr_lc.sol"
sed "s/${bold_addr_lit}/${bold_addr_lc}/" "${SRC}" >"${addr_lc}"
expect 0 "lowercased BOLD address tolerated (case-insensitive compare)" "${addr_lc}"

# --- REJECT: symbol value drift (append a char inside the quotes). ---
sym_drift="${TMP}/sym_drift.sol"
sed -E "s/(constant EXPECTED_BOLD_SYMBOL = )\"${bold_sym_lit}\"/\1\"${bold_sym_lit}X\"/" \
    "${SRC}" >"${sym_drift}"
expect 1 "EXPECTED_BOLD_SYMBOL value drift rejected" "${sym_drift}"

# --- REJECT: missing EXPECTED_BOLD_SYMBOL declaration. ---
sym_missing="${TMP}/sym_missing.sol"
grep -vE "constant EXPECTED_BOLD_SYMBOL[[:space:]]*=" "${SRC}" >"${sym_missing}"
expect 1 "missing EXPECTED_BOLD_SYMBOL rejected" "${sym_missing}"

# --- ENV ERROR: a missing audited file. ---
expect 2 "missing audited file reported as env error" "${TMP}/does_not_exist.sol"

echo "selftest: ${passed} passed, ${failed} failed."
if (( failed > 0 )); then
    exit 1
fi
echo "selftest: audit_compile_time_caps.sh behaves correctly on all ${passed} cases."

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
#
# Release-binary crypto gate (security-review F-1 / F-2).
#
# The per-PR workflows verify_keccak_link.sh and verify_secp256k1_link.sh
# each prove ONE adaptor's fallback->production flip in ISOLATION (the
# other trust binding stays on the fallback).  THIS script is the
# release-time check those cannot give: it builds a SINGLE `knomosis`
# binary with BOTH production adaptors linked at once — the keccak256
# hash adaptor AND the secp256k1 verifier — and asserts that `hash-check`
# AND `verify-check` BOTH exit 0 on that one executable.  That exercises
# duplicate-symbol / link-order / env interactions in the actual release
# binary, which the two single-adaptor scripts never do.
#
# It also proves the gate is non-vacuous: the DEFAULT (fallback) build
# must FAIL CLOSED on both checks (exit 1) before the production-linked
# build is required to pass both (exit 0).
#
# On the SHA-256 fingerprint: each adaptor staticlib's SHA-256 is RECORDED
# and logged as the release's crypto-adaptor fingerprint.  It is NOT
# checked against a committed pin: the staticlib embeds its absolute build
# path (e.g. /home/runner/... in CI vs a deployer's path), so the bytes
# are not reproducible across environments and a committed digest could
# not match.  The load-bearing guarantee is the production-link + dual
# fail-closed assertion above, not byte-pinning.
#
# Usage:  scripts/verify_release_crypto.sh
# Exit:   0  both adaptors link into one binary and both checks flip
#            fallback(1) -> production(0); non-zero on any failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1090,SC1091
[ -f "${HOME}/.elan/env" ] && source "${HOME}/.elan/env"
# shellcheck disable=SC1090,SC1091
[ -f "${HOME}/.cargo/env" ] && source "${HOME}/.cargo/env"
set -u

need() { command -v "$1" >/dev/null 2>&1 || { echo "verify_release_crypto: missing required tool: $1" >&2; exit 2; }; }
need lean
need lake
need cargo
need nm
need sha256sum

log() { echo "verify_release_crypto: $*"; }

LEAN_PREFIX="$(lean --print-prefix)"
log "lean prefix: ${LEAN_PREFIX}"

# Restore the DEFAULT (fallback) knomosis binary on exit, so a local run
# never leaves a both-adaptors-linked binary in .lake/build/bin.
restore_default() {
    log "restoring the default (fallback) knomosis binary ..."
    rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
    ( cd "${ROOT}" && lake build knomosis >/dev/null 2>&1 ) || true
}
trap restore_default EXIT

# ------------------------------------------------------------------
# 1. Build BOTH adaptor staticlibs WITH the Lean FFI shim, each into its
#    own isolated target dir (a plain `cargo build` of the crate would
#    otherwise clobber the shared .a with a no-shim build cargo still
#    reports up-to-date — the silently-vacuous trap).
# ------------------------------------------------------------------
KECCAK_TARGET="${ROOT}/runtime/target/release-gate-keccak"
VERIFY_TARGET="${ROOT}/runtime/target/release-gate-verify"
rm -rf "${KECCAK_TARGET}" "${VERIFY_TARGET}"

log "building knomosis-hash-keccak256 staticlib (--features lean-ffi --release) ..."
( cd runtime && LEAN_SYSROOT="${LEAN_PREFIX}" CARGO_TARGET_DIR="${KECCAK_TARGET}" \
    cargo build -p knomosis-hash-keccak256 --features lean-ffi --release )
KECCAK_A="${KECCAK_TARGET}/release/libknomosis_hash_keccak256.a"
[ -f "${KECCAK_A}" ] || { echo "verify_release_crypto: keccak staticlib not produced: ${KECCAK_A}" >&2; exit 1; }

log "building knomosis-verify-secp256k1 staticlib (--features lean-ffi --release) ..."
( cd runtime && LEAN_SYSROOT="${LEAN_PREFIX}" CARGO_TARGET_DIR="${VERIFY_TARGET}" \
    cargo build -p knomosis-verify-secp256k1 --features lean-ffi --release )
VERIFY_A="${VERIFY_TARGET}/release/libknomosis_verify_secp256k1.a"
[ -f "${VERIFY_A}" ] || { echo "verify_release_crypto: verify staticlib not produced: ${VERIFY_A}" >&2; exit 1; }

# Both staticlibs MUST export their Lean-ABI symbols (else lean.h was not
# found and the shim is absent — a silently vacuous build).  Capture `nm`
# into a variable to dodge the SIGPIPE/pipefail interaction.
keccak_syms="$(nm "${KECCAK_A}" 2>/dev/null || true)"
for sym in knomosis_hash_bytes knomosis_hash_stream knomosis_hash_identifier; do
    grep -qE "\\bT ${sym}\\b" <<<"${keccak_syms}" || {
        echo "verify_release_crypto: keccak staticlib does not export '${sym}' (Lean FFI shim not built?)." >&2; exit 1; }
done
verify_syms="$(nm "${VERIFY_A}" 2>/dev/null || true)"
grep -qE '\bT knomosis_verify_identifier\b' <<<"${verify_syms}" || {
    echo "verify_release_crypto: verify staticlib does not export 'knomosis_verify_identifier' (Lean FFI shim not built?)." >&2; exit 1; }
log "both staticlibs export their Lean-ABI symbols."

# ------------------------------------------------------------------
# 2. Record + log each adaptor's SHA-256 fingerprint (audit trail; NOT a
#    committed pin — see the header note on cross-environment build paths).
# ------------------------------------------------------------------
KECCAK_SHA="$(sha256sum "${KECCAK_A}" | awk '{print $1}')"
VERIFY_SHA="$(sha256sum "${VERIFY_A}" | awk '{print $1}')"
log "keccak256 adaptor SHA-256:  ${KECCAK_SHA}"
log "secp256k1 adaptor SHA-256:  ${VERIFY_SHA}"

# ------------------------------------------------------------------
# 3. Non-vacuity baseline: the DEFAULT (fallback) build must FAIL CLOSED
#    on BOTH checks (exit 1) before the production assertion below.
# ------------------------------------------------------------------
log "building the DEFAULT (fallback) knomosis ..."
rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
lake build knomosis >/dev/null 2>&1
if .lake/build/bin/knomosis hash-check >/dev/null 2>&1; then
    echo "verify_release_crypto: FATAL — DEFAULT hash-check exited 0; the gate is not fail-closed." >&2; exit 1
fi
if .lake/build/bin/knomosis verify-check >/dev/null 2>&1; then
    echo "verify_release_crypto: FATAL — DEFAULT verify-check exited 0; the gate is not fail-closed." >&2; exit 1
fi
log "default hash-check + verify-check both exit 1 (fail-closed) — as required."

# ------------------------------------------------------------------
# 4. Build ONE knomosis with BOTH production adaptors linked, and assert
#    BOTH checks exit 0 on that single binary.
# ------------------------------------------------------------------
log "building knomosis with BOTH production adaptors linked ..."
rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
KNOMOSIS_HASH_BACKEND=keccak256 \
    KNOMOSIS_KECCAK_STATICLIB="${KECCAK_A}" \
    KNOMOSIS_VERIFY_STATICLIB="${VERIFY_A}" \
    lake build knomosis >/dev/null 2>&1
if ! .lake/build/bin/knomosis hash-check; then
    echo "verify_release_crypto: FATAL — both-adaptors hash-check exited non-zero (keccak not linked?)." >&2; exit 1
fi
if ! .lake/build/bin/knomosis verify-check; then
    echo "verify_release_crypto: FATAL — both-adaptors verify-check exited non-zero (secp256k1 not linked / self-test failed?)." >&2; exit 1
fi
log "production-linked hash-check + verify-check BOTH exit 0 on a single binary — F-1/F-2 release gate verified."

log "PASSED — one knomosis binary links BOTH production adaptors; both checks flip fallback(1) -> production(0)."

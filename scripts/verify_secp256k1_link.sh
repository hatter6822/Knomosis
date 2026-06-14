#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

#
# Production secp256k1-verifier link verification (security-review F-2).
#
# The Lean kernel is signature-scheme AGNOSTIC: the `Verify` trust
# assumption surfaces as an `opaque`, and the deployment-facing
# `verifyImplementationIdentifier` is an `@[extern]` whose default body
# is the Lean fallback `"lean-opaque-fallback"` (so `lake build` / `lake
# test` run standalone and `knomosis verify-check` fails CLOSED — exit 1
# — refusing to deploy on a non-functional verifier).
#
# This script closes the F-2 loop end-to-end:
#
#   F-2(b) production link.  It builds the REAL secp256k1 adaptor
#   staticlib (`knomosis-verify-secp256k1`, backed by the audited `k256`
#   crate) WITH the Lean FFI shim, links it into the `knomosis` binary IN
#   PLACE OF the fallback (via the lakefile `knomosisVerifyFallback`
#   extern_lib + `KNOMOSIS_VERIFY_STATICLIB`), and asserts that
#   `knomosis verify-check` now exits 0 with the PRODUCTION identifier.
#   It ALSO asserts the default (fallback) build still exits 1 — so the
#   gate genuinely DISTINGUISHES production from fallback rather than
#   passing vacuously.
#
#   F-2(a) artefact integrity (SHA-256 record / verify scaffold).  It
#   records the SHA-256 of the just-built production staticlib to a
#   snapshot, and (in --check mode) re-verifies a prior snapshot, so a
#   deployment can pin the exact verifier artefact it links and detect
#   any drift (a swapped / tampered adaptor) before deploy.
#
# Requires: elan (lean / lake), cargo (rust 1.83), nm, sha256sum.  Pure
# orchestration; no source edits.
#
# Usage:
#   scripts/verify_secp256k1_link.sh            # build + record + prove
#   scripts/verify_secp256k1_link.sh --check    # build + VERIFY snapshot + prove
#
# Exit codes:
#   0  production verifier links and `verify-check` flips fallback(1)->prod(0)
#   1  a build / link / assertion / integrity-drift step failed
#   2  a required toolchain is missing

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

MODE="record"
if [ "${1:-}" = "--check" ]; then MODE="check"; fi

# Source toolchain envs (tolerate already-on-PATH; guard `set -u`).
set +u
# shellcheck disable=SC1090,SC1091
[ -f "${HOME}/.elan/env" ] && source "${HOME}/.elan/env"
# shellcheck disable=SC1090,SC1091
[ -f "${HOME}/.cargo/env" ] && source "${HOME}/.cargo/env"
set -u

need() { command -v "$1" >/dev/null 2>&1 || { echo "verify_secp256k1: missing required tool: $1" >&2; exit 2; }; }
need lean
need lake
need cargo
need nm
need sha256sum

log() { echo "verify_secp256k1: $*"; }

# ------------------------------------------------------------------
# 1. Build the secp256k1 adaptor staticlib WITH the Lean FFI shim, into
#    a DEDICATED isolated target dir (so a plain `cargo build` of the
#    crate cannot clobber the lean-ffi build while cargo still reports it
#    up-to-date — the same silently-vacuous trap the keccak script
#    guards against).
# ------------------------------------------------------------------
LEAN_PREFIX="$(lean --print-prefix)"
log "lean prefix: ${LEAN_PREFIX}"
VERIFY_TARGET="${ROOT}/runtime/target/secp256k1-ffi-verify"
rm -rf "${VERIFY_TARGET}"
log "building knomosis-verify-secp256k1 staticlib (--features lean-ffi) ..."
( cd runtime && LEAN_SYSROOT="${LEAN_PREFIX}" CARGO_TARGET_DIR="${VERIFY_TARGET}" \
    cargo build -p knomosis-verify-secp256k1 --features lean-ffi --release )

VERIFY_A="${VERIFY_TARGET}/release/libknomosis_verify_secp256k1.a"
[ -f "${VERIFY_A}" ] || { echo "verify_secp256k1: staticlib not produced: ${VERIFY_A}" >&2; exit 1; }

# The `lean-ffi` feature MUST have built the C shim (else `lean.h` was
# not found and `knomosis_verify_identifier` is absent — a silently
# vacuous build).  Capture `nm` into a variable to dodge the SIGPIPE/
# pipefail interaction (see the keccak script's note).
nm_syms="$(nm "${VERIFY_A}" 2>/dev/null || true)"
if ! grep -qE '\bT knomosis_verify_identifier\b' <<<"${nm_syms}"; then
    echo "verify_secp256k1: staticlib does not export 'knomosis_verify_identifier' — the Lean FFI shim was not built (lean.h not found?)." >&2
    exit 1
fi
log "staticlib exports the knomosis_verify_identifier Lean-ABI symbol."

# ------------------------------------------------------------------
# 2. F-2(a): record / verify the staticlib SHA-256.  The snapshot lives
#    under the gitignored target dir; a deployment copies it into its
#    own pinned-artefact manifest.  --check fails on ANY drift.
# ------------------------------------------------------------------
SNAPSHOT="${ROOT}/runtime/target/verify-adaptor.sha256"
DIGEST="$(sha256sum "${VERIFY_A}" | awk '{print $1}')"
log "secp256k1 adaptor SHA-256: ${DIGEST}"
if [ "${MODE}" = "check" ]; then
    [ -f "${SNAPSHOT}" ] || { echo "verify_secp256k1: --check but no snapshot at ${SNAPSHOT}; run without --check first." >&2; exit 1; }
    EXPECTED="$(awk '{print $1}' "${SNAPSHOT}")"
    if [ "${DIGEST}" != "${EXPECTED}" ]; then
        echo "verify_secp256k1: FATAL — staticlib SHA-256 drift!" >&2
        echo "  expected (snapshot): ${EXPECTED}" >&2
        echo "  actual   (rebuilt):  ${DIGEST}" >&2
        exit 1
    fi
    log "SHA-256 matches the recorded snapshot (artefact integrity OK)."
else
    echo "${DIGEST}  libknomosis_verify_secp256k1.a" > "${SNAPSHOT}"
    log "recorded SHA-256 snapshot -> ${SNAPSHOT}"
fi

# ------------------------------------------------------------------
# Restore the DEFAULT (fallback) knomosis binary on exit, so a local run
# never leaves a production-linked binary in .lake/build/bin.
# ------------------------------------------------------------------
restore_default() {
    log "restoring the default (fallback) knomosis binary ..."
    rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
    ( cd "${ROOT}" && lake build knomosis >/dev/null 2>&1 ) || true
}
trap restore_default EXIT

# ------------------------------------------------------------------
# 3. Sanity (the distinguishing baseline): the DEFAULT build must FAIL
#    closed (verify-check exit 1).  Without this the exit-0 assertion
#    below could pass vacuously.
# ------------------------------------------------------------------
log "building the DEFAULT (fallback) knomosis ..."
rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
lake build knomosis >/dev/null 2>&1
if .lake/build/bin/knomosis verify-check >/dev/null 2>&1; then
    echo "verify_secp256k1: FATAL — the DEFAULT build's verify-check exited 0; the gate is not fail-closed." >&2
    exit 1
fi
log "default verify-check exits 1 (fallback, fail-closed) — as required."

# ------------------------------------------------------------------
# 4. F-2(b): build knomosis with the production verifier linked and
#    assert verify-check now exits 0.
# ------------------------------------------------------------------
log "building knomosis with the production secp256k1 verifier linked ..."
rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
KNOMOSIS_VERIFY_STATICLIB="${VERIFY_A}" lake build knomosis >/dev/null 2>&1
if ! .lake/build/bin/knomosis verify-check; then
    echo "verify_secp256k1: FATAL — production-linked verify-check exited non-zero." >&2
    exit 1
fi
log "production-linked verify-check exits 0 (production verifier) — F-2(b) verified."

log "PASSED — secp256k1 verifier links; verify-check flips fallback(1) -> production(0)."

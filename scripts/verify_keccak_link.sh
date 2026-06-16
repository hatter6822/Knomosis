#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

#
# Production keccak256-hash link verification (security-review F-1 / F-2).
#
# The Lean kernel is hash-AGNOSTIC: the `Runtime.Hash.hashBytes` trust
# assumption (TA-2) surfaces as an `@[extern "knomosis_hash_bytes"]`
# swap-point, and the deployment-facing `hashImplementationIdentifier`
# is an `@[extern "knomosis_hash_identifier"]` whose default body is the
# Lean fallback FNV-1a-64 identifier (so `lake build` / `lake test` run
# standalone and `knomosis hash-check` fails CLOSED — exit 1 — refusing
# to deploy on the 64-bit FNV fallback, which a fault-proof adversary
# could collide with ~2^32 work — F-1).
#
# This script is the keccak/hash counterpart of
# `scripts/verify_secp256k1_link.sh` (which closes the verifier F-2 loop)
# and the artefact-pin half that `scripts/verify_keccak_crossstack.sh`
# (Lean<->EVM byte-equivalence) does NOT do.  It closes the F-1/F-2 loop
# for the hash adaptor end-to-end:
#
#   F-2(a) artefact integrity (SHA-256 record / verify).  It records the
#   SHA-256 of the just-built production keccak256 staticlib to a
#   snapshot, and (in --check mode) re-verifies a prior snapshot, so a
#   deployment can pin the exact hash artefact it links and detect any
#   drift (a swapped / tampered adaptor) before deploy.  This is the
#   keccak peer of the `verify-adaptor.sha256` pin the verifier script
#   records; together they pin BOTH FFI cdylibs named in the F-2
#   residual (security-review §7 / `docs/testnet_readiness.md` §3.2).
#
#   F-1(b) production link.  It builds the REAL keccak256 adaptor
#   staticlib (`knomosis-hash-keccak256`, backed by the audited `sha3`
#   crate) WITH the Lean FFI shim, links it into the `knomosis` binary IN
#   PLACE OF the FNV fallback (via the lakefile `knomosisHashFallback`
#   extern_lib + `KNOMOSIS_HASH_BACKEND=keccak256` /
#   `KNOMOSIS_KECCAK_STATICLIB`), and asserts that `knomosis hash-check`
#   now exits 0 with the PRODUCTION identifier.  It ALSO asserts the
#   default (fallback) build still exits 1 — so the gate genuinely
#   DISTINGUISHES production from fallback rather than passing vacuously.
#
# Division of labour: this script pins the artefact + proves the
# `hash-check` identifier flip; the FUNCTIONAL proof that the linked
# bytes are real keccak256 (byte-equal to the EVM `keccak256` opcode) is
# `scripts/verify_keccak_crossstack.sh`.
#
# Requires: elan (lean / lake), cargo (rust 1.83), nm, sha256sum.  Pure
# orchestration; no source edits.
#
# Usage:
#   scripts/verify_keccak_link.sh            # build + record + prove
#   scripts/verify_keccak_link.sh --check    # build + VERIFY snapshot + prove
#
# Exit codes:
#   0  production hash links and `hash-check` flips fallback(1)->prod(0)
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

need() { command -v "$1" >/dev/null 2>&1 || { echo "verify_keccak_link: missing required tool: $1" >&2; exit 2; }; }
need lean
need lake
need cargo
need nm
need sha256sum

log() { echo "verify_keccak_link: $*"; }

# ------------------------------------------------------------------
# 1. Build the keccak256 adaptor staticlib WITH the Lean FFI shim, into
#    a DEDICATED isolated target dir.  The shim materialises the
#    `knomosis_hash_*` C-ABI symbols only when `build.rs` finds `lean.h`;
#    a plain `cargo build`/`test` of the crate (no LEAN_SYSROOT) would
#    otherwise clobber the shared `.a` with a no-shim build while cargo's
#    fingerprint still reports the lean-ffi build up-to-date — making this
#    verification silently vacuous.  An isolated, rm-rf'd target dir is
#    never clobbered by other cargo invocations and forces the C-shim
#    object (and its lean.h discovery) to rebuild from scratch each run.
#    `--release` because this pins the PRODUCTION artefact (a deployment
#    links the release staticlib); the cross-stack equivalence script
#    builds debug for its own corpus run.
# ------------------------------------------------------------------
LEAN_PREFIX="$(lean --print-prefix)"
log "lean prefix: ${LEAN_PREFIX}"
KECCAK_TARGET="${ROOT}/runtime/target/keccak-ffi-link"
rm -rf "${KECCAK_TARGET}"
log "building knomosis-hash-keccak256 staticlib (--features lean-ffi --release) ..."
( cd runtime && LEAN_SYSROOT="${LEAN_PREFIX}" CARGO_TARGET_DIR="${KECCAK_TARGET}" \
    cargo build -p knomosis-hash-keccak256 --features lean-ffi --release )

KECCAK_A="${KECCAK_TARGET}/release/libknomosis_hash_keccak256.a"
[ -f "${KECCAK_A}" ] || { echo "verify_keccak_link: staticlib not produced: ${KECCAK_A}" >&2; exit 1; }

# The `lean-ffi` feature MUST have built the C shim (else `lean.h` was not
# found and the Lean-ABI symbols are absent — a silently-vacuous build).
# Capture `nm` into a variable rather than piping into `grep -q`: under
# `set -o pipefail`, `grep -q`'s early exit makes the large `nm` producer
# take SIGPIPE, which would report the pipeline as failed even on a match.
nm_syms="$(nm "${KECCAK_A}" 2>/dev/null || true)"
for sym in knomosis_hash_bytes knomosis_hash_stream knomosis_hash_identifier; do
    if ! grep -qE "\\bT ${sym}\\b" <<<"${nm_syms}"; then
        echo "verify_keccak_link: staticlib does not export '${sym}' — the Lean FFI shim was not built (lean.h not found?)." >&2
        exit 1
    fi
done
log "staticlib exports the three knomosis_hash_* Lean-ABI symbols."

# ------------------------------------------------------------------
# 2. F-2(a): record / verify the staticlib SHA-256.  The snapshot lives
#    under the gitignored target dir; a deployment copies it into its
#    own pinned-artefact manifest.  --check fails on ANY drift.
# ------------------------------------------------------------------
SNAPSHOT="${ROOT}/runtime/target/hash-keccak256-adaptor.sha256"
DIGEST="$(sha256sum "${KECCAK_A}" | awk '{print $1}')"
log "keccak256 adaptor SHA-256: ${DIGEST}"
if [ "${MODE}" = "check" ]; then
    [ -f "${SNAPSHOT}" ] || { echo "verify_keccak_link: --check but no snapshot at ${SNAPSHOT}; run without --check first." >&2; exit 1; }
    EXPECTED="$(awk '{print $1}' "${SNAPSHOT}")"
    if [ "${DIGEST}" != "${EXPECTED}" ]; then
        echo "verify_keccak_link: FATAL — staticlib SHA-256 drift!" >&2
        echo "  expected (snapshot): ${EXPECTED}" >&2
        echo "  actual   (rebuilt):  ${DIGEST}" >&2
        exit 1
    fi
    log "SHA-256 matches the recorded snapshot (artefact integrity OK)."
else
    echo "${DIGEST}  libknomosis_hash_keccak256.a" > "${SNAPSHOT}"
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
#    closed (hash-check exit 1).  Without this the exit-0 assertion below
#    could pass vacuously.
# ------------------------------------------------------------------
log "building the DEFAULT (fallback) knomosis ..."
rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
lake build knomosis >/dev/null 2>&1
if .lake/build/bin/knomosis hash-check >/dev/null 2>&1; then
    echo "verify_keccak_link: FATAL — the DEFAULT build's hash-check exited 0; the gate is not fail-closed." >&2
    exit 1
fi
log "default hash-check exits 1 (FNV-1a-64 fallback, fail-closed) — as required."

# ------------------------------------------------------------------
# 4. F-1(b): build knomosis with the production keccak256 hash linked and
#    assert hash-check now exits 0.  `KNOMOSIS_HASH_BACKEND=keccak256`
#    makes the lakefile `knomosisHashFallback` extern_lib swap the FNV
#    fallback for the staticlib at `KNOMOSIS_KECCAK_STATICLIB`, whose
#    `knomosis_hash_identifier` returns the production identifier, so
#    `isProductionHash` flips true and hash-check exits 0.
# ------------------------------------------------------------------
log "building knomosis with the production keccak256 hash linked ..."
rm -f "${ROOT}/.lake/build/bin/knomosis" 2>/dev/null || true
KNOMOSIS_HASH_BACKEND=keccak256 KNOMOSIS_KECCAK_STATICLIB="${KECCAK_A}" \
    lake build knomosis >/dev/null 2>&1
if ! .lake/build/bin/knomosis hash-check; then
    echo "verify_keccak_link: FATAL — production-linked hash-check exited non-zero (identifier still fallback?)." >&2
    exit 1
fi
log "production-linked hash-check exits 0 (production keccak256 identifier) — F-1(b) verified."

log "PASSED — keccak256 hash links; hash-check flips fallback(1) -> production(0)."

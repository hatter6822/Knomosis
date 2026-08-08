#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

#
# Keccak-linked cross-stack verification (the continuous counterpart to
# the manual "throwaway build" the workstream plans describe).
#
# The Lean kernel is hash-AGNOSTIC: `hashBytes` is an `@[extern]`
# swap-point whose default body is the dependency-free FNV-1a-64 fallback
# (so `lake build` / `lake test` run standalone).  Every hash-bound
# cross-stack corpus (`keccak256.json`, the deposit-receipt / fee-split /
# BOLD receiptHash corpora, the SMT corpus, the block-header goldens, ...)
# is generated under that fallback by default and its keccak-dependent
# assertions are gated off (`isKeccak256Linked = false`).
#
# This script closes the loop: it links the REAL keccak256 adaptor
# (`knomosis-hash-keccak256`, backed by the audited `sha3` crate) into the
# Lean test driver IN PLACE OF the fallback, regenerates the corpora with
# `isKeccak256Linked = true`, and runs the Solidity consumers so their
# keccak-gated byte-equivalence assertions execute against the EVM
# `keccak256` opcode.  A green run is a direct, end-to-end proof that
# Lean's hashing == the EVM's, byte-for-byte, across every corpus.
#
# The COMMITTED corpora stay on the FNV default: this script regenerates
# them only ephemerally and restores them on exit (so a local run never
# dirties the tree; CI checks out fresh anyway).
#
# Requires: elan (lean), cargo (rust 1.83), foundry (forge).  Pure
# orchestration; no source edits.
#
# Exit codes:
#   0  Lean<->EVM keccak equivalence verified across all corpora
#   1  a build / link / equivalence step failed
#   2  a required toolchain is missing

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Source toolchain envs (tolerate already-on-PATH; guard `set -u`).
set +u
# shellcheck disable=SC1090,SC1091
[ -f "${HOME}/.elan/env" ] && source "${HOME}/.elan/env"
# shellcheck disable=SC1090,SC1091
[ -f "${HOME}/.cargo/env" ] && source "${HOME}/.cargo/env"
set -u

need() { command -v "$1" >/dev/null 2>&1 || { echo "verify_keccak: missing required tool: $1" >&2; exit 2; }; }
need lean
need lake
need cargo
need forge

log() { echo "verify_keccak: $*"; }

# ------------------------------------------------------------------
# 1. Build the keccak256 adaptor staticlib WITH the Lean FFI shim.
#    The shim (`c/lean_shim.c`) is compiled only when `lean.h` is
#    locatable, which is what materialises the `knomosis_hash_*` C-ABI
#    symbols.  Point the crate's `build.rs` at the toolchain's headers.
# ------------------------------------------------------------------
LEAN_PREFIX="$(lean --print-prefix)"
log "lean prefix: ${LEAN_PREFIX}"
log "building knomosis-hash-keccak256 staticlib (--features lean-ffi) ..."
# Build into a DEDICATED, gitignored target dir under `runtime/target/`
# rather than the shared `target/debug`.  The Lean-ABI symbols are present
# only when `build.rs` finds `lean.h`; a plain `cargo test`/`build` of the
# crate (no LEAN_SYSROOT) would otherwise clobber the shared `.a` with a
# no-shim build while cargo's fingerprint still reports the lean-ffi build
# up-to-date — making this verification silently vacuous.  An isolated
# target dir is never clobbered by other cargo invocations.
KECCAK_TARGET="${ROOT}/runtime/target/keccak-ffi-verify"
# Clean the isolated dir so the C-shim object (and its lean.h discovery) is
# rebuilt from scratch every run — a build-script cache that recorded a
# "lean.h not found" state would otherwise persist and silently omit the
# Lean-ABI symbols.  The dir is small + dedicated, so this is cheap.
rm -rf "${KECCAK_TARGET}"
( cd runtime && LEAN_SYSROOT="${LEAN_PREFIX}" CARGO_TARGET_DIR="${KECCAK_TARGET}" \
    cargo build -p knomosis-hash-keccak256 --features lean-ffi )

KECCAK_A="${KECCAK_TARGET}/debug/libknomosis_hash_keccak256.a"
[ -f "${KECCAK_A}" ] || { echo "verify_keccak: staticlib not produced: ${KECCAK_A}" >&2; exit 1; }
# The `lean-ffi` feature MUST have built the C shim (else `lean.h` was not
# found and the Lean-ABI symbols are absent — a silently-vacuous build).
# Capture `nm` into a variable rather than piping into `grep -q`: under
# `set -o pipefail`, `grep -q`'s early exit makes the large `nm` producer
# take SIGPIPE, which would report the pipeline as failed even on a match.
nm_syms="$(nm "${KECCAK_A}" 2>/dev/null || true)"
if ! grep -qE '\bT knomosis_hash_bytes\b' <<<"${nm_syms}"; then
    echo "verify_keccak: staticlib does not export 'knomosis_hash_bytes' — the Lean FFI shim was not built (lean.h not found?)." >&2
    exit 1
fi
log "staticlib exports the three knomosis_hash_* Lean-ABI symbols."

# ------------------------------------------------------------------
# Corpus hygiene on exit -- and the drift CHECK that replaced a claim.
#
# This used to be an unconditional `git checkout --` of the corpora,
# justified by a comment saying the regeneration "reproduces exactly
# what is already committed" so the restore "is a no-op diff".
#
# That is true only while the code does not change corpus CONTENT, and
# nothing verified it.  When it stopped being true the script did the
# worst available thing: it regenerated the corpora, ran the Solidity
# consumers against the REGENERATED bytes, reported
# "PASSED -- byte-equivalence verified", and then deleted the evidence
# on the way out.  The committed corpora stayed stale, a bare
# `forge test` failed on them, and this lane said the tree was fine.
# A gate that discards its own output and reports success is worse than
# no gate, because it is believed.
#
# The claim is now CHECKED instead of asserted:
#
#   * a run that does not reach the regeneration step restores the
#     corpora, which is the guard's real purpose -- an interrupted or
#     failed run must not leave half-written fixtures behind;
#   * a run that DOES complete the regeneration leaves the files in
#     place and compares them against the index.  No diff means the
#     committed corpora already agreed with the code, which is what the
#     old comment asserted.  A diff means they did not, and that is a
#     RESULT, not a mess to tidy: the script fails, names the files, and
#     leaves the regenerated bytes on disk to be inspected and
#     committed.
# ------------------------------------------------------------------
CORPUS_PATHS=(solidity/test/CrossCheck/fixtures solidity/test/goldens)
# Set to 1 once the regeneration below completes; until then any exit
# is an abnormal one and the corpora are restored.
REGEN_COMPLETE=0

on_exit() {
    local rc=$?
    if [ "${REGEN_COMPLETE}" -ne 1 ]; then
        # Interrupted or failed before the corpora were fully written.
        git checkout -- "${CORPUS_PATHS[@]}" 2>/dev/null || true
        return "${rc}"
    fi
    local drifted
    drifted="$(git status --porcelain -- "${CORPUS_PATHS[@]}")"
    if [ -n "${drifted}" ]; then
        echo "verify_keccak: FATAL — the committed corpora do not match what this" >&2
        echo "verify_keccak: code generates.  Regenerating under real keccak256" >&2
        echo "verify_keccak: changed:" >&2
        echo "${drifted}" >&2
        echo "verify_keccak:" >&2
        echo "verify_keccak: The regenerated bytes are left on disk.  Review the" >&2
        echo "verify_keccak: diff and commit it in the same change that moved the" >&2
        echo "verify_keccak: corpus content.  Consumers read the COMMITTED bytes," >&2
        echo "verify_keccak: so a run that regenerated and then discarded them" >&2
        echo "verify_keccak: would be verifying something nobody ships." >&2
        return 1
    fi
    return "${rc}"
}
trap on_exit EXIT

export KNOMOSIS_HASH_BACKEND=keccak256
export KNOMOSIS_KECCAK_STATICLIB="${KECCAK_A}"

# ------------------------------------------------------------------
# 2. Build the Lean test driver with the keccak adaptor linked (the
#    lakefile's `knomosisHashFallback` extern_lib swaps to the staticlib
#    when KNOMOSIS_HASH_BACKEND=keccak256).
# ------------------------------------------------------------------
log "building the Lean test driver keccak-linked ..."
lake build Tests

# ------------------------------------------------------------------
# 3. Regenerate the cross-stack corpora with keccak (overwrite mode).
#    KNOMOSIS_HASH_BACKEND is also read at RUNTIME by the leak-detection
#    test so it skips in this intended keccak build.
# ------------------------------------------------------------------
log "regenerating corpora under real keccak256 ..."
KNOMOSIS_FIXTURES_OVERWRITE=1 .lake/build/bin/Tests
# The corpora are now fully written; from here an exit checks them for
# drift rather than discarding them.
REGEN_COMPLETE=1

# ------------------------------------------------------------------
# 4. Assert the linking actually took.  Without this, a failed link that
#    silently fell back to FNV would make every gated check skip and the
#    job pass vacuously.
# ------------------------------------------------------------------
if ! grep -q '"isKeccak256Linked":true' solidity/test/CrossCheck/fixtures/keccak256.json; then
    echo "verify_keccak: FATAL — corpora are not keccak-linked (isKeccak256Linked != true)." >&2
    echo "verify_keccak: the keccak adaptor did not override the FNV fallback; aborting." >&2
    exit 1
fi
log "corpora regenerated with isKeccak256Linked=true (real keccak256)."

# ------------------------------------------------------------------
# 5. Run the Solidity consumers.  Every keccak-gated cross-check
#    (keccak256, deposit-receipt / fee-split / BOLD receiptHash, SMT,
#    block-header goldens, ...) now RUNS instead of skipping and asserts
#    byte-equivalence against the EVM keccak256 opcode.
# ------------------------------------------------------------------
log "running the Solidity consumers against the keccak corpora ..."
# --gas-limit: the step-VM `test_perEntry_byte_equivalence_all_happy`
# (skipped under FNV) re-executes every happy fixture against
# `executeStep` in ONE call; under keccak it exceeds forge's default
# 2^30 per-call gas cap, so raise it (a legitimate hash-equivalence test,
# not a correctness failure).
( cd solidity && forge test --gas-limit 50000000000 )

log "PASSED — Lean<->EVM keccak256 byte-equivalence verified across all corpora."

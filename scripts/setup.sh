#!/usr/bin/env bash
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

#
# Knomosis — A Legal Kernel
# Lean 4 environment setup script.
#
# Adapted from Orbcrypt's `setup_lean_env.sh`
# (https://github.com/hatter6822/Orbcrypt/blob/main/scripts/setup_lean_env.sh)
# with the Mathlib-cache machinery stripped out: Knomosis's kernel is
# `Std`-only by Genesis-Plan §13.1, so there is no Mathlib precompiled
# cache to download.
#
# What this script does, in order:
#
#   1. Reads `lean-toolchain` to learn which Lean release the project pins.
#   2. Fast-paths if the toolchain is already installed AND its on-disk
#      `bin/lean` / `bin/lake` content hashes match the snapshot recorded
#      at install time (defense-in-depth integrity check, see
#      `bin_sha256_snapshot_*`).
#   3. Otherwise, downloads the Lean toolchain archive from the GitHub
#      release (NOT the unauthenticated `release.lean-lang.org` mirror)
#      and verifies its SHA-256 against the per-architecture pin baked
#      into this script.
#   4. Optionally downloads the `elan` toolchain manager (also SHA-256
#      pinned) so the user can switch toolchains later.
#   5. Records a content-hash snapshot of the freshly-installed
#      `bin/lean` / `bin/lake` so step 2 can detect post-install
#      modification on subsequent runs.
#
# Flags:
#   --quiet, -q       suppress informational logs (errors still print).
#   --build           run `lake build` after setup finishes.
#   --skip-solidity   skip Foundry / solc installation (Lean-only setup).
#   --solidity-only   ONLY install Foundry / solc (skip Lean toolchain).
#
# By default, the script installs BOTH the Lean toolchain AND the
# Solidity toolchain (Foundry + solc + OpenZeppelin / forge-std vendored
# deps).  Use `--skip-solidity` for a Lean-only environment, or
# `--solidity-only` for a Solidity-only environment.
#
# Exit codes:
#   0    success
#   1    any verification failed, or a hard prerequisite (curl, lean-toolchain)
#        is missing
#
# To bump the pinned Lean version:
#   1. Edit `lean-toolchain`.
#   2. Recompute the four `LEAN_TOOLCHAIN_SHA256_*` constants below.  The
#      commands are documented inline next to the constants.
#   3. Edit the SHA-256 audit log near the top of this script.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=0
BUILD_REQUESTED=0
SKIP_SOLIDITY=0
SOLIDITY_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --quiet|-q)       QUIET=1 ;;
    --build)          BUILD_REQUESTED=1 ;;
    --skip-solidity)  SKIP_SOLIDITY=1 ;;
    --solidity-only)  SOLIDITY_ONLY=1 ;;
    -h|--help)
      sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's|^# \?||'
      exit 0
      ;;
    *)
      echo "error: unknown argument '${arg}'" >&2
      echo "       run with --help for usage" >&2
      exit 1
      ;;
  esac
done
if [ "${SKIP_SOLIDITY}" -eq 1 ] && [ "${SOLIDITY_ONLY}" -eq 1 ]; then
  echo "error: --skip-solidity and --solidity-only are mutually exclusive" >&2
  exit 1
fi
log() { if [ "${QUIET}" -eq 0 ]; then echo "$@"; fi; }

# Elapsed-time helper for performance diagnostics (cheap; avoids `bc`
# unless available).
SETUP_START_TIME="${EPOCHREALTIME:-$(date +%s)}"
log_elapsed() {
  local now="${EPOCHREALTIME:-$(date +%s)}"
  local elapsed
  if command -v bc >/dev/null 2>&1; then
    elapsed="$(echo "${now} - ${SETUP_START_TIME}" | bc)"
  else
    elapsed="$(( ${now%.*} - ${SETUP_START_TIME%.*} ))"
  fi
  log "[setup +${elapsed}s] $*"
}

ELAN_HOME_DEFAULT="${HOME}/.elan"
ELAN_HOME_DIR="${ELAN_HOME:-$ELAN_HOME_DEFAULT}"
ELAN_ENV_FILE="${ELAN_HOME_DIR}/env"
LEAN_TOOLCHAIN_FILE="${ROOT_DIR}/lean-toolchain"

# -------- Pinned download integrity audit log --------
#
# Every URL the script will hit is content-pinned with SHA-256.  The
# constants below were re-computed against the GitHub release tarballs
# of each artefact and committed alongside the toolchain bump that
# introduced them.  Bumping any URL or version requires updating the
# matching SHA-256 *in the same commit*.

# elan installer (the shell script that bootstraps the elan binary).
# Pinned to a specific commit, NOT `master`, so an upstream re-write
# cannot retroactively change what this script trusts.
ELAN_INSTALLER_URL="https://raw.githubusercontent.com/leanprover/elan/87f5ec2f5627dd3df16b346733147412c3ddeef1/elan-init.sh"
ELAN_INSTALLER_SHA256="4bacca9502cb89736fe63d2685abc2947cfbf34dc87673504f1bb4c43eda9264"

# elan binary release.  v4.2.1 is the latest stable elan as of the
# v4.29.1 toolchain bump.
ELAN_BINARY_VERSION="v4.2.1"
ELAN_BINARY_SHA256_X86="4e717523217af592fa2d7b9c479410a31816c065d66ccbf0c2149337cfec0f5c"
ELAN_BINARY_SHA256_ARM="bb78726ace6a912c7122a389018bcd69d9122ce04659800101392f7db380d3b3"

# Lean toolchain archives.  To regenerate after a version bump:
#   v="$(cut -d: -f2 lean-toolchain)"  # e.g. v4.29.1
#   for arch in linux linux_aarch64; do
#     for ext in tar.zst zip; do
#       curl -fsSL "https://github.com/leanprover/lean4/releases/download/${v}/lean-${v#v}-${arch}.${ext}" \
#         | sha256sum
#     done
#   done
# Pinned to the v4.29.1 release (latest stable as of 2026-04-16).
LEAN_TOOLCHAIN_SHA256_ZST_X86="bf062d29556d655685fb287563c249ad6a8fde34352c18b5e32568a595c1aec1"
LEAN_TOOLCHAIN_SHA256_ZST_ARM="1ccdfb7f924901f4b73a4b4eb169e5b3dc74f6836521b47e733ea25f2abfc0dc"
LEAN_TOOLCHAIN_SHA256_ZIP_X86="357acb30fca2212986fdc8b83dbe88e8f5610efc060f6e3515079c56a92d276f"
LEAN_TOOLCHAIN_SHA256_ZIP_ARM="171cd3426c3f43ca49b5affad15633e4d9f1e983df536a208883097680872816"

# Foundry (forge / cast / anvil / chisel) toolchain.  Workstream E (the
# Solidity mirror of the kernel) needs `forge` to build / test the
# contracts under `solidity/`.  Pinned to v1.7.0; bumping requires
# recomputing the SHAs in the same commit.  Regenerate via:
#   for arch in amd64 arm64; do
#     curl -fsSL "https://github.com/foundry-rs/foundry/releases/download/v1.7.0/foundry_v1.7.0_linux_${arch}.tar.gz" \
#       | sha256sum
#   done
FOUNDRY_VERSION="v1.7.0"
FOUNDRY_SHA256_X86="88501301c43e2cb3231009e68bd76af17cc0f7e9981f9d37ceabc6b857febb2f"
FOUNDRY_SHA256_ARM="4be51b29d81f46f5f8913caf9b458db4b6f04f51565fbd59a0d11f69a4be2f77"

# solc 0.8.20 static binary (linux x86_64 only — the upstream v0.8.20
# release does not ship an ARM static binary; ARM users must build
# from source or install via package manager).  Bumping requires
# recomputing the SHA in the same commit; regenerate via:
#   curl -fsSL "https://github.com/ethereum/solidity/releases/download/v0.8.20/solc-static-linux" \
#     | sha256sum
SOLC_VERSION="v0.8.20"
SOLC_SHA256_X86="0479d44fdf9c501c25337fdc540419f1593b884a87b47f023da4f1c700fda782"

# -------- Parse toolchain spec --------
if [ ! -f "${LEAN_TOOLCHAIN_FILE}" ]; then
  echo "error: lean-toolchain not found at ${LEAN_TOOLCHAIN_FILE}" >&2
  exit 1
fi
TOOLCHAIN="$(tr -d '\n\r' < "${LEAN_TOOLCHAIN_FILE}")"
if [ -z "${TOOLCHAIN}" ]; then
  echo "error: ${LEAN_TOOLCHAIN_FILE} is empty" >&2
  exit 1
fi
# Validate spec format: org/repo:tag.  Reject anything else, since the
# value flows directly into curl URLs and elan toolchain identifiers.
if ! echo "${TOOLCHAIN}" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$'; then
  echo "error: lean-toolchain has malformed value '${TOOLCHAIN}'" >&2
  echo "       expected 'org/repo:tag' (e.g. leanprover/lean4:v4.29.1)" >&2
  exit 1
fi
TOOLCHAIN_ORG="$(echo "${TOOLCHAIN}" | cut -d/ -f1)"
TOOLCHAIN_REPO="$(echo "${TOOLCHAIN}" | cut -d/ -f2 | cut -d: -f1)"
TOOLCHAIN_TAG="$(echo "${TOOLCHAIN}" | cut -d: -f2)"
# elan normalises "org/repo:tag" -> "org-repo-tag" for directory names.
TOOLCHAIN_DIR_NAME="$(echo "${TOOLCHAIN}" | sed 's|/|-|g; s|:|-|g')"

# -------- SHA-256 helper --------
compute_sha256() {
  local target_file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${target_file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${target_file}" | awk '{print $1}'
  else
    echo "error: neither sha256sum nor shasum is available" >&2
    exit 1
  fi
}

# -------- Solidity toolchain install --------
#
# Idempotently installs the Foundry binaries (forge / cast / anvil /
# chisel) and the solc compiler, then runs the project's
# `vendor-deps.sh` to fetch the OpenZeppelin + forge-std submodules.
#
# Each artefact is content-pinned via SHA-256: a network MITM, an
# upstream release re-write, or a partial download all surface as a
# fatal error before the binary is moved into `${install_dir}`.
#
# Layout:
#   /usr/local/foundry/bin/{forge,cast,anvil,chisel}  (matches the
#                                                       project README)
#   /usr/local/bin/solc                                 (system PATH)
#   ${ROOT_DIR}/solidity/lib/{openzeppelin-contracts,forge-std}
#                                                       (vendored)
#
# Idempotency: a fast-path check verifies the installed binary's
# `--version` matches the pinned version.  If yes, the install is
# skipped.
do_solidity_install() {
  local arch_norm
  arch_norm="$(uname -m)"

  # Foundry pin selection.
  local foundry_archive_arch foundry_sha256
  case "${arch_norm}" in
    x86_64|amd64)
      foundry_archive_arch="amd64"
      foundry_sha256="${FOUNDRY_SHA256_X86}"
      ;;
    aarch64|arm64)
      foundry_archive_arch="arm64"
      foundry_sha256="${FOUNDRY_SHA256_ARM}"
      ;;
    *)
      echo "error: unsupported architecture for Foundry install: ${arch_norm}" >&2
      return 1
      ;;
  esac
  local foundry_url="https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_linux_${foundry_archive_arch}.tar.gz"
  local foundry_install_dir="/usr/local/foundry/bin"
  local solc_url="https://github.com/ethereum/solidity/releases/download/${SOLC_VERSION}/solc-static-linux"
  local solc_install_path="/usr/local/bin/solc"

  # ---- Foundry fast-path check ----
  if [ -x "${foundry_install_dir}/forge" ] && \
     "${foundry_install_dir}/forge" --version 2>/dev/null | grep -q "${FOUNDRY_VERSION}"; then
    log_elapsed "Foundry ${FOUNDRY_VERSION} is already installed (fast-path)"
  else
    log_elapsed "installing Foundry ${FOUNDRY_VERSION}"
    local tmp_archive
    tmp_archive="$(mktemp)"
    if ! curl -fsSL "${foundry_url}" -o "${tmp_archive}"; then
      rm -f "${tmp_archive}"
      echo "error: failed to download Foundry from ${foundry_url}" >&2
      return 1
    fi
    local got_sha
    got_sha="$(compute_sha256 "${tmp_archive}")"
    if [ "${got_sha}" != "${foundry_sha256}" ]; then
      rm -f "${tmp_archive}"
      echo "error: Foundry archive SHA-256 mismatch" >&2
      echo "  expected: ${foundry_sha256}" >&2
      echo "  got:      ${got_sha}" >&2
      return 1
    fi
    if [ -d "${foundry_install_dir}" ]; then
      rm -f "${foundry_install_dir}/forge" \
            "${foundry_install_dir}/cast" \
            "${foundry_install_dir}/anvil" \
            "${foundry_install_dir}/chisel"
    fi
    if ! mkdir -p "${foundry_install_dir}"; then
      rm -f "${tmp_archive}"
      echo "error: failed to create ${foundry_install_dir}" >&2
      return 1
    fi
    if ! tar xzf "${tmp_archive}" -C "${foundry_install_dir}"; then
      rm -f "${tmp_archive}"
      echo "error: failed to extract Foundry archive" >&2
      return 1
    fi
    rm -f "${tmp_archive}"
    chmod +x "${foundry_install_dir}/forge" \
             "${foundry_install_dir}/cast" \
             "${foundry_install_dir}/anvil" \
             "${foundry_install_dir}/chisel"
    log_elapsed "Foundry ${FOUNDRY_VERSION} installed at ${foundry_install_dir}"
  fi

  # Ensure foundry bins are on PATH for any subsequent steps in this
  # invocation (vendor-deps.sh + downstream `forge build` etc.).
  case ":${PATH}:" in
    *":${foundry_install_dir}:"*) ;;
    *) export PATH="${foundry_install_dir}:${PATH}" ;;
  esac

  # ---- solc fast-path check ----
  if [ "${arch_norm}" = "x86_64" ] || [ "${arch_norm}" = "amd64" ]; then
    if [ -x "${solc_install_path}" ] && \
       "${solc_install_path}" --version 2>/dev/null | grep -q "${SOLC_VERSION#v}"; then
      log_elapsed "solc ${SOLC_VERSION} is already installed (fast-path)"
    else
      log_elapsed "installing solc ${SOLC_VERSION}"
      local tmp_solc
      tmp_solc="$(mktemp)"
      if ! curl -fsSL "${solc_url}" -o "${tmp_solc}"; then
        rm -f "${tmp_solc}"
        echo "error: failed to download solc from ${solc_url}" >&2
        return 1
      fi
      local got_solc_sha
      got_solc_sha="$(compute_sha256 "${tmp_solc}")"
      if [ "${got_solc_sha}" != "${SOLC_SHA256_X86}" ]; then
        rm -f "${tmp_solc}"
        echo "error: solc binary SHA-256 mismatch" >&2
        echo "  expected: ${SOLC_SHA256_X86}" >&2
        echo "  got:      ${got_solc_sha}" >&2
        return 1
      fi
      mv "${tmp_solc}" "${solc_install_path}"
      chmod +x "${solc_install_path}"
      log_elapsed "solc ${SOLC_VERSION} installed at ${solc_install_path}"
    fi
  else
    echo "warning: solc static binary is x86_64-only; ARM users must" >&2
    echo "         build solc from source or install via system pkg" >&2
    echo "         manager (e.g. ethereum/ethereum PPA on Debian)." >&2
  fi

  # ---- Vendor OpenZeppelin + forge-std ----
  if [ -x "${ROOT_DIR}/solidity/scripts/vendor-deps.sh" ]; then
    log_elapsed "vendoring OpenZeppelin + forge-std"
    if ! "${ROOT_DIR}/solidity/scripts/vendor-deps.sh" >/dev/null 2>&1; then
      log_elapsed "warning: vendor-deps.sh failed; forge build will not link"
      return 1
    fi
    log_elapsed "Solidity dependencies vendored"
  else
    log_elapsed "skipping vendor-deps.sh (script not found or not executable)"
  fi

  log_elapsed "Solidity environment is ready"
}

# -------- Defense-in-depth: toolchain binary integrity snapshot --------
#
# After a fresh install (where the archive's SHA-256 was verified
# against the per-arch pin), we record the SHA-256 of the actually-
# installed `bin/lean` and `bin/lake` to a marker file.  On every
# subsequent fast-path entry, we recompute those SHAs and compare.
#
# Catches: accidental modification (system update, partial copy,
# filesystem corruption) and one class of malicious tampering
# (attacker who modifies `bin/lean` without also rewriting the marker).
#
# Does NOT catch: an attacker with write access to *both* the toolchain
# directory and the marker can stay consistent and bypass.  At that
# point the threat model is already game-over (the attacker can
# replace `bin/lean` directly), so this guard is defense-in-depth, not
# a substitute for filesystem-level access controls.
#
# The marker lives at `${tc_dir}/.bin_sha256.lock` so that
# `rm -rf "${tc_dir}"` (the destructive recovery path) wipes both the
# binaries and the snapshot atomically.
TOOLCHAIN_MARKER_FILENAME=".bin_sha256.lock"
TOOLCHAIN_PROTECTED_BINS=("bin/lean" "bin/lake")

bin_sha256_snapshot_create() {
  local tc_dir="$1"
  local marker="${tc_dir}/${TOOLCHAIN_MARKER_FILENAME}"
  if [ -f "${marker}" ]; then
    return 0
  fi
  local rel sha tmp
  # mktemp inside the toolchain dir so the final `mv` is atomic on
  # the same filesystem.  Each concurrent invocation gets its own
  # scratch file → last-writer-wins, no partial-content races.
  tmp="$(mktemp "${marker}.XXXXXX.tmp")" || {
    log_elapsed "warning: mktemp failed for ${marker}; skipping snapshot"
    return 1
  }
  for rel in "${TOOLCHAIN_PROTECTED_BINS[@]}"; do
    if [ ! -f "${tc_dir}/${rel}" ]; then
      log_elapsed "warning: ${rel} missing under ${tc_dir}; skipping snapshot"
      rm -f "${tmp}"
      return 1
    fi
    sha="$(compute_sha256 "${tc_dir}/${rel}")"
    printf '%s  %s\n' "${sha}" "${rel}" >> "${tmp}"
  done
  mv "${tmp}" "${marker}"
  log_elapsed "toolchain binary snapshot recorded (${marker})"
  return 0
}

bin_sha256_snapshot_verify() {
  # Returns:
  #   0  marker present and every recorded SHA matches → fast-path OK.
  #   1  marker absent → caller may take a snapshot now.
  #   2  any binary mismatch OR a protected binary missing from the
  #      marker (an attacker who deletes a marker line should not be
  #      able to silently disable verification of that binary).
  local tc_dir="$1"
  local marker="${tc_dir}/${TOOLCHAIN_MARKER_FILENAME}"
  if [ ! -f "${marker}" ]; then
    return 1
  fi
  local rel sha expected
  for rel in "${TOOLCHAIN_PROTECTED_BINS[@]}"; do
    if [ ! -f "${tc_dir}/${rel}" ]; then
      echo "error: ${rel} missing under ${tc_dir}; integrity check failed" >&2
      return 2
    fi
    expected="$(awk -v r="${rel}" '$2 == r {print $1; exit}' "${marker}")"
    if [ -z "${expected}" ]; then
      echo "error: ${rel} not recorded in ${marker}; marker may have been tampered" >&2
      echo "  toolchain at ${tc_dir} integrity cannot be confirmed" >&2
      echo "  delete ${tc_dir} and re-run this script to recover from a verified archive" >&2
      return 2
    fi
    sha="$(compute_sha256 "${tc_dir}/${rel}")"
    if [ "${sha}" != "${expected}" ]; then
      echo "error: ${rel} SHA-256 mismatch (expected ${expected}, got ${sha})" >&2
      echo "  toolchain at ${tc_dir} appears to have been modified post-install" >&2
      echo "  delete ${tc_dir} and re-run this script to recover from a verified archive" >&2
      return 2
    fi
  done
  return 0
}

# -------- Fast-path: skip setup if everything is already ready --------
fast_path_ready() {
  if [ -f "${ELAN_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ELAN_ENV_FILE}"
  fi
  command -v lake >/dev/null 2>&1 || return 1
  local tc_dir="${ELAN_HOME_DIR}/toolchains/${TOOLCHAIN_DIR_NAME}"
  [ -x "${tc_dir}/bin/lean" ] || return 1
  [ -f "${tc_dir}/lib/crti.o" ] || return 1

  # Three outcomes from the integrity snapshot:
  #   exit 0 — marker present and verifies → proceed.
  #   exit 1 — marker absent (e.g. predates this guard) → snapshot, proceed.
  #   exit 2 — genuine mismatch → FATAL.
  #
  # We must `exit 1` on case 2 (not `return 1`), otherwise the slow
  # path's `[ ! -x bin/lean ]` test would be false (the file *exists*,
  # just with the wrong content) and the script would silently accept
  # the tampered binaries.  Force the user through `rm -rf "${tc_dir}"`.
  local verify_status=0
  bin_sha256_snapshot_verify "${tc_dir}" || verify_status=$?
  case "${verify_status}" in
    0)  ;;
    1)  bin_sha256_snapshot_create "${tc_dir}" || true ;;
    *)  echo "error: toolchain integrity check failed" >&2
        echo "  see error messages above and remediate by deleting the toolchain:" >&2
        echo "    rm -rf \"${tc_dir}\"" >&2
        echo "  then re-run this script.  The reinstall path will redownload" >&2
        echo "  the archive and verify it against the SHA-256 pins in this" >&2
        echo "  script (\`LEAN_TOOLCHAIN_SHA256_*_{X86,ARM}\`)." >&2
        exit 1
        ;;
  esac
  return 0
}

if [ "${SOLIDITY_ONLY}" -eq 1 ]; then
  # Solidity-only setup: skip the Lean install entirely.
  log_elapsed "running --solidity-only setup"
  if ! do_solidity_install; then
    echo "error: Solidity install failed" >&2
    exit 1
  fi
  exit 0
fi

if fast_path_ready; then
  log_elapsed "Lean environment already configured (fast-path)"
  if [ "${SKIP_SOLIDITY}" -eq 0 ]; then
    if ! do_solidity_install; then
      echo "error: Solidity install failed" >&2
      exit 1
    fi
  fi
  if [ "${BUILD_REQUESTED}" -eq 1 ]; then
    log_elapsed "running lake build"
    (cd "${ROOT_DIR}" && lake build)
  fi
  exit 0
fi

log_elapsed "full environment setup required"

# -------- Prerequisite check --------
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required to install elan" >&2
  exit 1
fi

# -------- Package management helpers (used by the CRT-recovery path) --------
APT_UPDATE_DONE=0
run_pkg_install() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    "$@"
  fi
}
apt_update_once() {
  if [ "${APT_UPDATE_DONE}" -eq 0 ]; then
    if ! run_pkg_install apt-get update; then
      run_pkg_install apt-get update \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" || true
    fi
    APT_UPDATE_DONE=1
  fi
}

# -------- Toolchain archive verification --------
verify_toolchain_sha256() {
  local target_file="$1"
  local format="$2"
  local expected_sha=""
  case "$(uname -m)" in
    x86_64|amd64)
      if [ "${format}" = "zst" ]; then
        expected_sha="${LEAN_TOOLCHAIN_SHA256_ZST_X86}"
      else
        expected_sha="${LEAN_TOOLCHAIN_SHA256_ZIP_X86}"
      fi
      ;;
    aarch64|arm64)
      if [ "${format}" = "zst" ]; then
        expected_sha="${LEAN_TOOLCHAIN_SHA256_ZST_ARM}"
      else
        expected_sha="${LEAN_TOOLCHAIN_SHA256_ZIP_ARM}"
      fi
      ;;
  esac
  if [ -z "${expected_sha}" ]; then
    echo "error: no SHA-256 hash configured for architecture $(uname -m); aborting" >&2
    return 1
  fi
  local actual_sha
  actual_sha="$(compute_sha256 "${target_file}")"
  if [ "${actual_sha}" != "${expected_sha}" ]; then
    echo "error: Lean toolchain checksum verification failed" >&2
    echo "  expected: ${expected_sha}" >&2
    echo "  actual:   ${actual_sha}" >&2
    rm -f "${target_file}"
    exit 1
  fi
  log_elapsed "toolchain SHA-256 verified (${format})"
}

# -------- zstd install (optional; we fall back to .zip if missing) --------
install_zstd_if_needed() {
  if command -v zstd >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    if timeout 5 bash -c 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zstd 2>/dev/null' >/dev/null 2>&1; then
      log_elapsed "zstd installed"
    else
      log_elapsed "zstd not available; will use zip fallback"
    fi
  fi
}
install_zstd_if_needed

detect_arch_suffix() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64)  echo "" ;;
    aarch64|arm64) echo "_aarch64" ;;
    *) echo "error: unsupported architecture '${arch}'" >&2; exit 1 ;;
  esac
}

# -------- elan env file --------
ensure_elan_env_file() {
  if [ -f "${ELAN_ENV_FILE}" ]; then
    return 0
  fi
  mkdir -p "$(dirname "${ELAN_ENV_FILE}")"
  cat > "${ELAN_ENV_FILE}" << 'ENVEOF'
#!/bin/sh
# elan shell setup
case ":${PATH}:" in
    *:"${HOME}/.elan/bin":*)
        ;;
    *)
        export PATH="${HOME}/.elan/bin:${PATH}"
        ;;
esac
ENVEOF
}

# -------- Manual curl-based install (foreground; primary path) --------
manual_curl_install() {
  log_elapsed "manual curl-based install starting"

  local elan_bin_dir="${ELAN_HOME_DIR}/bin"
  local toolchain_dir="${ELAN_HOME_DIR}/toolchains/${TOOLCHAIN_DIR_NAME}"
  local arch_suffix
  arch_suffix="$(detect_arch_suffix)"
  local version_number="${TOOLCHAIN_TAG#v}"
  local lean_archive_name="lean-${version_number}-linux${arch_suffix}"

  mkdir -p "${elan_bin_dir}" "${ELAN_HOME_DIR}/toolchains"
  ensure_elan_env_file

  cat > "${ELAN_HOME_DIR}/settings.toml" << SETTINGSEOF
version = "12"
default_toolchain = "${TOOLCHAIN_DIR_NAME}"
SETTINGSEOF

  # Download elan binary in background for parallelism with the
  # (much larger) toolchain download below.
  local elan_bg_pid=""
  if [ ! -x "${elan_bin_dir}/elan" ]; then
    (
      local arch_name expected_sha
      case "$(uname -m)" in
        x86_64|amd64)
          arch_name="x86_64-unknown-linux-gnu"
          expected_sha="${ELAN_BINARY_SHA256_X86}"
          ;;
        aarch64|arm64)
          arch_name="aarch64-unknown-linux-gnu"
          expected_sha="${ELAN_BINARY_SHA256_ARM}"
          ;;
        *) exit 1 ;;
      esac
      local elan_tar
      elan_tar="$(mktemp)"
      curl -fsSL "https://github.com/leanprover/elan/releases/download/${ELAN_BINARY_VERSION}/elan-${arch_name}.tar.gz" -o "${elan_tar}"
      local actual_sha
      actual_sha="$(compute_sha256 "${elan_tar}")"
      if [ "${actual_sha}" != "${expected_sha}" ]; then
        echo "error: elan binary checksum verification failed" >&2
        rm -f "${elan_tar}"
        exit 1
      fi
      tar -xzf "${elan_tar}" -C "${elan_bin_dir}/" \
        && chmod +x "${elan_bin_dir}/elan-init"
      rm -f "${elan_tar}"
    ) &
    elan_bg_pid=$!
  fi

  # Install Lean toolchain (foreground — critical path).
  if [ ! -d "${toolchain_dir}/bin" ]; then
    log_elapsed "downloading Lean toolchain ${TOOLCHAIN}"
    if command -v zstd >/dev/null 2>&1; then
      local lean_tar lean_extracted
      lean_tar="$(mktemp)"
      trap 'rm -f "${lean_tar}"' EXIT
      curl -fsSL "https://github.com/${TOOLCHAIN_ORG}/${TOOLCHAIN_REPO}/releases/download/${TOOLCHAIN_TAG}/${lean_archive_name}.tar.zst" -o "${lean_tar}"
      verify_toolchain_sha256 "${lean_tar}" "zst"
      log_elapsed "extracting toolchain (zstd)"
      lean_extracted="$(mktemp).tar"
      zstd -d "${lean_tar}" -o "${lean_extracted}"
      tar -xf "${lean_extracted}" -C "${ELAN_HOME_DIR}/toolchains/"
      rm -f "${lean_tar}" "${lean_extracted}"
      trap - EXIT
    else
      log_elapsed "zstd unavailable; using zip archive"
      local lean_zip
      lean_zip="$(mktemp)"
      trap 'rm -f "${lean_zip}"' EXIT
      curl -fsSL "https://github.com/${TOOLCHAIN_ORG}/${TOOLCHAIN_REPO}/releases/download/${TOOLCHAIN_TAG}/${lean_archive_name}.zip" -o "${lean_zip}"
      verify_toolchain_sha256 "${lean_zip}" "zip"
      if ! command -v unzip >/dev/null 2>&1; then
        echo "error: unzip is required when zstd is unavailable" >&2
        rm -f "${lean_zip}"
        exit 1
      fi
      unzip -qo "${lean_zip}" -d "${ELAN_HOME_DIR}/toolchains/"
      rm -f "${lean_zip}"
      trap - EXIT
    fi

    # Rename extracted directory to match elan's naming convention
    # (`org-repo-tag`) so `elan default ${TOOLCHAIN}` resolves it.
    local extracted_dir="${ELAN_HOME_DIR}/toolchains/${lean_archive_name}"
    if [ -d "${extracted_dir}" ] && [ "${extracted_dir}" != "${toolchain_dir}" ]; then
      mv "${extracted_dir}" "${toolchain_dir}"
    fi
    log_elapsed "Lean toolchain installed to ${toolchain_dir}"
  else
    log_elapsed "Lean toolchain already present at ${toolchain_dir}"
  fi

  # Wait for the background elan binary install to finish before we
  # try to use it.
  if [ -n "${elan_bg_pid}" ]; then
    if wait "${elan_bg_pid}" 2>/dev/null; then
      log_elapsed "elan binary download complete (SHA-256 verified)"
    else
      log_elapsed "warning: elan binary download failed; toolchain symlinks will be used instead"
    fi
  fi

  # Direct symlinks so lean / lake / leanc are on PATH immediately,
  # even if elan registration fails.
  for bin in lean lake leanc leanmake; do
    if [ -x "${toolchain_dir}/bin/${bin}" ] && [ ! -e "${elan_bin_dir}/${bin}" ]; then
      ln -sf "${toolchain_dir}/bin/${bin}" "${elan_bin_dir}/${bin}"
    fi
  done

  # shellcheck disable=SC1090
  source "${ELAN_ENV_FILE}"
  if command -v elan >/dev/null 2>&1; then
    elan toolchain link "${TOOLCHAIN}" "${toolchain_dir}" 2>/dev/null || true
    elan default "${TOOLCHAIN}" 2>/dev/null || true
  fi

  mkdir -p "${ELAN_HOME_DIR}/update-hashes"
  echo "manual-install" > "${ELAN_HOME_DIR}/update-hashes/${TOOLCHAIN_DIR_NAME}"
}

# -------- Main installation flow --------
source_elan_env() {
  if [ -f "${ELAN_ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ELAN_ENV_FILE}"
  fi
}

source_elan_env
TOOLCHAIN_FRESHLY_INSTALLED=0

local_tc_dir="${ELAN_HOME_DIR}/toolchains/${TOOLCHAIN_DIR_NAME}"
if [ ! -x "${local_tc_dir}/bin/lean" ]; then
  log_elapsed "installing Lean toolchain ${TOOLCHAIN} (direct download)"
  if manual_curl_install; then
    TOOLCHAIN_FRESHLY_INSTALLED=1
  else
    log_elapsed "direct install failed; falling back to elan installer"
    if ! command -v elan >/dev/null 2>&1; then
      log_elapsed "downloading elan installer"
      elan_installer="$(mktemp)"
      trap 'rm -f "${elan_installer}"' EXIT
      curl -fsSL "${ELAN_INSTALLER_URL}" -o "${elan_installer}"
      installer_sha256="$(compute_sha256 "${elan_installer}")"
      if [ "${installer_sha256}" != "${ELAN_INSTALLER_SHA256}" ]; then
        echo "error: elan installer checksum verification failed" >&2
        exit 1
      fi
      if ! sh "${elan_installer}" -y --no-modify-path; then
        echo "error: both direct install and elan installer failed" >&2
        exit 1
      fi
      rm -f "${elan_installer}"
      trap - EXIT
    fi
    ensure_elan_env_file
    source_elan_env
    if command -v elan >/dev/null 2>&1 && [ ! -d "${local_tc_dir}/bin" ]; then
      elan toolchain install "${TOOLCHAIN}" 2>/dev/null || true
    fi
    elan default "${TOOLCHAIN}" 2>/dev/null || true
    TOOLCHAIN_FRESHLY_INSTALLED=1
  fi
else
  log_elapsed "Lean toolchain ${TOOLCHAIN} is already installed"
fi

ensure_elan_env_file
source_elan_env

if ! command -v lake >/dev/null 2>&1; then
  echo "error: lake is still not on PATH after setup" >&2
  exit 1
fi

# -------- CRT startup files verification --------
# Some Lean release archives have shipped without `crti.o` / `crt1.o`
# (the C runtime startup stubs), which makes any `lake build` linking
# step fail.  Detect the case, redownload the toolchain once, then
# fall back to a system libc-dev install.
if [ "${TOOLCHAIN_FRESHLY_INSTALLED}" -eq 1 ]; then
  verify_crt_files() {
    local tc_dir="${ELAN_HOME_DIR}/toolchains/${TOOLCHAIN_DIR_NAME}"
    local missing=0
    for crt_file in crti.o crt1.o Scrt1.o; do
      if [ ! -f "${tc_dir}/lib/${crt_file}" ]; then
        missing=1
        break
      fi
    done
    if [ "${missing}" -eq 1 ]; then
      echo "[setup] warning: CRT startup files missing; re-downloading toolchain" >&2
      rm -rf "${tc_dir}"
      manual_curl_install
      source_elan_env
      for crt_file in crti.o crt1.o Scrt1.o; do
        if [ ! -f "${tc_dir}/lib/${crt_file}" ]; then
          echo "[setup] warning: ${crt_file} still missing; linking may fail" >&2
          if command -v apt-get >/dev/null 2>&1; then
            apt_update_once
            run_pkg_install env DEBIAN_FRONTEND=noninteractive apt-get install -y libc-dev 2>/dev/null || true
          fi
          return 1
        fi
      done
      log_elapsed "CRT files restored successfully"
    fi
    return 0
  }
  verify_crt_files

  # Now that the archive's SHA-256 was verified by
  # `verify_toolchain_sha256`, record a snapshot of the binaries'
  # content hashes for future fast-path verification.
  bin_sha256_snapshot_create "${ELAN_HOME_DIR}/toolchains/${TOOLCHAIN_DIR_NAME}" || true
fi

log_elapsed "Lean environment is ready"
log_elapsed "lake version: $(lake --version)"

if [ "${SKIP_SOLIDITY}" -eq 0 ]; then
  if ! do_solidity_install; then
    echo "error: Solidity install failed" >&2
    exit 1
  fi
fi

if [ "${QUIET}" -eq 0 ]; then
  echo "[setup] next steps:"
  echo "  source \"${ELAN_ENV_FILE}\""
  echo "  lake build"
  if [ "${SKIP_SOLIDITY}" -eq 0 ]; then
    echo "  export PATH=\"/usr/local/foundry/bin:\$PATH\""
    echo "  (cd solidity && forge test)"
  fi
fi

if [ "${BUILD_REQUESTED}" -eq 1 ]; then
  log_elapsed "running lake build"
  (cd "${ROOT_DIR}" && lake build)
fi

#!/usr/bin/env bash
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.
# This is free software, and you are welcome to redistribute it
# under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
#
# ============================================================================
#  deploy_sepolia_launch.sh — one-command VALUE-BEARING Sepolia launch
# ============================================================================
#
#  Chains the whole launch execution into a single, fail-fast, confirm-before-
#  broadcast command:
#
#    1. Load + validate the deploy env (every required value present, no
#       leftover `SET-THIS…` placeholder).
#    2. F-1 / F-2 trust-binding gate (scripts/verify_release_crypto.sh) — a
#       fallback hash / signature verifier must NEVER reach a value-bearing
#       deploy.  REQUIRED; skippable only with --skip-crypto-gate.
#    3. In-memory dry-run (make deploy-sepolia-dryrun) — catches every config
#       error (bad quorum, cap ordering, missing role) WITHOUT spending gas.
#    4. Confirm (interactive, unless --yes), then the REAL Sepolia broadcast +
#       Etherscan source-verification (make deploy-sepolia).
#    5. Print the emitted addresses manifest.
#    6. Optionally bring up the L2 daemon stack against it (--with-l2-stack).
#
#  USAGE
#    ./scripts/deploy_sepolia_launch.sh [ENV_FILE] [flags]
#
#    ENV_FILE            Path to the filled deploy env (default:
#                        solidity/deploy.sepolia.env).  Start from
#                        solidity/deploy.sepolia.env.example.
#
#    --dry-run           Stop after the dry-run; never broadcast.
#    --yes               Skip the interactive pre-broadcast confirmation.
#    --with-l2-stack     After a successful deploy, run
#                        scripts/knomosis_l2_sepolia_stack.sh against the
#                        emitted manifest.
#    --skip-crypto-gate  Skip the F-1/F-2 gate (NOT recommended; for a rerun
#                        where you already proved it green this session).
#    -h | --help         This help.
#
#  See docs/launch_execution_checklist.md for the full pre/post-flight
#  checklist and docs/sepolia_deployment_runbook.md for the reference
#  procedure this wraps.
# ============================================================================

set -euo pipefail

# --- locate the repo root (this script lives in <root>/scripts/) -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ROOT}/solidity/deploy.sepolia.env"
DRY_RUN_ONLY=0
ASSUME_YES=0
WITH_L2_STACK=0
SKIP_CRYPTO_GATE=0

log()  { printf '\033[1;34m[launch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[launch:warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[launch:error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- args ------------------------------------------------------------------
for arg in "$@"; do
  case "${arg}" in
    --dry-run)          DRY_RUN_ONLY=1 ;;
    --yes|-y)           ASSUME_YES=1 ;;
    --with-l2-stack)    WITH_L2_STACK=1 ;;
    --skip-crypto-gate) SKIP_CRYPTO_GATE=1 ;;
    -h|--help)
      sed -n '9,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) die "unknown flag: ${arg} (try --help)" ;;
    *)  ENV_FILE="${arg}" ;;
  esac
done

# --- load + validate the env ----------------------------------------------
[ -f "${ENV_FILE}" ] || die "env file not found: ${ENV_FILE}
  Copy the template first:  cp solidity/deploy.sepolia.env.example ${ENV_FILE}"

log "loading deploy env: ${ENV_FILE}"
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

# Required for a value-bearing BOLD+AMM broadcast.  Each must be set AND must
# not still carry a `SET-THIS…` placeholder.
REQUIRED_VARS=(
  SEPOLIA_RPC_URL ETHERSCAN_API_KEY
  KNOMOSIS_ATTESTOR KNOMOSIS_SEQUENCER KNOMOSIS_TREASURY
  KNOMOSIS_ADJUDICATORS
  KNOMOSIS_BOLD_TOKEN KNOMOSIS_AMM_SEED_RATIO_BPS
  KNOMOSIS_BOLD_CIRCUIT_BREAKER KNOMOSIS_BOLD_ADMIN
  KNOMOSIS_AMM_MULTISIG_SIGNERS
)

missing=()
for v in "${REQUIRED_VARS[@]}"; do
  val="${!v:-}"
  if [ -z "${val}" ] || printf '%s' "${val}" | grep -q 'SET-THIS'; then
    missing+=("${v}")
  fi
done

# Normalise the signer.  A leftover `SET-THIS…` placeholder in
# KNOMOSIS_DEPLOYER_ACCOUNT must NOT shadow a real PRIVATE_KEY: `solidity/
# Makefile`'s deploy-sepolia prefers ANY non-empty account, so it would run
# `--account SET-THIS-…` and the documented raw-key fallback would fail after
# the dry-run.  Unset the placeholder so PRIVATE_KEY is reachable.
if [ -n "${KNOMOSIS_DEPLOYER_ACCOUNT:-}" ] && printf '%s' "${KNOMOSIS_DEPLOYER_ACCOUNT}" | grep -q 'SET-THIS'; then
  unset KNOMOSIS_DEPLOYER_ACCOUNT
fi
# Exactly one signer path must be provided (keystore preferred).
if [ -z "${KNOMOSIS_DEPLOYER_ACCOUNT:-}" ]; then
  if [ -z "${PRIVATE_KEY:-}" ] || printf '%s' "${PRIVATE_KEY:-}" | grep -q 'SET-THIS'; then
    missing+=("KNOMOSIS_DEPLOYER_ACCOUNT (keystore) or PRIVATE_KEY (raw)")
  fi
fi

if [ "${#missing[@]}" -gt 0 ]; then
  die "these required values are unset or still placeholders in ${ENV_FILE}:
    - ${missing[*]}
  Fill them in (see the comments in deploy.sepolia.env.example), then re-run."
fi

command -v forge >/dev/null 2>&1 || die "forge (Foundry) not found on PATH; install per docs/sepolia_deployment_runbook.md §1"

# A functional AMM needs BOTH a non-zero seed ratio AND a non-zero BOLD token
# (`functionalAmm = boldToken != 0 && ammSeedRatioBps > 0`).  A zero in either
# silently drops the AMM + its disaster-recovery multisig even though this
# wrapper required the AMM signer set — catch both before the operator thinks
# they deployed the kill switch.
if [ "${KNOMOSIS_AMM_SEED_RATIO_BPS}" = "0" ]; then
  die "KNOMOSIS_AMM_SEED_RATIO_BPS is 0 — the AMM (and its disaster-recovery
  multisig) would NOT be deployed.  Set it > 0 for the full BOLD+AMM suite, or
  use an ETH-only env if that is intended."
fi
case "${KNOMOSIS_BOLD_TOKEN}" in
  0x0 | 0x0000000000000000000000000000000000000000 | 0X0* | "")
    die "KNOMOSIS_BOLD_TOKEN is the zero address — this wrapper deploys the full
  BOLD+AMM suite, but a zero token disables BOLD and silently drops the AMM +
  its disaster-recovery multisig.  Set a real Sepolia BOLD token, or use an
  ETH-only deploy path." ;;
esac

log "env validated — value-bearing BOLD+AMM deploy"
log "  deployer:   ${KNOMOSIS_DEPLOYER_ACCOUNT:-<raw PRIVATE_KEY>}"
log "  bold token: ${KNOMOSIS_BOLD_TOKEN}"
log "  amm seed:   ${KNOMOSIS_AMM_SEED_RATIO_BPS} bps"

# --- step 1: F-1 / F-2 trust-binding gate ----------------------------------
if [ "${SKIP_CRYPTO_GATE}" -eq 0 ]; then
  log "F-1/F-2 gate: proving a single knomosis binary links BOTH production adaptors…"
  "${ROOT}/scripts/verify_release_crypto.sh" \
    || die "F-1/F-2 crypto gate FAILED — a fallback hash/verifier must never reach a value-bearing deploy. Aborting."
  log "F-1/F-2 gate: PASSED (production keccak256 + secp256k1 linked)."
else
  warn "skipping the F-1/F-2 crypto gate (--skip-crypto-gate)"
fi

# --- step 2: dry-run against a Sepolia FORK --------------------------------
# A value-bearing BOLD deploy CANNOT dry-run on an empty in-memory chain: the
# bridge constructor checks the BOLD token's `code.length` + `symbol()`, and a
# real Sepolia BOLD address has no code off-fork — so `make deploy-sepolia-
# dryrun` (a bare in-memory `forge script`) would abort here.  Fork Sepolia so
# the token (and any other pre-existing state) is present; this simulates the
# REAL value-bearing config end-to-end without broadcasting.
log "dry-run: simulating the full deploy against a Sepolia fork (no broadcast)…"
( cd "${ROOT}/solidity" && forge script script/DeploySepolia.s.sol --fork-url "${SEPOLIA_RPC_URL}" ) \
  || die "dry-run FAILED — fix the reported config error before broadcasting."
log "dry-run: PASSED — the config produces a consistent deployment on a Sepolia fork."

if [ "${DRY_RUN_ONLY}" -eq 1 ]; then
  log "--dry-run set: stopping before the real broadcast."
  exit 0
fi

# --- step 3: confirm, then broadcast ---------------------------------------
if [ "${ASSUME_YES}" -eq 0 ]; then
  printf '\033[1;33m[launch]\033[0m About to BROADCAST a value-bearing deploy to Sepolia and spend real test-ETH.\n'
  printf '        RPC: %s\n' "${SEPOLIA_RPC_URL%%\?*}"
  read -r -p "        Type 'deploy' to proceed: " confirm
  [ "${confirm}" = "deploy" ] || die "aborted (no 'deploy' confirmation)."
fi

log "broadcasting to Sepolia + verifying sources on Etherscan…"
( cd "${ROOT}/solidity" && make deploy-sepolia ) \
  || die "deploy FAILED during broadcast/verify — inspect the forge output above."

MANIFEST="${ROOT}/solidity/${KNOMOSIS_MANIFEST_OUT:-deployments/sepolia.json}"
log "deploy COMPLETE."
if [ -f "${MANIFEST}" ]; then
  log "addresses manifest: ${MANIFEST}"
else
  warn "expected manifest not found at ${MANIFEST}; check the forge output for the real path."
fi

# --- step 4: optional L2 stack bring-up ------------------------------------
if [ "${WITH_L2_STACK}" -eq 1 ]; then
  log "bringing up the L2 daemon stack against the manifest…"
  MANIFEST="${MANIFEST}" "${ROOT}/scripts/knomosis_l2_sepolia_stack.sh" \
    || die "L2 stack bring-up FAILED — see the output above."
  log "L2 stack up."
else
  log "next: bring up the L2 stack when ready →  MANIFEST=${MANIFEST} ./scripts/knomosis_l2_sepolia_stack.sh"
fi

log "done.  Post-deploy steps: docs/launch_execution_checklist.md."

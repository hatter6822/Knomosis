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
#    3. Dry-run against a Sepolia FORK (forge script --fork-url) — catches every
#       config error (bad quorum, cap ordering, missing role, a BOLD token with
#       no code) WITHOUT spending gas. A fork (not a bare in-memory chain) so
#       the real on-chain BOLD token the bridge constructor checks is present.
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
# not still carry a `SET-THIS…` placeholder.  The two economic knobs are
# required because DeploySepolia's defaults for them are explicitly launch-UNSAFE
# and immutable after construction: MIN_CHALLENGE_BOND defaults to 0.05 ETH (too
# low — cheap to grief the fault proof) and TVL_CAP defaults to 100000 ETH (far
# too high — unbounded bridged-value exposure).  Requiring them here stops a
# minimal env from silently deploying on those defaults (the template ships
# sized starting values).
REQUIRED_VARS=(
  SEPOLIA_RPC_URL ETHERSCAN_API_KEY
  KNOMOSIS_ATTESTOR KNOMOSIS_SEQUENCER KNOMOSIS_TREASURY
  KNOMOSIS_ADJUDICATORS
  KNOMOSIS_BOLD_TOKEN KNOMOSIS_AMM_SEED_RATIO_BPS
  KNOMOSIS_BOLD_CIRCUIT_BREAKER KNOMOSIS_BOLD_ADMIN
  KNOMOSIS_AMM_MULTISIG_SIGNERS
  KNOMOSIS_MIN_CHALLENGE_BOND KNOMOSIS_TVL_CAP
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
#
# Validate the seed ratio NUMERICALLY, not by a literal "0" string compare.
# DeploySepolia reads it with `vm.envOr(..., uint256)` and narrows to `uint16`,
# so spellings like `00` / `000` / `0x0` parse to 0 (AMM silently dropped) yet
# slip past `[ "$x" = "0" ]`, and any multiple of 65536 truncates to 0 via the
# uint16 narrowing.  Require a plain decimal integer in `(0, 65535]`.
case "${KNOMOSIS_AMM_SEED_RATIO_BPS}" in
  '' | *[!0-9]*)
    die "KNOMOSIS_AMM_SEED_RATIO_BPS ('${KNOMOSIS_AMM_SEED_RATIO_BPS}') must be a
  decimal integer number of basis points (e.g. 500).  DeploySepolia parses it as a
  uint, so a non-numeric value (including a 0x-hex spelling) is a config error." ;;
esac
# Bound the value WITHOUT fixed-width shell arithmetic: `$((10#$x))` wraps for a
# decimal string past bash's 64-bit width (e.g. 18446744073709552116 -> 500),
# which would let an oversized typo slip past both guards while DeploySepolia
# reads the full uint256 and narrows to uint16.  Operate on the digit string:
# strip leading zeros, reject an all-zero value, then bound by digit-count plus a
# lexicographic compare against the uint16 max (65535).  With leading zeros
# removed the string length is the true digit count and, at equal length, an
# ASCII compare of digits equals the numeric compare.
_bps_stripped="${KNOMOSIS_AMM_SEED_RATIO_BPS#"${KNOMOSIS_AMM_SEED_RATIO_BPS%%[!0]*}"}"
if [ -z "${_bps_stripped}" ]; then
  die "KNOMOSIS_AMM_SEED_RATIO_BPS is '${KNOMOSIS_AMM_SEED_RATIO_BPS}' (numerically
  0) — the AMM (and its disaster-recovery multisig) would NOT be deployed.  Set it
  > 0 for the full BOLD+AMM suite, or use an ETH-only env if that is intended."
fi
if [ "${#_bps_stripped}" -gt 5 ] || { [ "${#_bps_stripped}" -eq 5 ] && [[ "${_bps_stripped}" > "65535" ]]; }; then
  die "KNOMOSIS_AMM_SEED_RATIO_BPS is '${KNOMOSIS_AMM_SEED_RATIO_BPS}', above the
  uint16 basis-points field (max 65535): it would truncate mod 65536, and a multiple
  of 65536 narrows to 0 and silently drops the AMM.  Use a value in (0, 65535] (and
  <= MAX_AMM_SEED_RATIO_BPS — the fork dry-run enforces the contract cap)."
fi
case "${KNOMOSIS_BOLD_TOKEN}" in
  0x0 | 0x0000000000000000000000000000000000000000 | 0X0* | "")
    die "KNOMOSIS_BOLD_TOKEN is the zero address — this wrapper deploys the full
  BOLD+AMM suite, but a zero token disables BOLD and silently drops the AMM +
  its disaster-recovery multisig.  Set a real Sepolia BOLD token, or use an
  ETH-only deploy path." ;;
esac

# The addresses manifest is written by DeploySepolia's `vm.writeJson`, which
# `solidity/foundry.toml` `fs_permissions` restricts to the `./deployments`
# directory.  An absolute KNOMOSIS_MANIFEST_OUT (e.g. /tmp/sepolia.json) — or a
# relative one that escapes via `..` — would let the broadcast deploy every
# contract and THEN revert at manifest-write, leaving live contracts with no
# manifest and this wrapper dying before stack bring-up.  Require a relative path
# under `deployments/` with no `..`, mirroring DeploySepolia's pre-broadcast gate,
# so a mis-set path fails HERE before any test-ETH is spent.
if [ -n "${KNOMOSIS_MANIFEST_OUT:-}" ]; then
  case "${KNOMOSIS_MANIFEST_OUT}" in
    deployments/*..* | *../*)
      die "KNOMOSIS_MANIFEST_OUT ('${KNOMOSIS_MANIFEST_OUT}') must not contain '..'
  (path escape).  vm.writeJson can only write under solidity/deployments/." ;;
    deployments/*) : ;;  # ok: relative, under the permitted directory
    *)
      die "KNOMOSIS_MANIFEST_OUT ('${KNOMOSIS_MANIFEST_OUT}') must be a RELATIVE path
  under deployments/ (e.g. deployments/sepolia.json).  Foundry's fs_permissions
  grants vm.writeJson write access only to solidity/deployments/, so an absolute
  or out-of-tree path would broadcast the deploy and then fail at manifest-write." ;;
  esac
fi

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
# DeploySepolia's `_writeManifest` runs UNCONDITIONALLY — fork simulation still
# executes `vm.writeJson`.  Point the dry-run at a throwaway manifest so it never
# clobbers the canonical `deployments/<network>.json` that the L2 stack + ops
# tooling consume: otherwise an aborted confirmation (below) or a failed broadcast
# would leave that file pointing at fork-only addresses that were never deployed on
# Sepolia.  `fs_permissions` grants the whole `deployments/` dir, so a temp file
# there is writable; the EXIT trap removes it on any exit path (including `die`).
# The override is scoped to this one subshell command, so the REAL broadcast below
# still honours the operator's `KNOMOSIS_MANIFEST_OUT` (or the default).
dryrun_manifest_rel="deployments/.sepolia-dryrun.$$.json"
trap 'rm -f "${ROOT}/solidity/${dryrun_manifest_rel}"' EXIT

# Match the broadcast's msg.sender in the simulation.  DeploySepolia sets
# `deployer = msg.sender` and predicts EVERY CREATE address (bridge / verifier /
# stake / multisig) from it via `computeCreateAddress(deployer, nonce)`; the
# multisig constructor also rejects a signer equal to the bridge or to itself.
# A fork run under forge's DEFAULT sender (and that sender's fork nonce) predicts
# DIFFERENT addresses than the real broadcast, so a config that would revert on
# the real predicted addresses could pass here and then revert mid-broadcast,
# after the registry/bridge/verifier/stake are already on-chain.  Pin --sender to
# the real deployer so the fork reads its true nonce and predicts the broadcast's
# addresses.  A simulation needs only the ADDRESS (never the key), so prefer an
# explicit KNOMOSIS_DEPLOYER_ADDRESS (keeps the dry-run keystore-unlock-free) and
# otherwise derive it from the same signer the broadcast uses.
if [ -n "${KNOMOSIS_DEPLOYER_ADDRESS:-}" ]; then
  dryrun_sender="${KNOMOSIS_DEPLOYER_ADDRESS}"
else
  command -v cast >/dev/null 2>&1 \
    || die "cast (Foundry) not found on PATH — needed to derive the dry-run sender. Set KNOMOSIS_DEPLOYER_ADDRESS to the deployer's public address to skip derivation, or install Foundry."
  if [ -n "${KNOMOSIS_DEPLOYER_ACCOUNT:-}" ]; then
    dryrun_sender="$(cast wallet address --account "${KNOMOSIS_DEPLOYER_ACCOUNT}")" \
      || die "could not derive the deployer address from keystore account '${KNOMOSIS_DEPLOYER_ACCOUNT}'. Set KNOMOSIS_DEPLOYER_ADDRESS to the deployer's public address to skip the keystore unlock."
  else
    dryrun_sender="$(cast wallet address --private-key "${PRIVATE_KEY}")" \
      || die "could not derive the deployer address from PRIVATE_KEY."
  fi
fi
log "dry-run sender: ${dryrun_sender} (pinned to match the broadcast's msg.sender)"
( cd "${ROOT}/solidity" \
    && KNOMOSIS_MANIFEST_OUT="${dryrun_manifest_rel}" \
       forge script script/DeploySepolia.s.sol --fork-url "${SEPOLIA_RPC_URL}" --sender "${dryrun_sender}" ) \
  || die "dry-run FAILED — fix the reported config error before broadcasting."
rm -f "${ROOT}/solidity/${dryrun_manifest_rel}"
log "dry-run: PASSED — the config produces a consistent deployment on a Sepolia fork."

if [ "${DRY_RUN_ONLY}" -eq 1 ]; then
  log "--dry-run set: stopping before the real broadcast."
  exit 0
fi

# --- step 3: confirm, then broadcast ---------------------------------------
if [ "${ASSUME_YES}" -eq 0 ]; then
  printf '\033[1;33m[launch]\033[0m About to BROADCAST a value-bearing deploy to Sepolia and spend real test-ETH.\n'
  # Redact the RPC credential before printing.  A credential can live in three
  # places in the URL: the PATH (`/v3/<key>`, `/v2/<key>` — Infura/Alchemy), the
  # userinfo (`user:pass@host`), or a query/fragment stuck straight to the
  # authority (`host?token=…`).  Print scheme+host[:port] ONLY: take the
  # authority, drop a trailing query/fragment, then drop userinfo up to the last
  # `@`.  Everything after the authority is masked.
  _rpc_rest="${SEPOLIA_RPC_URL#*://}"
  _rpc_auth="${_rpc_rest%%/*}"    # authority (+ ?query/#frag when there is no path)
  _rpc_auth="${_rpc_auth%%[?#]*}" # drop a query/fragment attached to the authority
  _rpc_auth="${_rpc_auth##*@}"    # drop userinfo up to and including the last '@'
  if [ "${_rpc_rest}" != "${SEPOLIA_RPC_URL}" ]; then
    _rpc_display="${SEPOLIA_RPC_URL%%://*}://${_rpc_auth}/<redacted>"
  else
    _rpc_display="${_rpc_auth}/<redacted>"
  fi
  printf '        RPC: %s\n' "${_rpc_display}"
  read -r -p "        Type 'deploy' to proceed: " confirm
  [ "${confirm}" = "deploy" ] || die "aborted (no 'deploy' confirmation)."
fi

log "broadcasting to Sepolia + verifying sources on Etherscan…"
( cd "${ROOT}/solidity" && make deploy-sepolia ) \
  || die "deploy FAILED during broadcast/verify — inspect the forge output above."

# Resolve the manifest path forge wrote.  The env guard above (and DeploySepolia's
# pre-broadcast gate) constrain KNOMOSIS_MANIFEST_OUT to a relative path under
# solidity/deployments/ — the only directory vm.writeJson may write to — so the
# written file is always under the solidity project root.
_manifest_out="${KNOMOSIS_MANIFEST_OUT:-deployments/sepolia.json}"
MANIFEST="${ROOT}/solidity/${_manifest_out}"
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

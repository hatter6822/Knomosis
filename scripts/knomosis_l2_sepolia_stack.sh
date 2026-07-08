#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Knomosis  - A Societal Kernel
# Copyright (C) 2026  Adam Hall
# This program comes with ABSOLUTELY NO WARRANTY.  This is free software,
# and you are welcome to redistribute it under certain conditions.  See:
#   https://github.com/hatter6822/Knomosis/blob/main/LICENSE
#
# knomosis_l2_sepolia_stack.sh — bring up the Knomosis L2 daemon stack against
# a deployed L1 manifest (Sepolia by default) and expose the gateway HTTP/JSON
# + SSE surface for the Licio BFF.  See docs/sepolia_deployment_runbook.md.
#
# It reads a DeploySepolia manifest (deployments/<network>.json) for the
# deploymentId + L1 contract addresses, then launches — in dependency order —
# the CORE read/submit/event stack:
#
#   knomosis-host          (L2 sequencer front-end; writes the event log)
#   knomosis-event-subscribe (tails the log; serves the SUBSCRIBE stream)
#   knomosis-indexer       (subscribes; builds the SQLite read model)
#   knomosis-gateway       (fronts host+subscribe+indexer for Licio; auth on)
#
# and — only when a Sepolia RPC + a funded bridge-actor keystore are provided
# via env — the L1-anchoring daemons:
#
#   knomosis-l1-ingest         (watches the L1 bridge/registry; feeds the host)
#   knomosis-faultproof-observer (watches the L1 fault-proof game; optional)
#
# The gateway is served PLAINTEXT for a server-to-server Licio Hono BFF by
# default (the bearer token stays server-side).  For a browser-direct client,
# set GW_CORS_ORIGIN and terminate TLS (see the runbook §7).
#
# This is an operator convenience launcher for a SHADOW/test deployment.  A
# production deployment uses supervised services (systemd/k8s), real key
# custody, and monitoring — see docs/testnet_readiness.md §3.5.
#
# Exit codes: 0 clean shutdown · 1 a launch/health step failed · 2 a
# prerequisite (binary/tool/manifest) is missing.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MANIFEST="${MANIFEST:-${ROOT}/solidity/deployments/sepolia.json}"
RUNDIR="${RUNDIR:-${ROOT}/.knomosis-l2-run}"

# Binaries.  The Lean `knomosis` binary is shelled to by host/subscribe/
# observer; the Rust daemons come from the runtime workspace release build.
KNOMOSIS_BIN="${KNOMOSIS_BIN:-${ROOT}/.lake/build/bin/knomosis}"
RUST_BIN_DIR="${RUST_BIN_DIR:-${ROOT}/runtime/target/release}"

# Listen addresses (loopback by default — front the gateway with a reverse
# proxy / the Licio BFF, do not expose the host/subscribe sockets publicly).
HOST_ADDR="${HOST_ADDR:-127.0.0.1:9101}"
SUBSCRIBE_ADDR="${SUBSCRIBE_ADDR:-127.0.0.1:9102}"
GW_LISTEN="${GW_LISTEN:-127.0.0.1:8080}"

# Gateway bearer token for the Licio BFF.  Auto-generated if unset; written to
# a chmod-600 file (the gateway refuses a world-readable token file).
GW_TOKEN="${GW_TOKEN:-}"
GW_CORS_ORIGIN="${GW_CORS_ORIGIN:-}"   # e.g. http://localhost:5173 for browser-direct

# Per-actor budget policy.  DEFAULT = OFF (ungated): the host assembles NO
# budget gate, so a signed action is admitted on its §8.2 precondition +
# signature alone — a test actor needs no budget to submit (exactly what Licio
# needs out of the box).
#
# CRITICAL: knomosis-host assembles a BOUNDED policy whenever ANY of
# --free-tier / --action-cost / --current-epoch is passed (config.rs
# ::budget_policy -> any_sub), and `mk_bounded(free_tier=0, action_cost=1)` is
# DENY-ALL (a fresh actor has 0 budget and needs 1).  So those flags are
# emitted ONLY when an operator explicitly opts in with BUDGET_POLICY=bounded.
# (--epoch-length alone does NOT enable a gate.)
BUDGET_POLICY="${BUDGET_POLICY:-}"        # "" = ungated (default) · "bounded" = per-actor budgets
FREE_TIER="${FREE_TIER:-1000}"            # per-epoch free budget    (bounded mode only)
ACTION_COST="${ACTION_COST:-1}"           # per-action budget cost   (bounded mode only)
CURRENT_EPOCH="${CURRENT_EPOCH:-0}"       # genesis epoch            (bounded mode only)
EPOCH_LENGTH="${EPOCH_LENGTH:-0}"         # action-clock epoch length (0 = no replenish)
GAS_POOL_ACTOR="${GAS_POOL_ACTOR:-}"

# L1 anchoring (optional).  Set SEPOLIA_RPC_URL + BRIDGE_ACTOR_KEYSTORE to run
# knomosis-l1-ingest; add OBSERVER_KEYSTORE to run the fault-proof observer.
SEPOLIA_RPC_URL="${SEPOLIA_RPC_URL:-}"
BRIDGE_ACTOR_KEYSTORE="${BRIDGE_ACTOR_KEYSTORE:-}"
OBSERVER_KEYSTORE="${OBSERVER_KEYSTORE:-}"
L1_CHAIN_ID="${L1_CHAIN_ID:-11155111}"
CONFIRMATION_DEPTH="${CONFIRMATION_DEPTH:-12}"

# ---------------------------------------------------------------------------
log()  { echo "[l2-stack] $*"; }
die()  { echo "[l2-stack] ERROR: $*" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1" 2; }

usage() {
    sed -n '9,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then usage; fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
need jq
[ -f "${MANIFEST}" ] || die "manifest not found: ${MANIFEST} (run 'make deploy-sepolia' first)" 2
[ -x "${KNOMOSIS_BIN}" ] || die "knomosis binary not found/executable: ${KNOMOSIS_BIN} (run 'lake build')" 2
for b in knomosis-host knomosis-event-subscribe knomosis-indexer knomosis-gateway; do
    [ -x "${RUST_BIN_DIR}/${b}" ] || die "daemon not found: ${RUST_BIN_DIR}/${b} (run 'cd runtime && cargo build --release')" 2
done

# ---------------------------------------------------------------------------
# Parse the manifest
# ---------------------------------------------------------------------------
mf() { jq -er "$1" "${MANIFEST}"; }
DEPLOYMENT_ID="$(mf '.deploymentId')" || die "manifest missing .deploymentId"
CHAIN_ID="$(mf '.chainId')"           || die "manifest missing .chainId"
# The canonical Knomosis L2 chain id (8357 production / 83572 test) the gateway
# advertises via /v1/info + /rpc for wallet "Add Network".  REQUIRED: a manifest
# without it predates the L2-chain-id scheme, so its deployed
# KnomosisDisputeVerifier reconstructs the KnomosisAction domain with
# block.chainid (the L1 id) rather than the L2 chain id.  Letting the gateway
# fall back to its 83572 default there would make it advertise a chain id the
# on-chain verifier does NOT expect, so a wallet-signed action could be
# mis-verified as invalid during a dispute.  Fail closed on that version skew.
L2_CHAIN_ID="$(mf '.l2ChainId')" || die "manifest missing .l2ChainId: it predates the L2 chain-id scheme, and its deployed KnomosisDisputeVerifier reconstructs the KnomosisAction domain with block.chainid (not the L2 chain id) — incompatible with the gateway's advertised L2 chain id.  Redeploy with the current contracts (make deploy-sepolia)."
BRIDGE_ADDR="$(mf '.contracts.KnomosisBridge')"
REGISTRY_ADDR="$(mf '.contracts.KnomosisIdentityRegistry')"
GAME_ADDR="$(mf '.contracts.KnomosisFaultProofGame')"
STATE_ROOT_ADDR="$(mf '.contracts.KnomosisStateRootSubmission')"

log "manifest:      ${MANIFEST}"
log "network:       $(mf '.network') (chainId ${CHAIN_ID})"
log "deploymentId:  ${DEPLOYMENT_ID}"
log "bridge:        ${BRIDGE_ADDR}"

# ---------------------------------------------------------------------------
# Run directory + gateway token
# ---------------------------------------------------------------------------
mkdir -p "${RUNDIR}"
EVENT_LOG="${RUNDIR}/knomosis-l2.log"
INDEXER_DB="${RUNDIR}/indexer.sqlite"
TOKEN_FILE="${RUNDIR}/gateway-token"
INGEST_STATE="${RUNDIR}/l1-ingest.state"
OBSERVER_DB="${RUNDIR}/observer.sqlite"

if [ -z "${GW_TOKEN}" ]; then
    GW_TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
umask 077
printf '%s\n' "${GW_TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------
declare -a PIDS=()
declare -a NAMES=()
cleanup() {
    log "shutting down (${#PIDS[@]} daemons) ..."
    # Reverse order: gateway/observer first, host last.
    for ((i=${#PIDS[@]}-1; i>=0; i--)); do
        if kill -0 "${PIDS[i]}" 2>/dev/null; then
            kill "${PIDS[i]}" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
    log "stopped."
}
trap cleanup EXIT INT TERM

spawn() {
    local name="$1"; shift
    log "starting ${name}: $*"
    "$@" >"${RUNDIR}/${name}.out" 2>&1 &
    PIDS+=("$!"); NAMES+=("${name}")
    # Fail fast if it dies immediately.
    sleep 1
    if ! kill -0 "$!" 2>/dev/null; then
        echo "----- ${name} output -----" >&2; tail -20 "${RUNDIR}/${name}.out" >&2 || true
        die "${name} failed to start"
    fi
}

wait_tcp() {  # host:port, timeout_s
    local hp="$1" t="${2:-20}" h="${1%%:*}" p="${1##*:}"
    for ((i=0; i<t*2; i++)); do
        (exec 3<>"/dev/tcp/${h}/${p}") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
        sleep 0.5
    done
    return 1
}

wait_file() {  # path, timeout_s — wait for a file to exist (e.g. the indexer DB)
    local f="$1" t="${2:-20}"
    for ((i=0; i<t*2; i++)); do
        [ -e "${f}" ] && return 0
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------------------
# Launch the core L2 stack (dependency order)
# ---------------------------------------------------------------------------
# Budget-gate flags — EMPTY unless BUDGET_POLICY=bounded (see the note above).
# Passing any budget sub-flag to the host enables a gate, so the default
# (ungated) path passes none of them.
HOST_BUDGET=(); SUB_BUDGET=(); GW_BUDGET=()
if [ "${BUDGET_POLICY}" = "bounded" ]; then
    HOST_BUDGET=(--budget-policy bounded --free-tier "${FREE_TIER}" --action-cost "${ACTION_COST}" --current-epoch "${CURRENT_EPOCH}" --epoch-length "${EPOCH_LENGTH}")
    SUB_BUDGET=(--budget-policy bounded --free-tier "${FREE_TIER}" --action-cost "${ACTION_COST}" --current-epoch "${CURRENT_EPOCH}" --epoch-length "${EPOCH_LENGTH}")
    GW_BUDGET=(--free-tier "${FREE_TIER}" --action-cost "${ACTION_COST}" --epoch-length "${EPOCH_LENGTH}")
    log "budget policy: BOUNDED (free-tier=${FREE_TIER}, action-cost=${ACTION_COST})"
else
    log "budget policy: OFF (ungated) — actions admitted on precondition + signature alone."
fi

HOST_ARGS=(
    --listen "${HOST_ADDR}"
    --knomosis-log "${EVENT_LOG}"
    --knomosis-binary "${KNOMOSIS_BIN}"
    --deployment-id "${DEPLOYMENT_ID}"
    --persistent-connections
)
if [ ${#HOST_BUDGET[@]} -gt 0 ]; then HOST_ARGS+=("${HOST_BUDGET[@]}"); fi
spawn host "${RUST_BIN_DIR}/knomosis-host" "${HOST_ARGS[@]}"
wait_tcp "${HOST_ADDR}" || die "host did not open ${HOST_ADDR}"

SUB_ARGS=(
    --listen "${SUBSCRIBE_ADDR}"
    --log-path "${EVENT_LOG}"
    --knomosis-binary "${KNOMOSIS_BIN}"
    --deployment-id "${DEPLOYMENT_ID}"
)
if [ ${#SUB_BUDGET[@]} -gt 0 ]; then SUB_ARGS+=("${SUB_BUDGET[@]}"); fi
spawn event-subscribe "${RUST_BIN_DIR}/knomosis-event-subscribe" "${SUB_ARGS[@]}"
wait_tcp "${SUBSCRIBE_ADDR}" || die "event-subscribe did not open ${SUBSCRIBE_ADDR}"

INDEXER_ARGS=(--subscribe "${SUBSCRIBE_ADDR}" --storage "${INDEXER_DB}" --epoch-length "${EPOCH_LENGTH}")
[ -n "${GAS_POOL_ACTOR}" ] && INDEXER_ARGS+=(--gas-pool-actor "${GAS_POOL_ACTOR}")
spawn indexer "${RUST_BIN_DIR}/knomosis-indexer" "${INDEXER_ARGS[@]}"
# The gateway opens the indexer SQLite in READ-ONLY mode, which fails if the
# file does not exist yet — wait for the indexer to create it before starting
# the gateway (the indexer has no listening port to wait_tcp on).
wait_file "${INDEXER_DB}" || die "indexer did not create ${INDEXER_DB}"

GW_ARGS=(
    --listen "${GW_LISTEN}"
    --host-addr "${HOST_ADDR}"
    --event-subscribe-addr "${SUBSCRIBE_ADDR}"
    --indexer-db "${INDEXER_DB}"
    --auth-token-file "${TOKEN_FILE}"
    --deployment-id "${DEPLOYMENT_ID}"
)
if [ ${#GW_BUDGET[@]} -gt 0 ]; then GW_ARGS+=("${GW_BUDGET[@]}"); fi
[ -n "${GAS_POOL_ACTOR}" ] && GW_ARGS+=(--gas-pool-actor "${GAS_POOL_ACTOR}")
[ -n "${GW_CORS_ORIGIN}" ] && GW_ARGS+=(--cors-origin "${GW_CORS_ORIGIN}")
GW_ARGS+=(--l2-chain-id "${L2_CHAIN_ID}")   # required (validated at manifest parse)
spawn gateway "${RUST_BIN_DIR}/knomosis-gateway" "${GW_ARGS[@]}"
wait_tcp "${GW_LISTEN}" || die "gateway did not open ${GW_LISTEN}"

# ---------------------------------------------------------------------------
# Optional L1-anchoring daemons
# ---------------------------------------------------------------------------
if [ -n "${SEPOLIA_RPC_URL}" ] && [ -n "${BRIDGE_ACTOR_KEYSTORE}" ]; then
    spawn l1-ingest "${RUST_BIN_DIR}/knomosis-l1-ingest" \
        --l1-rpc "${SEPOLIA_RPC_URL}" \
        --bridge-contract "${BRIDGE_ADDR}" \
        --identity-registry "${REGISTRY_ADDR}" \
        --bridge-actor-keystore "${BRIDGE_ACTOR_KEYSTORE}" \
        --state-file "${INGEST_STATE}" \
        --knomosis-host-tcp "${HOST_ADDR}" \
        --deployment-id "${DEPLOYMENT_ID}" \
        --confirmation-depth "${CONFIRMATION_DEPTH}" \
        --emit-signer-hints
else
    log "L1-ingest NOT started (set SEPOLIA_RPC_URL + BRIDGE_ACTOR_KEYSTORE to bridge L1 deposits)."
fi

if [ -n "${SEPOLIA_RPC_URL}" ] && [ -n "${OBSERVER_KEYSTORE}" ] \
   && [ -x "${RUST_BIN_DIR}/knomosis-faultproof-observer" ]; then
    spawn observer "${RUST_BIN_DIR}/knomosis-faultproof-observer" \
        --l1-rpc "${SEPOLIA_RPC_URL}" \
        --game-contract "${GAME_ADDR}" \
        --state-root-contract "${STATE_ROOT_ADDR}" \
        --storage "${OBSERVER_DB}" \
        --keystore "${OBSERVER_KEYSTORE}" \
        --deployment-id "${DEPLOYMENT_ID}" \
        --chain-id "${L1_CHAIN_ID}" \
        --knomosis-log "${EVENT_LOG}" \
        --knomosis-binary "${KNOMOSIS_BIN}"
else
    log "fault-proof observer NOT started (set OBSERVER_KEYSTORE to run an independent watchtower)."
fi

# ---------------------------------------------------------------------------
# Ready — print the Licio connection info
# ---------------------------------------------------------------------------
echo
log "================= L2 stack up ================="
log "Gateway (for the Licio BFF):  http://${GW_LISTEN}"
[ -n "${L2_CHAIN_ID}" ] && log "  L2 chain id (wallet):       ${L2_CHAIN_ID} (add-network RPC: http://${GW_LISTEN}/rpc)"
log "  Bearer token file (0600):   ${TOKEN_FILE}"
log "                              (read it with:  cat ${TOKEN_FILE})"
[ -n "${GW_CORS_ORIGIN}" ] && log "  Browser CORS origin:        ${GW_CORS_ORIGIN}"
log "  OpenAPI contract:           docs/api/gateway.openapi.yaml"
log "  Health:  curl http://${GW_LISTEN}/readyz"
log "  Info:    curl -H \"Authorization: Bearer \$(cat ${TOKEN_FILE})\" http://${GW_LISTEN}/v1/info"
log "Run dir (logs/sqlite/log):    ${RUNDIR}"
log "Ctrl-C to tear the stack down."
echo

wait
